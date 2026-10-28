-- Direct-message unread counts per sender. Uses envelope_receipts.read_at to
-- distinguish delivered-but-unread envelopes. Returns {sender_id, count}.
-- Never exposes message content or keys.
begin;
create or replace function public.direct_unread_counts()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_object_agg(sender_id::text, cnt), '{}'::jsonb)
  into result
  from (
    select sender_id, count(*) as cnt
    from public.envelope_receipts
    where recipient_id = me
      and expires_at > now()
      and read_at is null
    group by sender_id
  ) sub;
  return result;
end $$;
revoke all on function public.direct_unread_counts() from public, anon, authenticated;
grant execute on function public.direct_unread_counts() to authenticated;
commit;