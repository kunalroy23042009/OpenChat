-- Pending ciphertext must count before a chat acknowledges delivery.
-- Status viewing obeys audience, blocking, and read-receipt consent.
begin;

create or replace function public.direct_unread_counts()
returns json language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then return '{}'::json; end if;
  return (
    select coalesce(jsonb_object_agg(sender_id::text, n), '{}'::jsonb)::json
    from (
      select sender_id, count(*)::int as n from (
        select e.id, e.sender_id from public.message_envelopes e
        where e.recipient_id = me
          and (e.expires_at is null or e.expires_at > now())
        union
        select r.envelope_id, r.sender_id from public.envelope_receipts r
        where r.recipient_id = me
          and (r.expires_at is null or r.expires_at > now())
          and coalesce(r.read_at, r.local_read_at) is null
      ) activity group by sender_id
    ) counts
  );
end $$;
revoke all on function public.direct_unread_counts() from public, anon;
grant execute on function public.direct_unread_counts() to authenticated;

create or replace function public.mark_status_viewed(p_status_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); owner uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select s.author_id into owner from public.status_updates s
  where s.id = p_status_id and s.expires_at > now()
    and (s.author_id = me or (
      exists (select 1 from public.contact_requests c
        where c.status = 'accepted'
          and ((c.sender_id = me and c.recipient_id = s.author_id)
            or (c.recipient_id = me and c.sender_id = s.author_id)))
      and (s.audience = 'contacts'
        or (s.audience = 'only' and me = any(s.audience_user_ids))
        or (s.audience = 'except' and not (me = any(s.audience_user_ids))))
      and not exists (select 1 from public.contact_blocks b
        where (b.owner_id = me and b.blocked_id = s.author_id)
           or (b.owner_id = s.author_id and b.blocked_id = me))
    ));
  if owner is null then raise exception 'Status unavailable'; end if;
  if owner = me then return; end if;
  if exists (select 1 from public.user_preferences
    where user_id = me and not read_receipts) then return; end if;
  insert into public.status_views(status_id, viewer_id) values(p_status_id, me)
  on conflict do nothing;
end $$;
revoke all on function public.mark_status_viewed(uuid) from public, anon;
grant execute on function public.mark_status_viewed(uuid) to authenticated;

-- A receipt-disabled author cannot inspect the viewer list either.
create or replace function public.status_viewers(p_status_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if exists (select 1 from public.user_preferences
    where user_id = me and not read_receipts) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'viewer_id', v.viewer_id, 'display_name', p.display_name,
    'viewed_at', v.viewed_at) order by v.viewed_at desc), '[]'::jsonb)
  into result from public.status_views v
  join public.status_updates s on s.id = v.status_id
  join public.profiles p on p.id = v.viewer_id
  where v.status_id = p_status_id and s.author_id = me
    and not exists (select 1 from public.contact_blocks b
      where (b.owner_id = me and b.blocked_id = v.viewer_id)
         or (b.owner_id = v.viewer_id and b.blocked_id = me));
  return result;
end $$;
revoke all on function public.status_viewers(uuid) from public, anon;
grant execute on function public.status_viewers(uuid) to authenticated;
commit;
