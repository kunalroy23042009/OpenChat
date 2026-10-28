-- Receipts privacy + presence privacy + unread-count regression fix.
--
-- 1. mark_messages_read gains a p_share_receipts switch: users with read
--    receipts off still clear their unread badge locally (WhatsApp parity)
--    without lifting the read state to the sender.
-- 2. direct_unread_counts: back to the durable receipt cursor
--    (202610220001) and now honors the local-only read marker.
-- 3. update_presence: publishing presence while last-seen is "Nobody" is
--    suppressed server-side so the client cannot leak online state.

begin;

alter table public.envelope_receipts
  add column if not exists local_read_at timestamptz;

-- The one-argument overload leaks read state unconditionally on the old
-- call path; only the privacy-aware signature remains.
drop function if exists public.mark_messages_read(uuid[]);

create or replace function public.mark_messages_read(
  p_ids uuid[],
  p_share_receipts boolean default true
)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare me uuid := auth.uid(); marked integer; share boolean;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 100 then
    raise exception 'Invalid read batch';
  end if;
  share := coalesce(p_share_receipts, true);
  if share and exists (
    select 1 from public.user_preferences where user_id = me and not read_receipts
  ) then
    share := false;
  end if;
  -- Shared blue-tick state: only written with the user's consent.
  if share then
    update public.envelope_receipts
    set read_at = coalesce(read_at, now())
    where recipient_id = me and envelope_id = any(p_ids)
      and expires_at > now() and read_at is null;
  end if;
  -- Local read marker: always advances so unread badges clear even when
  -- receipts stay private.
  update public.envelope_receipts
  set local_read_at = coalesce(local_read_at, now())
  where recipient_id = me and envelope_id = any(p_ids)
    and expires_at > now();
  get diagnostics marked = row_count;
  return marked;
end $function$;
revoke all on function public.mark_messages_read(uuid[], boolean) from public, anon, authenticated;
grant execute on function public.mark_messages_read(uuid[], boolean) to authenticated;

create or replace function public.direct_unread_counts()
returns json
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return '{}'::json;
  end if;
  return (
    select coalesce(jsonb_object_agg(sender_id::text, n), '{}'::jsonb)::json
    from (
      select sender_id, count(*)::int as n
      from public.envelope_receipts
      where recipient_id = me
        and expires_at > now()
        and coalesce(read_at, local_read_at) is null
      group by sender_id
    ) t
  );
end $$;
revoke all on function public.direct_unread_counts() from public, anon;
grant execute on function public.direct_unread_counts() to authenticated;

create or replace function public.update_presence(
  p_is_online boolean,
  p_custom_status character varying default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare me uuid := auth.uid(); privacy text;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select last_seen_privacy into privacy
    from public.user_preferences where user_id = me;
  if privacy = 'nobody' then
    -- Hidden entirely: never publish is_online, never advance last_seen.
    update public.profiles
    set is_online = false,
        custom_status = coalesce(p_custom_status, custom_status)
    where id = me;
    return;
  end if;
  update public.profiles
  set is_online = p_is_online,
      last_seen = case when not p_is_online then now() else last_seen end,
      custom_status = coalesce(p_custom_status, custom_status)
  where id = me;
end;
$function$;
revoke all on function public.update_presence(boolean, character varying) from public, anon;
grant execute on function public.update_presence(boolean, character varying) to authenticated;

commit;
