begin;
-- Rotatable bearer invitations: knowing a conversation UUID never grants access.
create or replace function public.group_invite_link(p_conversation_id uuid, p_reset boolean default false)
returns text language plpgsql security definer set search_path = '' as $$
declare code text;
begin
  perform 1 from public.conversations where id = p_conversation_id and type = 'group' for update;
  if not found then raise exception 'Group unavailable'; end if;
  if not exists (select 1 from public.conversation_members where conversation_id = p_conversation_id
    and user_id = auth.uid() and role in ('owner','admin')) then
    raise exception 'Only admins can manage invite links';
  end if;
  update public.conversations set invite_code = replace(gen_random_uuid()::text,'-','')
    where id = p_conversation_id and (p_reset or invite_code is null or length(invite_code) < 32);
  select invite_code into code from public.conversations where id = p_conversation_id;
  return code;
end $$;

create or replace function public.preview_group_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare grp public.conversations;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into grp from public.conversations where invite_code = p_code and type = 'group';
  if not found then raise exception 'This invitation has expired or was reset'; end if;
  return jsonb_build_object('title',grp.title,'description',grp.description,
    'require_approval',grp.require_approval,'member_count',
    (select count(*) from public.conversation_members where conversation_id = grp.id));
end $$;

create or replace function public.join_group_by_invite(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare grp public.conversations;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into grp from public.conversations where invite_code = p_code and type = 'group' for update;
  if not found then raise exception 'This invitation has expired or was reset'; end if;
  if exists (select 1 from public.conversation_members where conversation_id = grp.id and user_id = auth.uid()) then
    return grp.id;
  end if;
  if grp.require_approval then raise exception 'Ask a group admin to add you'; end if;
  if (select count(*) from public.conversation_members where conversation_id = grp.id) >= 1024 then
    raise exception 'This group is full';
  end if;
  insert into public.conversation_members(conversation_id,user_id,role,last_read_at)
    values (grp.id,auth.uid(),'member',now());
  return grp.id;
end $$;

create or replace function public.add_conversation_member(p_conversation_id uuid, p_user_id uuid, p_role varchar default 'member')
returns void language plpgsql security definer set search_path = '' as $$
declare my_role varchar;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  perform 1 from public.conversations where id = p_conversation_id and type in ('group','channel') for update;
  if not found then raise exception 'Group unavailable'; end if;
  select role into my_role from public.conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid();
  if my_role is null or my_role not in ('owner','admin') then raise exception 'Only admins can add members'; end if;
  if p_role is null or p_role not in ('member','admin') then raise exception 'Invalid member role'; end if;
  if not public.messaging_allowed(auth.uid(),p_user_id) then raise exception 'Add an accepted contact'; end if;
  if (select count(*) from public.conversation_members where conversation_id = p_conversation_id) >= 1024 then
    raise exception 'This group is full';
  end if;
  insert into public.conversation_members(conversation_id,user_id,role,last_read_at)
    values(p_conversation_id,p_user_id,p_role,now()) on conflict do nothing;
end $$;

revoke all on function public.group_invite_link(uuid,boolean) from public, anon;
revoke all on function public.preview_group_invite(text) from public, anon;
revoke all on function public.join_group_by_invite(text) from public, anon;
grant execute on function public.group_invite_link(uuid,boolean) to authenticated;
grant execute on function public.preview_group_invite(text) to authenticated;
grant execute on function public.join_group_by_invite(text) to authenticated;
commit;
