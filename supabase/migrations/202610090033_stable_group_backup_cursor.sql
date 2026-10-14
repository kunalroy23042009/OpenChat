-- Stable composite cursor prevents same-timestamp group messages from being
-- skipped between encrypted backup pages.
begin;

drop function public.backup_group_messages(uuid, timestamptz, integer);

create function public.backup_group_messages(
  p_conversation_id uuid,
  p_before timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 100
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then
    raise exception 'Not a member of this conversation';
  end if;

  select coalesce(
    jsonb_agg(to_jsonb(items) order by items.created_at, items.id),
    '[]'::jsonb
  ) into result
  from (
    select
      gm.id, gm.conversation_id, gm.sender_id, gm.parent_message_id,
      gm.content, gm.type, gm.media_url, gm.metadata,
      gm.is_edited, gm.edited_at, gm.is_deleted,
      gm.is_view_once, gm.is_forwarded, gm.forward_count,
      gm.created_at,
      p.display_name as sender_name,
      exists (
        select 1 from public.pinned_messages pm
        where pm.conversation_id = gm.conversation_id
          and pm.message_id = gm.id
      ) as is_pinned,
      exists (
        select 1 from public.starred_messages sm
        where sm.message_id = gm.id and sm.user_id = me
      ) as is_starred,
      (select coalesce(jsonb_agg(jsonb_build_object(
        'emoji', r.emoji, 'user_id', r.user_id
      )), '[]'::jsonb)
       from public.message_reactions r where r.message_id = gm.id) as reactions
    from public.group_messages gm
    join public.profiles p on p.id = gm.sender_id
    where gm.conversation_id = p_conversation_id
      and (
        p_before is null
        or gm.created_at < p_before
        or (gm.created_at = p_before and gm.id < p_before_id)
      )
      and not coalesce((gm.metadata->'deleted_for'->>me::text)::boolean, false)
    order by gm.created_at desc, gm.id desc
    limit least(greatest(coalesce(p_limit, 100), 1), 100)
  ) items;

  return result;
end;
$$;

revoke all on function public.backup_group_messages(uuid, timestamptz, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.backup_group_messages(uuid, timestamptz, uuid, integer)
  to authenticated;

commit;
