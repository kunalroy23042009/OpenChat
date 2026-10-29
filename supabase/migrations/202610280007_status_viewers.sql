-- Status "Viewed by" list. Only the status author may call this for their
-- own statuses; returns viewer profile fields that RLS on profiles would
-- otherwise hide (profiles are self-select-only for peers).

begin;

create or replace function public.status_viewers(p_status_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'viewer_id', v.viewer_id,
      'display_name', p.display_name,
      'avatar_path', p.avatar_path,
      'viewed_at', v.viewed_at
    ) order by v.viewed_at desc),
    '[]'::jsonb
  ) into result
  from public.status_views v
  join public.status_updates s on s.id = v.status_id
  join public.profiles p on p.id = v.viewer_id
  where v.status_id = p_status_id
    and s.author_id = me;
  return result;
end $function$;

revoke all on function public.status_viewers(uuid) from public, anon;
grant execute on function public.status_viewers(uuid) to authenticated;

commit;
