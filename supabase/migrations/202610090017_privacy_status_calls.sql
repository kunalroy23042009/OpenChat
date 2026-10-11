-- Self-contained privacy, session, status, call-log and disappearing-message features.
-- Apply after 202610090016_team_collaboration.sql.
begin;

alter table public.devices
  add column if not exists device_token_hash text,
  add column if not exists os_version text,
  add column if not exists ip_address inet,
  add column if not exists last_active_at timestamptz not null default now(),
  add column if not exists is_primary boolean not null default false;

create unique index if not exists devices_user_token_unique
  on public.devices(user_id, device_token_hash) where device_token_hash is not null;

create table public.user_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  read_receipts boolean not null default true,
  last_seen_privacy varchar(20) not null default 'contacts'
    check (last_seen_privacy in ('everyone','contacts','nobody')),
  profile_photo_privacy varchar(20) not null default 'contacts'
    check (profile_photo_privacy in ('everyone','contacts','nobody')),
  status_privacy varchar(20) not null default 'contacts'
    check (status_privacy in ('contacts','except','only')),
  default_disappearing_seconds integer
    check (default_disappearing_seconds in (86400,604800,7776000)),
  focus_mode boolean not null default false,
  focus_message varchar(160),
  updated_at timestamptz not null default now()
);
alter table public.user_preferences enable row level security;
grant select, insert, update on public.user_preferences to authenticated;
create policy preferences_self on public.user_preferences for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

alter table public.conversation_members
  add column if not exists disappearing_seconds integer
    check (disappearing_seconds in (86400,604800,7776000)),
  add column if not exists is_locked boolean not null default false,
  add column if not exists marked_unread boolean not null default false,
  add column if not exists muted_until timestamptz;

create table public.status_updates (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  type varchar(10) not null check (type in ('text','image','video')),
  content text,
  media_url text,
  background_color integer,
  audience varchar(20) not null default 'contacts'
    check (audience in ('contacts','except','only')),
  audience_user_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  check (content is not null or media_url is not null)
);
create index status_updates_active on public.status_updates(expires_at, created_at desc);
alter table public.status_updates enable row level security;
grant select on public.status_updates to authenticated;
create policy status_author_read on public.status_updates for select to authenticated
  using (author_id = (select auth.uid()));
create policy status_audience_read on public.status_updates for select to authenticated
  using (expires_at > now() and author_id <> (select auth.uid()) and (
    (audience = 'only' and (select auth.uid()) = any(audience_user_ids)) or
    (audience = 'except' and not ((select auth.uid()) = any(audience_user_ids))) or
    (audience = 'contacts' and exists (
      select 1 from public.contact_requests c where c.status = 'accepted'
        and ((c.sender_id = author_id and c.recipient_id = (select auth.uid()))
          or (c.recipient_id = author_id and c.sender_id = (select auth.uid())))
    ))
  ));

create table public.status_views (
  status_id uuid not null references public.status_updates(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (status_id, viewer_id)
);
alter table public.status_views enable row level security;
grant select on public.status_views to authenticated;
create policy status_views_author_read on public.status_views for select to authenticated
  using (exists (select 1 from public.status_updates s
    where s.id = status_id and s.author_id = (select auth.uid())));

create table public.call_logs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  peer_id uuid references public.profiles(id) on delete set null,
  peer_label varchar(100),
  conversation_id uuid references public.conversations(id) on delete set null,
  call_type varchar(10) not null check (call_type in ('voice','video')),
  direction varchar(10) not null check (direction in ('incoming','outgoing')),
  outcome varchar(10) not null check (outcome in ('completed','missed','declined','failed')),
  started_at timestamptz not null default now(),
  duration_seconds integer not null default 0 check (duration_seconds >= 0),
  call_link_token text,
  scheduled_for timestamptz
);
create index call_logs_owner_started on public.call_logs(owner_id, started_at desc);
alter table public.call_logs enable row level security;
grant select, insert, delete on public.call_logs to authenticated;
create policy call_logs_self on public.call_logs for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

create or replace function public.upsert_preferences(p_values jsonb)
returns public.user_preferences language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result public.user_preferences;
begin
  if me is null then raise exception 'Sign in required'; end if;
  insert into public.user_preferences(user_id) values(me) on conflict do nothing;
  update public.user_preferences set
    read_receipts = coalesce((p_values->>'read_receipts')::boolean, read_receipts),
    last_seen_privacy = coalesce(p_values->>'last_seen_privacy', last_seen_privacy),
    profile_photo_privacy = coalesce(p_values->>'profile_photo_privacy', profile_photo_privacy),
    status_privacy = coalesce(p_values->>'status_privacy', status_privacy),
    default_disappearing_seconds = case when p_values ? 'default_disappearing_seconds'
      then (p_values->>'default_disappearing_seconds')::integer else default_disappearing_seconds end,
    focus_mode = coalesce((p_values->>'focus_mode')::boolean, focus_mode),
    focus_message = case when p_values ? 'focus_message' then p_values->>'focus_message' else focus_message end,
    updated_at = now()
  where user_id = me returning * into result;
  return result;
end $$;

create or replace function public.register_device_session(
  p_label text, p_platform text, p_token_hash text, p_os_version text default null,
  p_is_primary boolean default false
) returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_platform not in ('android','ios','web') then raise exception 'Invalid platform'; end if;
  if (select count(*) from public.devices where user_id = me) >= 10 and not exists
    (select 1 from public.devices where user_id = me and device_token_hash = p_token_hash)
    then raise exception 'Device limit reached'; end if;
  insert into public.devices(user_id,label,platform,device_token_hash,os_version,is_primary,last_active_at)
  values(me, left(trim(p_label),60), p_platform, p_token_hash, p_os_version, p_is_primary, now())
  on conflict (user_id,device_token_hash) where device_token_hash is not null do update
    set label=excluded.label, os_version=excluded.os_version, last_active_at=now()
  returning id into result;
  return result;
end $$;

create or replace function public.publish_status(
  p_type varchar, p_content text default null, p_media_url text default null,
  p_background_color integer default null, p_audience varchar default 'contacts',
  p_audience_user_ids uuid[] default '{}'
) returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result uuid;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_type not in ('text','image','video') or p_audience not in ('contacts','except','only')
    then raise exception 'Invalid status'; end if;
  insert into public.status_updates(author_id,type,content,media_url,background_color,audience,audience_user_ids)
  values(me,p_type,nullif(trim(p_content),''),p_media_url,p_background_color,p_audience,p_audience_user_ids)
  returning id into result;
  return result;
end $$;

create or replace function public.mark_status_viewed(p_status_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if not exists (select 1 from public.status_updates where id=p_status_id and expires_at>now())
    then raise exception 'Status unavailable'; end if;
  insert into public.status_views(status_id,viewer_id) values(p_status_id,auth.uid())
  on conflict do nothing;
end $$;

revoke all on function public.upsert_preferences(jsonb),
  public.register_device_session(text,text,text,text,boolean),
  public.publish_status(varchar,text,text,integer,varchar,uuid[]),
  public.mark_status_viewed(uuid) from public, anon, authenticated;
grant execute on function public.upsert_preferences(jsonb),
  public.register_device_session(text,text,text,text,boolean),
  public.publish_status(varchar,text,text,integer,varchar,uuid[]),
  public.mark_status_viewed(uuid) to authenticated;

commit;
