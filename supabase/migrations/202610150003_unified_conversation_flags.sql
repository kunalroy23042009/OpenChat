-- Unified per-member conversation flags (mute/pin/archive/lock/favourite) and
-- expose them on list_conversations so groups behave like direct chats.

-- 1. Add is_favourite if missing (is_locked/marked_unread/muted_until already exist).
alter table conversation_members
  add column if not exists is_favourite boolean not null default false;

-- 2. Single RPC to flip member flags. Null args are left unchanged.
create or replace function public.set_conversation_member_flags(
  p_conversation_id uuid,
  p_is_muted boolean default null,
  p_muted_until timestamptz default null,
  p_is_pinned boolean default null,
  p_is_archived boolean default null,
  p_is_locked boolean default null,
  p_is_favourite boolean default null,
  p_marked_unread boolean default null
)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists(
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = me
  ) then
    raise exception 'Not a member of this conversation';
  end if;

  update conversation_members
  set is_muted = coalesce(p_is_muted, is_muted),
      muted_until = case
        when p_is_muted is false then null
        when p_is_muted is true then p_muted_until
        else muted_until
      end,
      is_pinned = coalesce(p_is_pinned, is_pinned),
      is_archived = coalesce(p_is_archived, is_archived),
      is_locked = coalesce(p_is_locked, is_locked),
      is_favourite = coalesce(p_is_favourite, is_favourite),
      marked_unread = coalesce(p_marked_unread, marked_unread),
      unread_count = case
        when p_marked_unread is true then greatest(unread_count, 1)
        else unread_count
      end
  where conversation_id = p_conversation_id and user_id = me;
end;
$$;
revoke all on function public.set_conversation_member_flags(
  uuid, boolean, timestamptz, boolean, boolean, boolean, boolean, boolean
) from public, anon, authenticated;
grant execute on function public.set_conversation_member_flags(
  uuid, boolean, timestamptz, boolean, boolean, boolean, boolean, boolean
) to authenticated;

-- 3. Expose the extra flags + last_activity on list_conversations.
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
      cm.is_locked, cm.is_favourite, cm.marked_unread, cm.muted_until,
      cm.last_read_at, cm.unread_count,
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
