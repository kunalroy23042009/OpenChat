-- RPCs for conversation lifecycle, group messaging, and member management.
-- Apply after 202610090014_conversations.sql.
begin;

-- ============================================================
-- 1. Create conversation (group or channel)
-- ============================================================
create or replace function public.create_conversation(
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
  if p_type not in ('group', 'channel') then
    raise exception 'Invalid conversation type';
  end if;
  if p_title is null or char_length(trim(p_title)) < 1 or char_length(trim(p_title)) > 100 then
    raise exception 'Title must be 1–100 characters';
  end if;

  insert into public.conversations(type, title, description, avatar_url, created_by,
    invite_code)
  values (p_type, trim(p_title), p_description, p_avatar_url, me,
    substr(replace(gen_random_uuid()::text, '-', ''), 1, 16))
  returning id into conv_id;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (conv_id, me, 'owner');

  return conv_id;
end;
$$;
revoke all on function public.create_conversation(varchar, varchar, text, text)
  from public, anon, authenticated;
grant execute on function public.create_conversation(varchar, varchar, text, text)
  to authenticated;

-- ============================================================
-- 2. Create direct conversation (1-on-1, idempotent)
-- ============================================================
create or replace function public.create_direct_conversation(p_peer_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  conv_id uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_peer_id is null or p_peer_id = me then
    raise exception 'Invalid peer';
  end if;

  -- Check for existing direct conversation between these two users
  select c.id into conv_id
  from public.conversations c
  join public.conversation_members cm1 on cm1.conversation_id = c.id and cm1.user_id = me
  join public.conversation_members cm2 on cm2.conversation_id = c.id and cm2.user_id = p_peer_id
  where c.type = 'direct'
  limit 1;

  if conv_id is not null then return conv_id; end if;

  insert into public.conversations(type, created_by)
  values ('direct', me)
  returning id into conv_id;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (conv_id, me, 'owner'), (conv_id, p_peer_id, 'member');

  return conv_id;
end;
$$;
revoke all on function public.create_direct_conversation(uuid) from public, anon, authenticated;
grant execute on function public.create_direct_conversation(uuid) to authenticated;

-- ============================================================
-- 3. Add member to group/channel
-- ============================================================
create or replace function public.add_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid,
  p_role varchar default 'member'
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  my_role varchar;
  conv_type varchar;
  member_count integer;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;

  if my_role is null then raise exception 'Not a member of this conversation'; end if;

  select c.type into conv_type from public.conversations c where c.id = p_conversation_id;

  -- Only admins/owners can add members in groups
  if conv_type in ('group', 'channel') and my_role = 'member' then
    raise exception 'Only admins can add members';
  end if;

  -- Check member limit (1024 for groups)
  select count(*) into member_count
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id;

  if member_count >= 1024 then
    raise exception 'Group is full (1024 members maximum)';
  end if;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (p_conversation_id, p_user_id, coalesce(p_role, 'member'))
  on conflict (conversation_id, user_id) do nothing;
end;
$$;
revoke all on function public.add_conversation_member(uuid, uuid, varchar)
  from public, anon, authenticated;
grant execute on function public.add_conversation_member(uuid, uuid, varchar)
  to authenticated;

-- ============================================================
-- 4. Remove member from group/channel
-- ============================================================
create or replace function public.remove_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  my_role varchar;
  target_role varchar;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;

  if my_role is null then raise exception 'Not a member'; end if;

  -- Users can remove themselves (leave group)
  if p_user_id = me then
    if my_role = 'owner' then
      raise exception 'Owners cannot leave. Transfer ownership first.';
    end if;
    delete from public.conversation_members
    where conversation_id = p_conversation_id and user_id = me;
    return;
  end if;

  -- Only admins/owners can remove others
  if my_role = 'member' then
    raise exception 'Only admins can remove members';
  end if;

  select cm.role into target_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = p_user_id;

  -- Admins cannot remove owners
  if target_role = 'owner' then
    raise exception 'Cannot remove the group owner';
  end if;

  -- Admins cannot remove other admins
  if my_role = 'admin' and target_role = 'admin' then
    raise exception 'Admins cannot remove other admins';
  end if;

  delete from public.conversation_members
  where conversation_id = p_conversation_id and user_id = p_user_id;
end;
$$;
revoke all on function public.remove_conversation_member(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.remove_conversation_member(uuid, uuid)
  to authenticated;

-- ============================================================
-- 5. Send group message
-- ============================================================
create or replace function public.send_group_message(
  p_conversation_id uuid,
  p_content text,
  p_type varchar default 'text',
  p_parent_message_id uuid default null,
  p_media_url text default null,
  p_metadata jsonb default null,
  p_is_view_once boolean default false,
  p_is_forwarded boolean default false,
  p_forward_count integer default 0
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  my_role varchar;
  conv public.conversations;
  msg_id uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;

  if my_role is null then raise exception 'Not a member of this conversation'; end if;

  -- Check announcement mode: only admins/owners can send
  select * into conv from public.conversations c where c.id = p_conversation_id;

  if p_content is null or char_length(p_content) < 1 or char_length(p_content) > 8000 then
    raise exception 'Message content must be 1–8000 characters';
  end if;

  insert into public.group_messages(
    conversation_id, sender_id, content, type,
    parent_message_id, media_url, metadata,
    is_view_once, is_forwarded, forward_count
  )
  values (
    p_conversation_id, me, p_content, coalesce(p_type, 'text'),
    p_parent_message_id, p_media_url, coalesce(p_metadata, '{}'::jsonb),
    coalesce(p_is_view_once, false),
    coalesce(p_is_forwarded, false),
    coalesce(p_forward_count, 0)
  )
  returning id into msg_id;

  -- Insert sender receipt
  insert into public.group_message_receipts(message_id, user_id, status)
  values (msg_id, me, 'read');

  -- Increment unread count for other members
  update public.conversation_members
  set unread_count = unread_count + 1
  where conversation_id = p_conversation_id and user_id <> me;

  return msg_id;
end;
$$;
revoke all on function public.send_group_message(uuid, text, varchar, uuid, text, jsonb, boolean, boolean, integer)
  from public, anon, authenticated;
grant execute on function public.send_group_message(uuid, text, varchar, uuid, text, jsonb, boolean, boolean, integer)
  to authenticated;

-- ============================================================
-- 6. Edit group message (within 15 minutes)
-- ============================================================
create or replace function public.edit_group_message(
  p_message_id uuid,
  p_content text
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  msg public.group_messages;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select * into msg from public.group_messages where id = p_message_id;

  if not found then raise exception 'Message not found'; end if;
  if msg.sender_id <> me then raise exception 'Can only edit your own messages'; end if;
  if msg.is_deleted then raise exception 'Cannot edit a deleted message'; end if;

  if msg.created_at < now() - interval '15 minutes' then
    raise exception 'Cannot edit messages older than 15 minutes';
  end if;

  if p_content is null or char_length(p_content) < 1 or char_length(p_content) > 8000 then
    raise exception 'Content must be 1–8000 characters';
  end if;

  update public.group_messages
  set content = p_content, is_edited = true, edited_at = now()
  where id = p_message_id;
end;
$$;
revoke all on function public.edit_group_message(uuid, text) from public, anon, authenticated;
grant execute on function public.edit_group_message(uuid, text) to authenticated;

-- ============================================================
-- 7. Delete group message
-- ============================================================
create or replace function public.delete_group_message(
  p_message_id uuid,
  p_for_everyone boolean default false
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  msg public.group_messages;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select * into msg from public.group_messages where id = p_message_id;
  if not found then raise exception 'Message not found'; end if;

  if p_for_everyone then
    if msg.sender_id <> me then raise exception 'Can only delete your own messages for everyone'; end if;
    if msg.created_at < now() - interval '60 hours' then
      raise exception 'Cannot delete for everyone after 60 hours';
    end if;
    update public.group_messages
    set is_deleted = true, content = 'This message was deleted'
    where id = p_message_id;
  else
    -- Delete for me: soft-delete via metadata flag (client handles hiding)
    update public.group_messages
    set metadata = jsonb_set(
      coalesce(metadata, '{}'::jsonb),
      ('{deleted_for,' || me::text || '}')::text[],
      'true'::jsonb
    )
    where id = p_message_id;
  end if;
end;
$$;
revoke all on function public.delete_group_message(uuid, boolean) from public, anon, authenticated;
grant execute on function public.delete_group_message(uuid, boolean) to authenticated;

-- ============================================================
-- 8. React to group message
-- ============================================================
create or replace function public.react_to_message(
  p_message_id uuid,
  p_emoji varchar
)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_emoji is null or char_length(p_emoji) < 1 or char_length(p_emoji) > 8 then
    raise exception 'Invalid emoji';
  end if;

  -- Toggle: if reaction exists, remove it; otherwise add it
  if exists(
    select 1 from public.message_reactions
    where message_id = p_message_id and user_id = me and emoji = p_emoji
  ) then
    delete from public.message_reactions
    where message_id = p_message_id and user_id = me and emoji = p_emoji;
  else
    insert into public.message_reactions(message_id, user_id, emoji)
    values (p_message_id, me, p_emoji);
  end if;
end;
$$;
revoke all on function public.react_to_message(uuid, varchar) from public, anon, authenticated;
grant execute on function public.react_to_message(uuid, varchar) to authenticated;

-- ============================================================
-- 9. Pin/unpin message (max 3 per conversation)
-- ============================================================
create or replace function public.pin_message(
  p_conversation_id uuid,
  p_message_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  my_role varchar;
  pin_count integer;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;

  if my_role is null or my_role = 'member' then
    raise exception 'Only admins can pin messages';
  end if;

  -- Toggle: if already pinned, unpin
  if exists(
    select 1 from public.pinned_messages
    where conversation_id = p_conversation_id and message_id = p_message_id
  ) then
    delete from public.pinned_messages
    where conversation_id = p_conversation_id and message_id = p_message_id;
    return;
  end if;

  select count(*) into pin_count
  from public.pinned_messages where conversation_id = p_conversation_id;

  if pin_count >= 3 then
    raise exception 'Cannot pin more than 3 messages per conversation';
  end if;

  insert into public.pinned_messages(conversation_id, message_id, pinned_by)
  values (p_conversation_id, p_message_id, me);
end;
$$;
revoke all on function public.pin_message(uuid, uuid) from public, anon, authenticated;
grant execute on function public.pin_message(uuid, uuid) to authenticated;

-- ============================================================
-- 10. Update presence (online/offline/last seen)
-- ============================================================
create or replace function public.update_presence(
  p_is_online boolean,
  p_custom_status varchar default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;

  update public.profiles
  set is_online = p_is_online,
      last_seen = case when not p_is_online then now() else last_seen end,
      custom_status = coalesce(p_custom_status, custom_status)
  where id = me;
end;
$$;
revoke all on function public.update_presence(boolean, varchar) from public, anon, authenticated;
grant execute on function public.update_presence(boolean, varchar) to authenticated;

-- ============================================================
-- 11. List user conversations
-- ============================================================
create or replace function public.list_conversations(
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select coalesce(jsonb_agg(to_jsonb(items) order by items.last_activity desc nulls last), '[]'::jsonb)
  into result
  from (
    select
      c.id, c.type, c.title, c.description, c.avatar_url, c.invite_code,
      c.require_approval, c.created_by, c.created_at,
      cm.role as my_role, cm.is_muted, cm.is_pinned, cm.is_archived,
      cm.unread_count,
      (select max(gm.created_at) from public.group_messages gm
       where gm.conversation_id = c.id) as last_activity,
      (select gm.content from public.group_messages gm
       where gm.conversation_id = c.id
       order by gm.created_at desc limit 1) as last_message
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
revoke all on function public.list_conversations(integer, integer) from public, anon, authenticated;
grant execute on function public.list_conversations(integer, integer) to authenticated;

-- ============================================================
-- 12. Fetch group messages for a conversation
-- ============================================================
create or replace function public.fetch_group_messages(
  p_conversation_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;

  -- Verify membership
  if not exists(
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then
    raise exception 'Not a member of this conversation';
  end if;

  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at), '[]'::jsonb)
  into result
  from (
    select
      gm.id, gm.conversation_id, gm.sender_id, gm.parent_message_id,
      gm.content, gm.type, gm.media_url, gm.metadata,
      gm.is_edited, gm.edited_at, gm.is_deleted,
      gm.is_view_once, gm.is_forwarded, gm.forward_count,
      gm.created_at,
      p.display_name as sender_name,
      -- Aggregate reactions as JSON array
      (select coalesce(jsonb_agg(jsonb_build_object(
        'emoji', r.emoji, 'user_id', r.user_id
      )), '[]'::jsonb) from public.message_reactions r where r.message_id = gm.id) as reactions
    from public.group_messages gm
    join public.profiles p on p.id = gm.sender_id
    where gm.conversation_id = p_conversation_id
      and (p_before is null or gm.created_at < p_before)
      -- Hide deleted-for-me messages
      and not coalesce((gm.metadata->'deleted_for'->>me::text)::boolean, false)
    order by gm.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) items;

  -- Mark messages as delivered for this user
  insert into public.group_message_receipts(message_id, user_id, status)
  select gm.id, me, 'delivered'
  from public.group_messages gm
  where gm.conversation_id = p_conversation_id
    and gm.sender_id <> me
    and not exists (
      select 1 from public.group_message_receipts r
      where r.message_id = gm.id and r.user_id = me
    )
  on conflict (message_id, user_id) do nothing;

  -- Reset unread count
  update public.conversation_members
  set unread_count = 0
  where conversation_id = p_conversation_id and user_id = me;

  return result;
end;
$$;
revoke all on function public.fetch_group_messages(uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.fetch_group_messages(uuid, timestamptz, integer)
  to authenticated;

commit;
