-- Group unread fix: track a per-member read cursor (timestamp) instead of
-- relying on unread_count being zeroed by every fetch (incl. pagination).

-- 0. Enable Realtime for conversation_members so unread badges stay live.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversation_members'
  ) then
    alter publication supabase_realtime add table public.conversation_members;
  end if;
end $$;

-- 1. Columns: last_read_at cursor. Drop the earlier bigint attempt (group_messages.id is a UUID).
alter table conversation_members
  add column if not exists last_read_at timestamptz;
alter table conversation_members
  drop column if exists last_read_message_id;

-- 2. Explicit mark_group_read RPC.
drop function if exists public.mark_group_read(uuid, bigint);
drop function if exists public.mark_group_read(uuid, timestamptz);

create function public.mark_group_read(
  p_conversation_id uuid,
  p_read_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update conversation_members
  set last_read_at = greatest(coalesce(last_read_at, to_timestamp(0)), p_read_at),
      unread_count = 0
  where conversation_id = p_conversation_id
    and user_id = auth.uid();
end;
$$;

grant execute on function public.mark_group_read(uuid, timestamptz) to authenticated;

-- 3. Unread count function using last_read_at.
drop function if exists public.get_group_unread_count(uuid);

create function public.get_group_unread_count(p_conversation_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last_read timestamptz;
  v_count int;
begin
  select last_read_at
  into v_last_read
  from conversation_members
  where conversation_id = p_conversation_id
    and user_id = auth.uid();

  if v_last_read is null then
    select count(*) into v_count
    from group_messages
    where conversation_id = p_conversation_id;
  else
    select count(*) into v_count
    from group_messages
    where conversation_id = p_conversation_id
      and created_at > v_last_read;
  end if;

  return v_count;
end;
$$;

grant execute on function public.get_group_unread_count(uuid) to authenticated;

-- 4. fetch_group_messages: keep delivery receipts, but do NOT reset unread_count
--    (client calls mark_group_read when the newest message is visible). This
--    prevents silent read-clearing during background pagination.
create or replace function public.fetch_group_messages(
  p_conversation_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;

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
      p.avatar_url as sender_avatar,
      (select coalesce(jsonb_agg(jsonb_build_object(
        'emoji', r.emoji, 'user_id', r.user_id
      )), '[]'::jsonb) from public.message_reactions r where r.message_id = gm.id) as reactions
    from public.group_messages gm
    join public.profiles p on p.id = gm.sender_id
    where gm.conversation_id = p_conversation_id
      and (p_before is null or gm.created_at < p_before)
      and not coalesce((gm.metadata->'deleted_for'->>me::text)::boolean, false)
    order by gm.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) items;

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

  return result;
end;
$$;
revoke all on function public.fetch_group_messages(uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.fetch_group_messages(uuid, timestamptz, integer)
  to authenticated;
