begin;

-- Any current member may pin a message. The previous implementation exposed
-- pinning in the client but rejected ordinary members, making the action look
-- broken. Every mutation also verifies that the message belongs to the group.
create or replace function public.pin_message(
  p_conversation_id uuid,
  p_message_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  message_conversation_id uuid;
  pin_count integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = me
  ) then
    raise exception 'Not a member of this conversation';
  end if;

  select conversation_id into message_conversation_id
  from public.group_messages
  where id = p_message_id and not is_deleted;
  if not found or message_conversation_id <> p_conversation_id then
    raise exception 'Message is not in this conversation';
  end if;

  if exists (
    select 1 from public.pinned_messages
    where conversation_id = p_conversation_id and message_id = p_message_id
  ) then
    delete from public.pinned_messages
    where conversation_id = p_conversation_id and message_id = p_message_id;
    return;
  end if;

  select count(*) into pin_count from public.pinned_messages
  where conversation_id = p_conversation_id;
  if pin_count >= 3 then
    raise exception 'Cannot pin more than 3 messages per conversation';
  end if;

  insert into public.pinned_messages(conversation_id, message_id, pinned_by)
  values (p_conversation_id, p_message_id, me);
end;
$$;
revoke all on function public.pin_message(uuid, uuid) from public, anon;
grant execute on function public.pin_message(uuid, uuid) to authenticated;

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
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = msg.conversation_id and user_id = me
  ) then
    raise exception 'Not a member of this conversation';
  end if;

  if p_for_everyone then
    if msg.sender_id <> me then
      raise exception 'Can only delete your own messages for everyone';
    end if;
    if msg.created_at < now() - interval '60 hours' then
      raise exception 'Cannot delete for everyone after 60 hours';
    end if;
    update public.group_messages
    set is_deleted = true, content = 'This message was deleted'
    where id = p_message_id;
  else
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
revoke all on function public.delete_group_message(uuid, boolean) from public, anon;
grant execute on function public.delete_group_message(uuid, boolean) to authenticated;

commit;
