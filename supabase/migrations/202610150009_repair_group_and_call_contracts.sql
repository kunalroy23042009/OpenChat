begin;

-- Restore the parameter/column contract used by the mobile client. The avatar
-- migration accidentally used member_id, although the table uses user_id.
drop function if exists public.list_conversation_members(uuid);
create function public.list_conversation_members(p_conversation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()) then
    raise exception 'Not a member';
  end if;
  return (select coalesce(jsonb_agg(to_jsonb(r) order by r.joined_at), '[]'::jsonb)
    from (select m.user_id, m.role, m.joined_at, p.display_name, p.username, p.avatar_url
      from public.conversation_members m join public.profiles p on p.id = m.user_id
      where m.conversation_id = p_conversation_id) r);
end $$;
revoke all on function public.list_conversation_members(uuid) from public, anon;
grant execute on function public.list_conversation_members(uuid) to authenticated;

create or replace function public.get_group_unread_count(p_conversation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare member public.conversation_members;
begin
  select * into member from public.conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid();
  if not found then raise exception 'Not a member'; end if;
  return (select count(*)::integer from public.group_messages g
    where g.conversation_id = p_conversation_id and g.sender_id <> auth.uid()
      and not g.is_deleted
      and g.created_at > coalesce(member.last_read_at, member.joined_at));
end $$;
revoke all on function public.get_group_unread_count(uuid) from public, anon;

create or replace function public.mark_group_read(p_conversation_id uuid, p_read_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_read_at is null then raise exception 'Read cursor required'; end if;
  update public.conversation_members
    set last_read_at = greatest(coalesce(last_read_at, joined_at), least(p_read_at, now())),
        marked_unread = false
    where conversation_id = p_conversation_id and user_id = auth.uid();
  if not found then raise exception 'Not a member'; end if;
  update public.conversation_members
    set unread_count = public.get_group_unread_count(p_conversation_id)
    where conversation_id = p_conversation_id and user_id = auth.uid();
end $$;
revoke all on function public.mark_group_read(uuid,timestamptz) from public, anon;

create or replace function public.list_conversations(p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(r) order by r.is_pinned desc,
    r.last_activity desc, r.id), '[]'::jsonb) from (
    select c.id, c.type, c.title, c.description, c.avatar_url, c.invite_code,
      c.require_approval, c.created_by, c.created_at, c.e2ee_enabled,
      m.role as my_role, m.is_muted, m.is_pinned, m.is_archived, m.is_locked,
      m.is_favourite, m.marked_unread, m.muted_until, m.last_read_at,
      public.get_group_unread_count(c.id) as unread_count,
      coalesce(last.created_at, c.created_at) as last_activity,
      case when c.e2ee_enabled then null else last.content end as last_message
    from public.conversations c
    join public.conversation_members m on m.conversation_id = c.id and m.user_id = auth.uid()
    left join lateral (select g.created_at, g.content from public.group_messages g
      where g.conversation_id = c.id order by g.created_at desc, g.id desc limit 1) last on true
    order by m.is_pinned desc, coalesce(last.created_at, c.created_at) desc, c.id
    limit least(greatest(coalesce(p_limit,50),1),100)
    offset greatest(coalesce(p_offset,0),0)
  ) r);
end $$;

-- Only the encrypted three-argument entry point is used by the app.
drop function if exists public.place_call(uuid,text);
create or replace function public.place_call(p_callee_id uuid, p_type text, p_encrypted_call_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); invite public.call_invites;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_callee_id is null or p_callee_id = me or not public.messaging_allowed(me,p_callee_id) then
    raise exception 'Contact unavailable';
  end if;
  if p_type is null or p_type not in ('voice','video') then raise exception 'Invalid call type'; end if;
  if p_encrypted_call_key is null or length(p_encrypted_call_key) not between 1 and 8192 then
    raise exception 'Encrypted call key required';
  end if;
  -- Serialize setup involving either participant, including simultaneous calls.
  perform id from public.profiles where id in (me,p_callee_id) order by id for update;
  update public.call_invites set status = 'ended'
    where status in ('ringing','accepted') and expires_at <= now()
      and (caller_id in (me,p_callee_id) or callee_id in (me,p_callee_id));
  if exists (select 1 from public.call_invites where status in ('ringing','accepted')
    and expires_at > now() and (caller_id in (me,p_callee_id) or callee_id in (me,p_callee_id))) then
    raise exception 'A participant is already in a call';
  end if;
  insert into public.call_invites(caller_id,callee_id,room,call_type,encrypted_call_key,expires_at)
    values (me,p_callee_id,'call_' || replace(gen_random_uuid()::text,'-',''),p_type,
      p_encrypted_call_key,now() + interval '60 seconds') returning * into invite;
  return jsonb_build_object('id',invite.id,'room',invite.room);
end $$;
revoke all on function public.place_call(uuid,text,text) from public, anon;
grant execute on function public.place_call(uuid,text,text) to authenticated;

create or replace function public.answer_call(p_invite_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_accept is null then raise exception 'Answer required'; end if;
  update public.call_invites
    set status = case when p_accept then 'accepted' else 'declined' end,
        expires_at = case when p_accept then now() + interval '6 hours' else expires_at end
    where id = p_invite_id and callee_id = auth.uid() and status = 'ringing'
      and expires_at > now();
  if not found then raise exception 'Call unavailable'; end if;
end $$;
-- Prevent direct writes from bypassing expiry, busy and contact checks.
revoke insert, update on public.call_invites from authenticated;
commit;
