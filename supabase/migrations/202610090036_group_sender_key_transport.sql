-- Signal Sender Keys for encrypted group/channel text. The server stores
-- only sender-key ciphertext and individually Signal-encrypted key deliveries.
begin;

alter table public.conversations
  add column if not exists e2ee_enabled boolean not null default false,
  add column if not exists group_epoch integer not null default 1
    check (group_epoch > 0);

create or replace function public.bump_group_epoch()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  changed_conversation_id uuid;
begin
  if tg_op = 'DELETE' then
    changed_conversation_id := old.conversation_id;
  else
    changed_conversation_id := new.conversation_id;
  end if;
  update public.conversations
  set group_epoch = group_epoch + 1
  where id = changed_conversation_id and type in ('group', 'channel');
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists conversation_members_bump_group_epoch
  on public.conversation_members;
create trigger conversation_members_bump_group_epoch
after insert or delete on public.conversation_members
for each row execute function public.bump_group_epoch();

-- A Signal identity rotation (for example, reinstalling a device) invalidates
-- the old recipient key envelopes. Advance every joined encrypted group's
-- epoch so senders must distribute fresh sender keys to the new identity.
create function public.bump_group_epoch_on_identity_rotation()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.identity_key is distinct from new.identity_key then
    update public.conversations c
    set group_epoch = group_epoch + 1
    where c.type in ('group', 'channel') and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = c.id and cm.user_id = new.user_id
    );
  end if;
  return new;
end;
$$;
drop trigger if exists group_epoch_on_identity_rotation on public.key_bundles;
create trigger group_epoch_on_identity_rotation
after update of identity_key on public.key_bundles
for each row execute function public.bump_group_epoch_on_identity_rotation();

-- New groups are E2EE by default; existing groups remain explicitly legacy
-- until their owner opts in, so historical plaintext is never mislabeled.
drop function public.create_conversation(varchar, varchar, text, text);
create function public.create_conversation(
  p_type varchar,
  p_title varchar,
  p_description text default null,
  p_avatar_url text default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  conv_id uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_type not in ('group', 'channel') then raise exception 'Invalid type'; end if;
  if p_title is null or char_length(trim(p_title)) not between 1 and 100 then
    raise exception 'Title must be 1–100 characters';
  end if;
  insert into public.conversations(
    type, title, description, avatar_url, created_by, invite_code, e2ee_enabled
  ) values (
    p_type, trim(p_title), p_description, p_avatar_url, me,
    substr(replace(gen_random_uuid()::text, '-', ''), 1, 16), true
  ) returning id into conv_id;
  insert into public.conversation_members(conversation_id, user_id, role)
  values (conv_id, me, 'owner');
  return conv_id;
end;
$$;
revoke all on function public.create_conversation(varchar, varchar, text, text)
  from public, anon, authenticated;
grant execute on function public.create_conversation(varchar, varchar, text, text)
  to authenticated;

create or replace function public.list_conversations(
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.last_activity desc nulls last), '[]'::jsonb)
  into result from (
    select
      c.id, c.type, c.title, c.description, c.avatar_url, c.invite_code,
      c.require_approval, c.created_by, c.created_at,
      c.e2ee_enabled, c.group_epoch,
      cm.role as my_role, cm.is_muted, cm.is_pinned, cm.is_archived,
      cm.unread_count,
      (select max(gm.created_at) from public.group_messages gm
       where gm.conversation_id = c.id) as last_activity,
      (select case when c.e2ee_enabled then 'Encrypted message' else gm.content end
       from public.group_messages gm where gm.conversation_id = c.id
       order by gm.created_at desc, gm.id desc limit 1) as last_message
    from public.conversations c
    join public.conversation_members cm on cm.conversation_id = c.id
    where cm.user_id = me
    order by cm.is_pinned desc nulls last,
      (select max(gm2.created_at) from public.group_messages gm2
       where gm2.conversation_id = c.id) desc nulls last
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
    offset greatest(coalesce(p_offset, 0), 0)
  ) items;
  return result;
end;
$$;
revoke all on function public.list_conversations(integer, integer)
  from public, anon, authenticated;
grant execute on function public.list_conversations(integer, integer)
  to authenticated;

create table public.group_sender_key_envelopes (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  epoch integer not null check (epoch > 0),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  distribution_id uuid not null,
  ciphertext text not null check (char_length(ciphertext) between 1 and 8192),
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  check (sender_id <> recipient_id),
  unique (conversation_id, epoch, sender_id, recipient_id)
);
create index group_sender_key_pending
  on public.group_sender_key_envelopes(recipient_id, created_at)
  where acknowledged_at is null;
alter table public.group_sender_key_envelopes enable row level security;
revoke all on public.group_sender_key_envelopes from anon, authenticated;

create function public.enable_group_e2ee(p_conversation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  epoch integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if exists (
    select 1 from public.group_messages gm
    where gm.conversation_id = p_conversation_id
  ) then
    raise exception 'This group has legacy history. Create a new encrypted group to protect all messages.';
  end if;
  update public.conversations c
  set e2ee_enabled = true, group_epoch = group_epoch + 1
  where c.id = p_conversation_id and c.type in ('group', 'channel')
    and c.created_by = me
  returning c.group_epoch into epoch;
  if not found then raise exception 'Only the group owner can enable encryption'; end if;
  return epoch;
end;
$$;
revoke all on function public.enable_group_e2ee(uuid) from public, anon, authenticated;
grant execute on function public.enable_group_e2ee(uuid) to authenticated;

create function public.group_security_state(p_conversation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then raise exception 'Not a member of this conversation'; end if;
  select jsonb_build_object(
    'e2ee_enabled', c.e2ee_enabled,
    'epoch', c.group_epoch,
    'member_ids', coalesce((
      select jsonb_agg(cm.user_id order by cm.user_id)
      from public.conversation_members cm
      where cm.conversation_id = c.id
    ), '[]'::jsonb)
  ) into result
  from public.conversations c where c.id = p_conversation_id;
  return result;
end;
$$;
revoke all on function public.group_security_state(uuid) from public, anon, authenticated;
grant execute on function public.group_security_state(uuid) to authenticated;

create function public.publish_group_sender_key(
  p_conversation_id uuid,
  p_epoch integer,
  p_distribution_id uuid,
  p_envelopes jsonb
)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  current_epoch integer;
  expected integer;
  saved integer := 0;
  member record;
  packet text;
  existing_distribution uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select c.group_epoch into current_epoch
  from public.conversations c
  where c.id = p_conversation_id and c.e2ee_enabled
    and c.type in ('group', 'channel')
  for update;
  if not found then raise exception 'Encrypted group unavailable'; end if;
  if current_epoch <> p_epoch then raise exception 'Group membership changed; refresh keys'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then raise exception 'Not a member of this conversation'; end if;
  if jsonb_typeof(p_envelopes) <> 'object' then
    raise exception 'Invalid sender-key envelope map';
  end if;
  select count(*) into expected from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id <> me;
  if jsonb_object_length(p_envelopes) <> expected then
    raise exception 'Sender key must be distributed to every current member';
  end if;
  for member in
    select cm.user_id from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id <> me
  loop
    packet := p_envelopes ->> member.user_id::text;
    if packet is null or char_length(packet) not between 1 and 8192 then
      raise exception 'Invalid sender-key envelope';
    end if;
    insert into public.group_sender_key_envelopes(
      conversation_id, epoch, sender_id, recipient_id,
      distribution_id, ciphertext, acknowledged_at
    ) values (
      p_conversation_id, p_epoch, me, member.user_id,
      p_distribution_id, packet, null
    ) on conflict (conversation_id, epoch, sender_id, recipient_id) do nothing;
    select envelope.distribution_id into existing_distribution
    from public.group_sender_key_envelopes envelope
    where envelope.conversation_id = p_conversation_id
      and envelope.epoch = p_epoch and envelope.sender_id = me
      and envelope.recipient_id = member.user_id;
    if existing_distribution <> p_distribution_id then
      raise exception 'A different sender key is already registered for this epoch';
    end if;
    saved := saved + 1;
  end loop;
  return saved;
end;
$$;
revoke all on function public.publish_group_sender_key(uuid, integer, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_group_sender_key(uuid, integer, uuid, jsonb)
  to authenticated;

create function public.fetch_group_sender_keys(
  p_conversation_id uuid,
  p_limit integer default 100
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then raise exception 'Not a member of this conversation'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at, items.id), '[]'::jsonb)
  into result from (
    select id, conversation_id, epoch, sender_id, distribution_id, ciphertext, created_at
    from public.group_sender_key_envelopes
    where conversation_id = p_conversation_id and recipient_id = me
      and acknowledged_at is null
    order by created_at, id
    limit least(greatest(coalesce(p_limit, 100), 1), 100)
  ) items;
  return result;
end;
$$;
revoke all on function public.fetch_group_sender_keys(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.fetch_group_sender_keys(uuid, integer)
  to authenticated;

create function public.ack_group_sender_keys(p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  changed integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 100 then
    raise exception 'Invalid key acknowledgment batch';
  end if;
  update public.group_sender_key_envelopes
  set acknowledged_at = coalesce(acknowledged_at, now())
  where recipient_id = me and id = any(p_ids);
  get diagnostics changed = row_count;
  return changed;
end;
$$;
revoke all on function public.ack_group_sender_keys(uuid[])
  from public, anon, authenticated;
grant execute on function public.ack_group_sender_keys(uuid[])
  to authenticated;

create function public.send_e2ee_group_message(
  p_conversation_id uuid,
  p_message_id uuid,
  p_epoch integer,
  p_ciphertext text
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  current_epoch integer;
  message_id uuid;
  my_role text;
  conversation_type text;
  existing public.group_messages;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select c.group_epoch, c.type into current_epoch, conversation_type
  from public.conversations c
  where c.id = p_conversation_id and c.e2ee_enabled
    and c.type in ('group', 'channel');
  if not found then raise exception 'Encrypted group unavailable'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then raise exception 'Not a member of this conversation'; end if;
  select cm.role into my_role from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;
  if conversation_type = 'channel' and my_role not in ('owner', 'admin') then
    raise exception 'Only channel admins can send messages';
  end if;
  if p_message_id is null then raise exception 'Message id required'; end if;
  select * into existing from public.group_messages gm where gm.id = p_message_id;
  if found then
    if existing.conversation_id = p_conversation_id
       and existing.sender_id = me
       and existing.metadata->>'e2ee' = 'true'
       and existing.metadata->>'epoch' = p_epoch::text
       and existing.content = 'E2E1:' || p_ciphertext then
      return p_message_id;
    end if;
    raise exception 'Message id is already in use';
  end if;
  if current_epoch <> p_epoch then
    raise exception 'Group membership changed; refresh and retry';
  end if;
  if p_ciphertext is null or char_length(p_ciphertext) not between 1 and 7900 then
    raise exception 'Encrypted message size is invalid';
  end if;
  insert into public.group_messages(
    id, conversation_id, sender_id, content, type, metadata
  ) values (
    p_message_id, p_conversation_id, me, 'E2E1:' || p_ciphertext, 'text',
    jsonb_build_object('e2ee', true, 'epoch', p_epoch)
  ) returning id into message_id;
  insert into public.group_message_receipts(message_id, user_id, status)
  values (message_id, me, 'read');
  update public.conversation_members
  set unread_count = unread_count + 1
  where conversation_id = p_conversation_id and user_id <> me;
  return message_id;
end;
$$;
revoke all on function public.send_e2ee_group_message(uuid, uuid, integer, text)
  from public, anon, authenticated;
grant execute on function public.send_e2ee_group_message(uuid, uuid, integer, text)
  to authenticated;

-- Once a group is marked encrypted, legacy RPCs cannot store plaintext bodies
-- or metadata into its message table.
create function public.enforce_group_e2ee_content()
returns trigger language plpgsql security definer set search_path = '' as $$
declare encrypted boolean;
begin
  select c.e2ee_enabled into encrypted
  from public.conversations c where c.id = new.conversation_id;
  if encrypted then
    if coalesce(new.is_deleted, false)
       and new.content = 'This message was deleted' then
      return new;
    end if;
    if new.metadata->>'e2ee' is distinct from 'true'
       or (new.metadata - array['e2ee', 'epoch']) <> '{}'::jsonb
       or new.content not like 'E2E1:%'
       or new.type <> 'text'
       or new.media_url is not null
       or new.parent_message_id is not null
       or coalesce(new.is_view_once, false)
       or coalesce(new.is_forwarded, false)
       or coalesce(new.forward_count, 0) <> 0 then
      raise exception 'End-to-end encryption is required for all group content';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists group_messages_require_e2ee on public.group_messages;
create trigger group_messages_require_e2ee
before insert or update of content, metadata, conversation_id, is_deleted
on public.group_messages
for each row execute function public.enforce_group_e2ee_content();

commit;
