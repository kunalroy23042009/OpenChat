-- Group member avatars: extend member roster and message fetch with sender avatar

-- 1. Extend list_conversation_members to include avatar_url
--    (replaces 202610090029_group_members_list.sql)
drop function if exists public.list_conversation_members(uuid);

create function public.list_conversation_members(p_conv_id uuid)
returns table (
  member_id uuid,
  display_name text,
  username text,
  role text,
  avatar_url text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    cm.member_id,
    coalesce(p.display_name, 'User') as display_name,
    coalesce(p.username, 'user') as username,
    cm.role,
    p.avatar_url
  from conversation_members cm
  join profiles p on p.id = cm.member_id
  where cm.conversation_id = p_conv_id
  order by cm.role desc, p.display_name;
end;
$$;

grant execute on function public.list_conversation_members(uuid) to authenticated;

-- 2. Extend fetch_group_messages to include sender_avatar
--    (replaces 202610090015_conversation_rpcs.sql section)
drop function if exists public.fetch_group_messages(uuid, int, int);

create function public.fetch_group_messages(
  p_conversation_id uuid,
  p_limit int default 50,
  p_offset int default 0
)
returns table (
  id bigint,
  conversation_id uuid,
  sender_id uuid,
  sender_name text,
  sender_avatar text,
  content text,
  created_at timestamptz,
  reply_to bigint,
  reply_preview text,
  reply_sender_name text,
  message_type text,
  media_url text,
  media_type text,
  media_name text,
  media_size bigint,
  view_once boolean,
  edited_at timestamptz,
  is_starred boolean,
  is_pinned boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    gm.id,
    gm.conversation_id,
    gm.sender_id,
    coalesce(p.display_name, 'User') as sender_name,
    p.avatar_url as sender_avatar,
    gm.content,
    gm.created_at,
    gm.reply_to,
    gm.reply_preview,
    gm.reply_sender_name,
    gm.message_type,
    gm.media_url,
    gm.media_type,
    gm.media_name,
    gm.media_size,
    gm.view_once,
    gm.edited_at,
    coalesce(sm.is_starred, false) as is_starred,
    coalesce(pm.is_pinned, false) as is_pinned
  from group_messages gm
  join profiles p on p.id = gm.sender_id
  left join starred_messages sm
    on sm.message_id = gm.id
    and sm.user_id = auth.uid()
  left join pinned_messages pm
    on pm.message_id = gm.id
    and pm.conversation_id = p_conversation_id
  where gm.conversation_id = p_conversation_id
  order by gm.created_at desc
  limit p_limit
  offset p_offset;
end;
$$;

grant execute on function public.fetch_group_messages(uuid, int, int) to authenticated;

-- 3. Realtime already publishes group_messages; avatar will be included in INSERT/UPDATE payloads
--    No additional migration needed for realtime.