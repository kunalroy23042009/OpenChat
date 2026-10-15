-- Group lifecycle controls. Only the owner can delete a group or transfer
-- ownership; deletion cascades through conversation-owned rows.

create or replace function public.delete_conversation_group(
  p_conversation_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  conv_type varchar;
  my_role varchar;
begin
  if me is null then raise exception 'Sign in required'; end if;

  select c.type into conv_type
  from public.conversations c where c.id = p_conversation_id;
  if conv_type is null then raise exception 'Group not found'; end if;
  if conv_type <> 'group' then raise exception 'Only groups can be deleted here'; end if;

  select cm.role into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = me;
  if my_role is distinct from 'owner' then
    raise exception 'Only the group owner can delete this group';
  end if;

  -- Remove members first so the membership-change trigger can safely advance
  -- the sender-key epoch while the parent row still exists.
  delete from public.conversation_members
  where conversation_id = p_conversation_id;
  delete from public.conversations where id = p_conversation_id;
end;
$$;
revoke all on function public.delete_conversation_group(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_conversation_group(uuid) to authenticated;

create or replace function public.transfer_conversation_ownership(
  p_conversation_id uuid,
  p_new_owner_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  conv_type varchar;
  target_role varchar;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select c.type into conv_type
  from public.conversations c where c.id = p_conversation_id;
  if conv_type <> 'group' then raise exception 'Only groups support ownership transfer'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me and cm.role = 'owner'
  ) then raise exception 'Only the group owner can transfer ownership'; end if;
  if p_new_owner_id = me then raise exception 'Choose another group member'; end if;

  select cm.role into target_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id and cm.user_id = p_new_owner_id;
  if target_role is null then raise exception 'New owner must be a group member'; end if;

  update public.conversation_members
  set role = case when user_id = p_new_owner_id then 'owner' else 'admin' end
  where conversation_id = p_conversation_id and user_id in (me, p_new_owner_id);
end;
$$;
revoke all on function public.transfer_conversation_ownership(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.transfer_conversation_ownership(uuid, uuid)
  to authenticated;
