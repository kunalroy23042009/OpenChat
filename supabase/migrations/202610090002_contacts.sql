-- Apply after 202610090001_foundation.sql.
begin;
alter table public.profiles add column username text unique
  check (username ~ '^[a-z][a-z0-9_]{2,23}$');

create table public.contact_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create unique index contact_requests_pair on public.contact_requests
  (least(sender_id, recipient_id), greatest(sender_id, recipient_id));
create index contact_requests_recipient on public.contact_requests(recipient_id);
create index contact_requests_sender on public.contact_requests(sender_id);
alter table public.contact_requests enable row level security;
revoke all on public.contact_requests from anon, authenticated;
grant select on public.contact_requests to authenticated;
create policy requests_participant_read on public.contact_requests for select to authenticated
  using ((select auth.uid()) in (sender_id, recipient_id));

create table public.contact_blocks (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  primary key (owner_id, blocked_id), check (owner_id <> blocked_id)
);
alter table public.contact_blocks enable row level security;
revoke all on public.contact_blocks from anon, authenticated;
grant select on public.contact_blocks to authenticated;
create policy blocks_owner_read on public.contact_blocks for select to authenticated
  using (owner_id = (select auth.uid()));

-- Bounded to one counter row per account. No client table privileges.
create table public.contact_invite_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_start date not null,
  attempts integer not null
);
alter table public.contact_invite_limits enable row level security;
revoke all on public.contact_invite_limits from anon, authenticated;

create function public.save_profile(p_display_name text, p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if char_length(trim(p_display_name)) not between 1 and 60
     or p_display_name is null or p_username is null
     or lower(trim(p_username)) !~ '^[a-z][a-z0-9_]{2,23}$' then
    raise exception 'Enter a name and a valid username';
  end if;
  update public.profiles set display_name = trim(p_display_name), username = lower(trim(p_username)) where id = me;
end;
$$;

create function public.send_contact_invite(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); target uuid; used integer; existing public.contact_requests;
begin
  if me is null then raise exception 'Sign in required'; end if;
  -- Return expected failures instead of throwing so attempt accounting commits.
  insert into public.contact_invite_limits as limits(user_id, window_start, attempts)
  values (me, (now() at time zone 'UTC')::date, 1)
  on conflict (user_id) do update set
    attempts = case when limits.window_start = excluded.window_start then least(limits.attempts + 1, 21) else 1 end,
    window_start = excluded.window_start
  returning attempts into used;
  if used > 20 then return 'rate_limited'; end if;
  if not exists(select 1 from public.profiles where id = me and username is not null) then return 'profile_required'; end if;
  select id into target from public.profiles where username = lower(trim(p_username));
  if target is null or target = me then return 'unavailable'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(least(me,target)::text || greatest(me,target)::text, 0));
  if exists(select 1 from public.contact_blocks where (owner_id = me and blocked_id = target) or (owner_id = target and blocked_id = me)) then return 'unavailable'; end if;
  select * into existing from public.contact_requests where least(sender_id,recipient_id) = least(me,target) and greatest(sender_id,recipient_id) = greatest(me,target);
  if found then
    if existing.status = 'accepted' then return 'already_connected'; end if;
    if existing.status = 'declined' then return 'unavailable'; end if;
    if existing.sender_id = me then return 'already_sent'; end if;
    return 'incoming_pending';
  end if;
  insert into public.contact_requests(sender_id,recipient_id) values(me,target);
  return 'sent';
end;
$$;

create function public.respond_contact_invite(p_request_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); request public.contact_requests;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select * into request from public.contact_requests where id = p_request_id and recipient_id = me;
  if not found then raise exception 'Invitation unavailable'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(least(me,request.sender_id)::text || greatest(me,request.sender_id)::text, 0));
  if exists(select 1 from public.contact_blocks where (owner_id = me and blocked_id = request.sender_id) or (owner_id = request.sender_id and blocked_id = me)) then raise exception 'Invitation unavailable'; end if;
  update public.contact_requests set status = case when p_accept then 'accepted' else 'declined' end
    where id = p_request_id and recipient_id = me and status = 'pending';
  if not found then raise exception 'Invitation already handled'; end if;
end;
$$;

create function public.block_contact(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_user_id is null or p_user_id = me then raise exception 'Contact unavailable'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(least(me,p_user_id)::text || greatest(me,p_user_id)::text, 0));
  if not exists(select 1 from public.contact_requests where (sender_id = me and recipient_id = p_user_id) or (sender_id = p_user_id and recipient_id = me)) then raise exception 'Contact unavailable'; end if;
  insert into public.contact_blocks(owner_id,blocked_id) values(me,p_user_id) on conflict do nothing;
  delete from public.contact_requests where (sender_id = me and recipient_id = p_user_id) or (sender_id = p_user_id and recipient_id = me);
end;
$$;

create function public.unblock_contact(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(least(me,p_user_id)::text || greatest(me,p_user_id)::text, 0));
  delete from public.contact_blocks where owner_id = me and blocked_id = p_user_id;
end;
$$;

-- Return only names/usernames of participants already related to the caller.
-- There is no global directory or unrestricted username lookup endpoint.
create function public.list_my_contacts()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at desc), '[]'::jsonb) into result from (
    select r.id as request_id, p.id as user_id, p.display_name, p.username, r.status,
      (r.recipient_id = me) as incoming, r.created_at
    from public.contact_requests r join public.profiles p
      on p.id = case when r.sender_id = me then r.recipient_id else r.sender_id end
    where me in (r.sender_id,r.recipient_id) and r.status in ('pending','accepted')
      and not exists(select 1 from public.contact_blocks b where (b.owner_id = me and b.blocked_id = p.id) or (b.owner_id = p.id and b.blocked_id = me))
    union all
    select null::uuid, p.id, p.display_name, p.username, 'blocked', false, p.created_at
    from public.contact_blocks b join public.profiles p on p.id = b.blocked_id where b.owner_id = me
  ) items;
  return result;
end;
$$;

create function public.cancel_contact_invite(p_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  delete from public.contact_requests where id = p_request_id and sender_id = me and status = 'pending';
  if not found then raise exception 'Invitation unavailable or already handled'; end if;
end;
$$;

create function public.delete_account()
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  delete from public.profiles where id = me;
  delete from auth.users where id = me;
end;
$$;

revoke all on function public.save_profile(text,text) from public, anon, authenticated;
revoke all on function public.send_contact_invite(text) from public, anon, authenticated;
revoke all on function public.respond_contact_invite(uuid,boolean) from public, anon, authenticated;
revoke all on function public.cancel_contact_invite(uuid) from public, anon, authenticated;
revoke all on function public.block_contact(uuid) from public, anon, authenticated;
revoke all on function public.unblock_contact(uuid) from public, anon, authenticated;
revoke all on function public.list_my_contacts() from public, anon, authenticated;
revoke all on function public.delete_account() from public, anon, authenticated;
grant execute on function public.save_profile(text,text) to authenticated;
grant execute on function public.send_contact_invite(text) to authenticated;
grant execute on function public.respond_contact_invite(uuid,boolean) to authenticated;
grant execute on function public.cancel_contact_invite(uuid) to authenticated;
grant execute on function public.block_contact(uuid) to authenticated;
grant execute on function public.unblock_contact(uuid) to authenticated;
grant execute on function public.list_my_contacts() to authenticated;
grant execute on function public.delete_account() to authenticated;
commit;
