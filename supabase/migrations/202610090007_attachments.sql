-- Apply after 202610090006_kyber_signatures.sql.
-- Encrypted attachment transport: per-file reservations against a pilot byte
-- budget, verified sizes, recipient-scoped download coordinates, and garbage
-- collection. The server never sees plaintext, file keys, or nonces: those
-- travel inside the Signal-encrypted message. Actual R2 bytes and presigned
-- URLs are issued by a later Edge Function; these RPCs return coordinates only.
begin;

-- One row per intended upload. `reserved` rows hold budget until finalized or
-- expired; `uploaded` rows hold budget until retention passes.
create table public.attachment_blobs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  object_key text not null unique,
  expected_bytes integer not null check (expected_bytes between 1 and 10485760),
  actual_bytes integer check (actual_bytes between 1 and 10485760),
  status text not null default 'reserved'
    check (status in ('reserved', 'uploaded')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  retained_until timestamptz,
  check (owner_id <> recipient_id)
);
create index attachment_blobs_owner on public.attachment_blobs(owner_id, created_at);
create index attachment_blobs_recipient on public.attachment_blobs(recipient_id, created_at);
alter table public.attachment_blobs enable row level security;
revoke all on public.attachment_blobs from anon, authenticated;

-- Reserves budget and mints an object key. Aborts when the file or the
-- resulting active budget would exceed the pilot allowance.
create function public.reserve_attachment(p_recipient_id uuid, p_bytes integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  active bigint;
  row public.attachment_blobs;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_recipient_id is null or p_recipient_id = me then
    raise exception 'Contact unavailable';
  end if;
  if p_bytes is null or p_bytes not between 1 and 10485760 then
    raise exception 'Invalid attachment size';
  end if;
  if not public.messaging_allowed(me, p_recipient_id) then
    raise exception 'Contact unavailable';
  end if;
  perform pg_advisory_xact_lock(hashtext('attachment-budget:' || me::text));
  select coalesce(sum(
    case when status = 'uploaded' then actual_bytes else expected_bytes end
  ), 0) into active from public.attachment_blobs
  where owner_id = me
    and (status = 'uploaded' or (status = 'reserved' and expires_at > now()));
  -- Pilot budget: 100 MiB of live (reserved + retained) bytes per user.
  if active + p_bytes > 104857600 then
    raise exception 'Attachment budget exhausted';
  end if;
  insert into public.attachment_blobs(
    owner_id, recipient_id, object_key, expected_bytes, expires_at)
  values (
    me, p_recipient_id,
    'attachments/' || me::text || '/' || gen_random_uuid()::text,
    p_bytes, now() + interval '15 minutes')
  returning * into row;
  return jsonb_build_object(
    'id', row.id, 'object_key', row.object_key,
    'expected_bytes', row.expected_bytes, 'expires_at', row.expires_at);
end;
$$;
revoke all on function public.reserve_attachment(uuid,integer) from public, anon, authenticated;
grant execute on function public.reserve_attachment(uuid,integer) to authenticated;

-- Confirms the real uploaded size. The Edge Function calls this after R2
-- reports the object; the client never self-certifies.
create function public.finalize_attachment(p_id uuid, p_actual_bytes integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  row public.attachment_blobs;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_actual_bytes is null or p_actual_bytes not between 1 and 10485760 then
    raise exception 'Invalid attachment size';
  end if;
  perform pg_advisory_xact_lock(hashtext('attachment-budget:' || me::text));
  update public.attachment_blobs set
    actual_bytes = p_actual_bytes,
    status = 'uploaded',
    retained_until = now() + interval '30 days'
  where id = p_id and owner_id = me and status = 'reserved' and expires_at > now()
  returning * into row;
  if not found then raise exception 'Reservation unavailable'; end if;
  if row.actual_bytes > row.expected_bytes then
    raise exception 'Uploaded size exceeds reservation';
  end if;
  return jsonb_build_object(
    'id', row.id, 'object_key', row.object_key,
    'actual_bytes', row.actual_bytes, 'retained_until', row.retained_until);
end;
$$;
revoke all on function public.finalize_attachment(uuid,integer) from public, anon, authenticated;
grant execute on function public.finalize_attachment(uuid,integer) to authenticated;

-- Download coordinates for the uploader or the declared recipient only.
-- Coordinates are useless without the file key inside the Signal message.
create function public.authorize_download(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  row public.attachment_blobs;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select * into row from public.attachment_blobs where id = p_id;
  if not found then raise exception 'Attachment unavailable'; end if;
  if me <> row.owner_id and me <> row.recipient_id then
    raise exception 'Attachment unavailable';
  end if;
  if row.status <> 'uploaded' or row.retained_until is null
     or row.retained_until < now() then
    raise exception 'Attachment unavailable';
  end if;
  return jsonb_build_object(
    'id', row.id, 'object_key', row.object_key,
    'actual_bytes', row.actual_bytes);
end;
$$;
revoke all on function public.authorize_download(uuid) from public, anon, authenticated;
grant execute on function public.authorize_download(uuid) to authenticated;

-- Drops abandoned reservations and retention-expired uploads, freeing budget.
create function public.cleanup_attachments()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  abandoned integer;
  expired integer;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  delete from public.attachment_blobs
  where status = 'reserved' and expires_at < now();
  get diagnostics abandoned = row_count;
  delete from public.attachment_blobs
  where status = 'uploaded' and retained_until < now();
  get diagnostics expired = row_count;
  return jsonb_build_object('abandoned', abandoned, 'expired', expired);
end;
$$;
revoke all on function public.cleanup_attachments() from public, anon, authenticated;
grant execute on function public.cleanup_attachments() to authenticated;
commit;
