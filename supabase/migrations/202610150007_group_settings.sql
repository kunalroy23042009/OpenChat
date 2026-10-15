-- WhatsApp-style group settings: admins/owners can rename a group, change its
-- description, and update its photo URL. Direct conversations are immutable.

create or replace function public.update_conversation(
  p_conversation_id uuid,
  p_title varchar default null,
  p_description text default null,
  p_avatar_url text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  my_role varchar;
  conv_type varchar;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select c.type into conv_type
  from public.conversations c where c.id = p_conversation_id;
  if conv_type is null then raise exception 'Conversation not found'; end if;
  if conv_type = 'direct' then
    raise exception 'Direct conversations cannot be edited';
  end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;
  if my_role is null then raise exception 'Not a member'; end if;
  if my_role not in ('admin', 'owner') then
    raise exception 'Only admins can edit group settings';
  end if;

  if p_title is not null and (char_length(p_title) < 1 or char_length(p_title) > 100) then
    raise exception 'Group name must be 1-100 characters';
  end if;
  if p_description is not null and char_length(p_description) > 500 then
    raise exception 'Description is too long (500 characters max)';
  end if;

  update public.conversations
  set title = coalesce(p_title, title),
      description = coalesce(p_description, description),
      avatar_url = coalesce(p_avatar_url, avatar_url)
  where id = p_conversation_id;
end;
$$;
revoke all on function public.update_conversation(uuid, varchar, text, text)
  from public, anon, authenticated;
grant execute on function public.update_conversation(uuid, varchar, text, text)
  to authenticated;
