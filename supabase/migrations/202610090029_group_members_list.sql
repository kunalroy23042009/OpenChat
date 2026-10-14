-- Member roster for group admin UI (badges, kick). Members can already
-- read only their own membership row (conv_members_read), so this scoped
-- RPC returns the roster with display names for conversations the caller
-- belongs to. No global directory: membership implies visibility.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
create or replace function public.list_conversation_members(p_conversation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = me) then
    raise exception 'Not a member';
  end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.joined_at), '[]'::jsonb)
  into result from (
    select m.user_id, m.role, m.joined_at, p.display_name, p.username
    from public.conversation_members m
    join public.profiles p on p.id = m.user_id
    where m.conversation_id = p_conversation_id
  ) items;
  return result;
end;
$$;
revoke all on function public.list_conversation_members(uuid) from public, anon, authenticated;
grant execute on function public.list_conversation_members(uuid) to authenticated;
