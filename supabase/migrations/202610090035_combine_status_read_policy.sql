-- Combine the author's visibility and active-audience visibility into one
-- SELECT policy to avoid repeated permissive-policy evaluation per row.
begin;

drop policy if exists status_author_read on public.status_updates;
drop policy if exists status_audience_read on public.status_updates;

create policy status_read on public.status_updates
  for select to authenticated
  using (
    author_id = (select auth.uid())
    or (
      expires_at > now()
      and author_id <> (select auth.uid())
      and (
        (audience = 'only' and (select auth.uid()) = any(audience_user_ids))
        or (audience = 'except' and not ((select auth.uid()) = any(audience_user_ids)))
        or (
          audience = 'contacts'
          and exists (
            select 1 from public.contact_requests c
            where c.status = 'accepted'
              and (
                (c.sender_id = status_updates.author_id
                  and c.recipient_id = (select auth.uid()))
                or (c.recipient_id = status_updates.author_id
                  and c.sender_id = (select auth.uid()))
              )
          )
        )
      )
    )
  );

commit;
