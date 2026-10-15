-- WhatsApp-style group admin management: promote/demote members.
--   * Owners can promote any member and demote admins.
--   * Admins can promote members but cannot demote other admins or the owner.
--   * The owner role can only be transferred via transfer_group_ownership.

create or replace function public.set_conversation_member_role(
  p_conversation_id uuid,
  p_user_id uuid,
  p_role varchar
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  my_role varchar;
  target_role varchar;
  conv_type varchar;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_role not in ('admin', 'member') then
    raise exception 'Role must be admin or member';
  end if;

  select c.type into conv_type
  from public.conversations c where c.id = p_conversation_id;
  if conv_type not in ('group', 'channel') then
    raise exception 'Roles apply only to groups';
  end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;
  if my_role is null then raise exception 'Not a member'; end if;
  if my_role not in ('admin', 'owner') then
    raise exception 'Only admins can change roles';
  end if;

  select cm.role into target_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = p_user_id;
  if target_role is null then raise exception 'User is not a member'; end if;
  if target_role = 'owner' then raise exception 'Cannot change the owner role'; end if;
  if my_role = 'admin' and target_role = 'admin' then
    raise exception 'Admins cannot change other admins';
  end if;

  update public.conversation_members
  set role = p_role
  where conversation_id = p_conversation_id and user_id = p_user_id;
end;
$$;
revoke all on function public.set_conversation_member_role(uuid, uuid, varchar)
  from public, anon, authenticated;
grant execute on function public.set_conversation_member_role(uuid, uuid, varchar)
  to authenticated;
