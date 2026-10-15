-- Status privacy fix:
--   * "except" previously allowed ANY authenticated non-listed user to read a
--     status. Both "only" and "except" must also be accepted contacts now.
--   * publish_status validates the audience/allow-list combination.

drop policy if exists status_read on public.status_updates;
drop policy if exists status_author_read on public.status_updates;
drop policy if exists status_audience_read on public.status_updates;

create policy status_read on public.status_updates
  for select to authenticated
  using (
    author_id = (select auth.uid())
    or (
      expires_at > now()
      and author_id <> (select auth.uid())
      -- Every non-author viewer must be an accepted contact of the author.
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
      and (
        audience = 'contacts'
        or (audience = 'only' and (select auth.uid()) = any(audience_user_ids))
        or (audience = 'except' and not ((select auth.uid()) = any(audience_user_ids)))
      )
    )
  );

create or replace function public.publish_status(
  p_type varchar, p_content text default null, p_media_url text default null,
  p_background_color integer default null, p_audience varchar default 'contacts',
  p_audience_user_ids uuid[] default '{}'
) returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result uuid; v_audience uuid[];
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_type not in ('text','image','video') or p_audience not in ('contacts','except','only')
    then raise exception 'Invalid status'; end if;

  -- Only share with accepted contacts; drop any non-contact ids and self.
  select coalesce(array_agg(cid), '{}') into v_audience
  from unnest(coalesce(p_audience_user_ids, '{}')) as cid
  where cid <> me
    and exists (
      select 1 from public.contact_requests c
      where c.status = 'accepted'
        and ((c.sender_id = me and c.recipient_id = cid)
          or (c.recipient_id = me and c.sender_id = cid))
    );

  if p_audience = 'only' and array_length(v_audience, 1) is null then
    raise exception 'Choose at least one contact to share with';
  end if;

  insert into public.status_updates(author_id,type,content,media_url,background_color,audience,audience_user_ids)
  values(me,p_type,nullif(trim(p_content),''),p_media_url,p_background_color,p_audience,v_audience)
  returning id into result;
  return result;
end $$;

revoke all on function public.publish_status(varchar,text,text,integer,varchar,uuid[])
  from public, anon, authenticated;
grant execute on function public.publish_status(varchar,text,text,integer,varchar,uuid[])
  to authenticated;
