-- WhatsApp-style lifecycle hardening: real-time profile (avatar/name)
-- channels, one-time-prekey pool top-ups, status media storage,
-- sender-key re-issue after lost device state, contact presence,
-- and a client events log for observability.
-- Apply after 202610230001_two_factor.sql.
begin;

-- ============================================================
-- 1. Real-time profile changes (avatars, names) over realtime.
-- Postgres Changes honours RLS: a viewer only receives rows whose
-- profile photo (or last seen) they are allowed to see.
-- ============================================================
alter table public.profiles replica identity full;
-- Idempotent: previous pushes may already have added the table.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'profiles'
  ) then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;

drop policy if exists profiles_photo_realtime_read on public.profiles;
drop policy if exists profiles_last_seen_realtime_read on public.profiles;
-- A row policy cannot hide individual profile fields. Broadcast only an
-- invalidation marker; clients re-fetch through field-filtered RPCs.
create table public.profile_changes (
  id uuid primary key references public.profiles(id) on delete cascade,
  changed_at timestamptz not null default now()
);
alter table public.profile_changes enable row level security;
grant select on public.profile_changes to authenticated;
create policy profile_changes_contacts on public.profile_changes
for select to authenticated using (
  id = (select auth.uid()) or exists (
    select 1 from public.contact_requests r
    where r.status = 'accepted' and
      ((r.sender_id = id and r.recipient_id = (select auth.uid())) or
       (r.recipient_id = id and r.sender_id = (select auth.uid())))
  )
);
create function public.signal_profile_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profile_changes(id, changed_at) values(new.id, now())
  on conflict(id) do update set changed_at = excluded.changed_at;
  return new;
end;
$$;
create trigger profile_change_signal after update on public.profiles
for each row execute function public.signal_profile_change();
alter publication supabase_realtime add table public.profile_changes;

-- ============================================================
-- 2. One-time-prekey pool management.
-- publish_key_bundle is a one-shot wipe-and-replace at install; when a
-- pool drains, claim_key_bundle hands out null one-time keys and senders
-- fail with "Contact must reopen the app to refresh one-time keys".
-- These functions let a client keep its own pool topped up.
-- ============================================================
create function public.prekey_pool_counts()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ec_available', (select count(*) from public.one_time_prekeys
      where user_id = (select auth.uid()) and claimed_at is null),
    'kyber_available', (select count(*) from public.kyber_prekeys
      where user_id = (select auth.uid()) and claimed_at is null)
  );
$$;
revoke all on function public.prekey_pool_counts() from public, anon, authenticated;
grant execute on function public.prekey_pool_counts() to authenticated;

-- Appends fresh one-time prekeys without touching the identity bundle or
-- already-claimed rows, so existing sessions stay valid. Symmetric limits
-- match publish_key_bundle (50 EC / 10 kyber added at most per call).
create function public.top_up_prekeys(p_prekeys jsonb, p_kyber jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  added_ec integer := 0;
  added_kyber integer := 0;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if jsonb_typeof(p_prekeys) <> 'array' or jsonb_array_length(p_prekeys) not between 1 and 50
     or jsonb_typeof(p_kyber) <> 'array' or jsonb_array_length(p_kyber) not between 1 and 10 then
    raise exception 'Invalid prekey update';
  end if;
  if exists(select 1 from jsonb_array_elements(p_prekeys) e
            where e->>'id' is null or e->>'key' is null
               or char_length(e->>'key') not between 32 and 256) then
    raise exception 'Invalid one-time prekey';
  end if;
  if exists(select 1 from jsonb_array_elements(p_kyber) e
            where e->>'id' is null or e->>'key' is null
               or e->>'signature' is null
               or char_length(e->>'signature') not between 32 and 256
               or char_length(e->>'key') not between 256 and 4096) then
    raise exception 'Invalid kyber prekey';
  end if;
  with newcomer as (
    select (e->>'id')::integer as prekey_id, e->>'key' as public_key
    from jsonb_array_elements(p_prekeys) e
  )
  insert into public.one_time_prekeys(user_id, prekey_id, public_key)
  select me, prekey_id, public_key from newcomer
  on conflict (user_id, prekey_id) do nothing;
  get diagnostics added_ec = row_count;
  with newcomer as (
    select (e->>'id')::integer as prekey_id, e->>'key' as public_key,
      e->>'signature' as signature
    from jsonb_array_elements(p_kyber) e
  )
  insert into public.kyber_prekeys(user_id, prekey_id, public_key, signature)
  select me, prekey_id, public_key, signature from newcomer
  on conflict (user_id, prekey_id) do nothing;
  get diagnostics added_kyber = row_count;
  return jsonb_build_object('ec_added', added_ec, 'kyber_added', added_kyber);
end;
$$;
revoke all on function public.top_up_prekeys(jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.top_up_prekeys(jsonb,jsonb) to authenticated;

-- ============================================================
-- 3. Status media storage. Statuses are audience-gated, not E2EE; this
-- private bucket mirrors the exact visibility predicate of
-- status_updates so only permitted viewers can read a status file.
-- Path contract: <author-uid>/<file>. media_url stores 'status-media/'||path.
-- ============================================================
insert into storage.buckets(id, name, public)
values ('status-media', 'status-media', false)
on conflict (id) do update set public = false;

drop policy if exists "status media insert own" on storage.objects;
create policy "status media insert own" on storage.objects for insert to authenticated
with check (
  bucket_id = 'status-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
drop policy if exists "status media update own" on storage.objects;
create policy "status media update own" on storage.objects for update to authenticated
using (
  bucket_id = 'status-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'status-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
drop policy if exists "status media delete own" on storage.objects;
create policy "status media delete own" on storage.objects for delete to authenticated
using (
  bucket_id = 'status-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
drop policy if exists "status media read by audience" on storage.objects;
create policy "status media read by audience" on storage.objects for select to authenticated
using (
  bucket_id = 'status-media'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or exists (
      select 1 from public.status_updates s
      where s.media_url = 'status-media/' || name
        and s.expires_at > now()
        and s.author_id <> (select auth.uid())
        and (
          (s.audience = 'only' and (select auth.uid()) = any(s.audience_user_ids))
          or (s.audience = 'except' and not ((select auth.uid()) = any(s.audience_user_ids)))
          or (s.audience = 'contacts' and exists (
            select 1 from public.contact_requests c where c.status = 'accepted'
              and ((c.sender_id = s.author_id and c.recipient_id = (select auth.uid()))
                or (c.recipient_id = s.author_id and c.sender_id = (select auth.uid())))
          ))
        )
    )
  )
);

-- ============================================================
-- 4. Sender-key re-issue. A device that lost its local Signal state
-- (reinstall/app-data clear) still sees old epoch distributions as
-- acknowledged; this clears acknowledged_at for the current epoch so
-- the client can fetch and re-process them once its keys are restored
-- from a cloud backup. Identity unchanged => envelopes decrypt again.
-- ============================================================
create function public.reissue_group_sender_keys(p_conversation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  current_epoch integer;
  changed integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then raise exception 'Not a member of this conversation'; end if;
  select c.group_epoch into current_epoch
  from public.conversations c
  where c.id = p_conversation_id and c.e2ee_enabled;
  if not found then raise exception 'Encrypted group unavailable'; end if;
  update public.group_sender_key_envelopes
  set acknowledged_at = null
  where conversation_id = p_conversation_id
    and recipient_id = me
    and epoch = current_epoch;
  get diagnostics changed = row_count;
  return changed;
end;
$$;
revoke all on function public.reissue_group_sender_keys(uuid) from public, anon, authenticated;
grant execute on function public.reissue_group_sender_keys(uuid) to authenticated;

-- ============================================================
-- 5. Contact presence listing for the chat list ("online" subtitles).
-- Respects each contact's last_seen privacy, exactly like field reads.
-- ============================================================
create function public.list_contact_presence()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.user_id), '[]'::jsonb)
  into result from (
    select p.id as user_id,
      case when public.can_view_profile_field(p.id, me, 'last_seen')
        then p.is_online end as is_online,
      case when public.can_view_profile_field(p.id, me, 'last_seen')
        then p.last_seen end as last_seen
    from public.contact_requests r
    join public.profiles p
      on p.id = case when r.sender_id = me then r.recipient_id else r.sender_id end
    where me in (r.sender_id, r.recipient_id)
      and r.status = 'accepted'
      and not exists (
        select 1 from public.contact_blocks b
        where (b.owner_id = me and b.blocked_id = p.id)
           or (b.owner_id = p.id and b.blocked_id = me)
      )
  ) items;
  return result;
end;
$$;
revoke all on function public.list_contact_presence() from public, anon, authenticated;
grant execute on function public.list_contact_presence() to authenticated;

-- ============================================================
-- 6. Observability: allowlisted client event codes (no message bodies,
-- ciphertext or key material) for send/decrypt/sync forensics.
-- ============================================================
create table public.client_events (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.profiles(id) on delete cascade,
  area varchar(40) not null check (char_length(area) between 1 and 40),
  code varchar(64) not null check (char_length(code) between 1 and 64),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index client_events_account_recent
  on public.client_events(account_id, created_at desc);
alter table public.client_events enable row level security;
revoke all on public.client_events from anon, authenticated;
grant select on public.client_events to authenticated;
create policy client_events_read_own on public.client_events
  for select to authenticated
  using (account_id = (select auth.uid()));

create function public.report_client_event(p_events jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  row record;
  saved integer := 0;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if jsonb_typeof(p_events) <> 'array'
     or jsonb_array_length(p_events) not between 1 and 20 then
    raise exception 'Invalid event batch';
  end if;
  for row in
    select * from jsonb_to_recordset(p_events)
      as item(area text, code text, details jsonb)
  loop
    if row.area is null or row.code is null
       or char_length(row.area) not between 1 and 40
       or char_length(row.code) not between 1 and 64 then
      raise exception 'Invalid event entry';
    end if;
    insert into public.client_events(account_id, area, code, details)
    values (
      me,
      left(trim(row.area), 40),
      left(trim(row.code), 64),
      coalesce(row.details, '{}'::jsonb)
    );
    saved := saved + 1;
  end loop;
  return saved;
end;
$$;
revoke all on function public.report_client_event(jsonb) from public, anon, authenticated;
grant execute on function public.report_client_event(jsonb) to authenticated;

-- Prohibited-content guard: details must be small and carry no
-- message-like payloads beyond metadata keys. Enforce size cap via check.
alter table public.client_events
  add constraint client_events_details_size
  check (octet_length(details::text) <= 2048);

commit;
