-- Fix group send failure: jsonb_object_length() does not exist in
-- Postgres (only json_object_length for json). Count object keys instead.
-- Idempotent: recreates publish_group_sender_key with the same signature.
begin;
create or replace function public.publish_group_sender_key(
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
  given integer;
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
  select count(*) into given from jsonb_object_keys(p_envelopes);
  if given <> expected then
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
commit;
