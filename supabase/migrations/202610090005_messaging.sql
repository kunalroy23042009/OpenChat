-- Apply after 202610090004_push_tokens.sql.
-- Encrypted messaging transport: public key material, single-use prekey
-- claims, and per-recipient ciphertext envelopes. Plaintext bodies and
-- private keys must never appear in these tables. Single-device pilot.
begin;

-- One published bundle per user. Readable only through claim_key_bundle.
create table public.key_bundles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  identity_key text not null check (char_length(identity_key) between 32 and 128),
  registration_id integer not null check (registration_id between 1 and 16380),
  signed_prekey_id integer not null check (signed_prekey_id >= 0),
  signed_prekey text not null check (char_length(signed_prekey) between 32 and 256),
  signed_prekey_signature text not null check (char_length(signed_prekey_signature) between 32 and 256),
  updated_at timestamptz not null default now()
);
alter table public.key_bundles enable row level security;
revoke all on public.key_bundles from anon, authenticated;

create table public.one_time_prekeys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prekey_id integer not null check (prekey_id >= 0),
  public_key text not null check (char_length(public_key) between 32 and 256),
  claimed_at timestamptz,
  unique (user_id, prekey_id)
);
create index one_time_prekeys_available on public.one_time_prekeys(user_id) where claimed_at is null;
alter table public.one_time_prekeys enable row level security;
revoke all on public.one_time_prekeys from anon, authenticated;

create table public.kyber_prekeys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prekey_id integer not null check (prekey_id >= 0),
  public_key text not null check (char_length(public_key) between 256 and 4096),
  claimed_at timestamptz,
  unique (user_id, prekey_id)
);
create index kyber_prekeys_available on public.kyber_prekeys(user_id) where claimed_at is null;
alter table public.kyber_prekeys enable row level security;
revoke all on public.kyber_prekeys from anon, authenticated;

-- Ciphertext envelopes. Deleted on acknowledgment; expire after 7 days.
create table public.message_envelopes (
  id uuid primary key default gen_random_uuid(),
  client_message_id text not null check (char_length(client_message_id) between 1 and 64),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  ciphertext text not null check (char_length(ciphertext) between 1 and 8192),
  protocol_version integer not null default 4 check (protocol_version = 4),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  check (sender_id <> recipient_id),
  unique (sender_id, client_message_id)
);
create index message_envelopes_recipient on public.message_envelopes(recipient_id, created_at);
alter table public.message_envelopes enable row level security;
revoke all on public.message_envelopes from anon, authenticated;

create table public.message_send_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_start date not null,
  attempts integer not null
);
alter table public.message_send_limits enable row level security;
revoke all on public.message_send_limits from anon, authenticated;

-- Two users may exchange keys/messages only with an accepted connection
-- and no block in either direction.
create function public.messaging_allowed(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.contact_requests r
    where r.status = 'accepted'
      and ((r.sender_id = a and r.recipient_id = b) or (r.sender_id = b and r.recipient_id = a))
  ) and not exists(
    select 1 from public.contact_blocks k
    where (k.owner_id = a and k.blocked_id = b) or (k.owner_id = b and k.blocked_id = a)
  );
$$;
revoke all on function public.messaging_allowed(uuid,uuid) from public, anon, authenticated;

create function public.publish_key_bundle(
  p_identity_key text, p_registration_id integer,
  p_signed_prekey_id integer, p_signed_prekey text, p_signed_prekey_signature text,
  p_prekeys jsonb, p_kyber jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if char_length(p_identity_key) not between 32 and 128
     or p_registration_id not between 1 and 16380
     or p_signed_prekey_id < 0
     or char_length(p_signed_prekey) not between 32 and 256
     or char_length(p_signed_prekey_signature) not between 32 and 256
     or jsonb_typeof(p_prekeys) <> 'array' or jsonb_array_length(p_prekeys) not between 1 and 50
     or jsonb_typeof(p_kyber) <> 'array' or jsonb_array_length(p_kyber) not between 1 and 10 then
    raise exception 'Invalid key bundle';
  end if;
  if exists(select 1 from jsonb_array_elements(p_prekeys) e
            where e->>'id' is null or e->>'key' is null
               or char_length(e->>'key') not between 32 and 256) then
    raise exception 'Invalid one-time prekey';
  end if;
  if exists(select 1 from jsonb_array_elements(p_kyber) e
            where e->>'id' is null or e->>'key' is null
               or char_length(e->>'key') not between 256 and 4096) then
    raise exception 'Invalid kyber prekey';
  end if;
  insert into public.key_bundles as bundle(user_id, identity_key, registration_id, signed_prekey_id, signed_prekey, signed_prekey_signature, updated_at)
  values (me, p_identity_key, p_registration_id, p_signed_prekey_id, p_signed_prekey, p_signed_prekey_signature, now())
  on conflict (user_id) do update set identity_key = excluded.identity_key, registration_id = excluded.registration_id,
    signed_prekey_id = excluded.signed_prekey_id, signed_prekey = excluded.signed_prekey,
    signed_prekey_signature = excluded.signed_prekey_signature, updated_at = now();
  delete from public.one_time_prekeys where user_id = me;
  delete from public.kyber_prekeys where user_id = me;
  insert into public.one_time_prekeys(user_id, prekey_id, public_key)
  select me, (e->>'id')::integer, e->>'key' from jsonb_array_elements(p_prekeys) e;
  insert into public.kyber_prekeys(user_id, prekey_id, public_key)
  select me, (e->>'id')::integer, e->>'key' from jsonb_array_elements(p_kyber) e;
end;
$$;
revoke all on function public.publish_key_bundle(text,integer,integer,text,text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.publish_key_bundle(text,integer,integer,text,text,jsonb,jsonb) to authenticated;

-- Atomically hands out one EC prekey and one kyber prekey. A claimed prekey
-- is never issued twice (SKIP LOCKED keeps concurrent claims distinct).
create function public.claim_key_bundle(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); bundle public.key_bundles; ec public.one_time_prekeys; ky public.kyber_prekeys;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_user_id is null or p_user_id = me then raise exception 'Contact unavailable'; end if;
  if not public.messaging_allowed(me, p_user_id) then raise exception 'Contact unavailable'; end if;
  select * into bundle from public.key_bundles where user_id = p_user_id;
  if not found then raise exception 'Contact has no published keys yet'; end if;
  update public.one_time_prekeys set claimed_at = now() where id = (
    select id from public.one_time_prekeys where user_id = p_user_id and claimed_at is null
    order by prekey_id limit 1 for update skip locked
  ) returning * into ec;
  update public.kyber_prekeys set claimed_at = now() where id = (
    select id from public.kyber_prekeys where user_id = p_user_id and claimed_at is null
    order by prekey_id limit 1 for update skip locked
  ) returning * into ky;
  return jsonb_build_object(
    'identity_key', bundle.identity_key, 'registration_id', bundle.registration_id,
    'signed_prekey_id', bundle.signed_prekey_id, 'signed_prekey', bundle.signed_prekey,
    'signed_prekey_signature', bundle.signed_prekey_signature,
    'prekey_id', ec.prekey_id, 'prekey', ec.public_key,
    'kyber_id', ky.prekey_id, 'kyber', ky.public_key);
end;
$$;
revoke all on function public.claim_key_bundle(uuid) from public, anon, authenticated;
grant execute on function public.claim_key_bundle(uuid) to authenticated;

-- Statuses keep quota accounting committed: sent, duplicate, unavailable,
-- invalid, rate_limited. Only sent/duplicate return envelope coordinates.
create function public.enqueue_message(p_recipient_id uuid, p_client_message_id text, p_ciphertext text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); used integer; envelope public.message_envelopes; inserted integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  insert into public.message_send_limits as limits(user_id, window_start, attempts)
  values (me, (now() at time zone 'UTC')::date, 1)
  on conflict (user_id) do update set
    attempts = case when limits.window_start = excluded.window_start then least(limits.attempts + 1, 501) else 1 end,
    window_start = excluded.window_start
  returning attempts into used;
  if used > 500 then return jsonb_build_object('status', 'rate_limited'); end if;
  if p_recipient_id is null or p_recipient_id = me then return jsonb_build_object('status', 'unavailable'); end if;
  if p_client_message_id is null or char_length(p_client_message_id) not between 1 and 64
     or p_ciphertext is null or char_length(p_ciphertext) not between 1 and 8192 then
    return jsonb_build_object('status', 'invalid');
  end if;
  if not public.messaging_allowed(me, p_recipient_id) then return jsonb_build_object('status', 'unavailable'); end if;
  insert into public.message_envelopes(client_message_id, sender_id, recipient_id, ciphertext, expires_at)
  values (p_client_message_id, me, p_recipient_id, p_ciphertext, now() + interval '7 days')
  on conflict (sender_id, client_message_id) do nothing;
  get diagnostics inserted = row_count;
  select * into envelope from public.message_envelopes where sender_id = me and client_message_id = p_client_message_id;
  if inserted = 0 then
    return jsonb_build_object('status', 'duplicate', 'id', envelope.id, 'expires_at', envelope.expires_at);
  end if;
  return jsonb_build_object('status', 'sent', 'id', envelope.id, 'expires_at', envelope.expires_at);
end;
$$;
revoke all on function public.enqueue_message(uuid,text,text) from public, anon, authenticated;
grant execute on function public.enqueue_message(uuid,text,text) to authenticated;

create function public.fetch_inbox(p_since timestamptz default null, p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at), '[]'::jsonb) into result from (
    select id, client_message_id, sender_id, ciphertext, protocol_version, created_at, expires_at
    from public.message_envelopes
    where recipient_id = me and expires_at > now()
      and (p_since is null or created_at > p_since)
    order by created_at limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) items;
  return result;
end;
$$;
revoke all on function public.fetch_inbox(timestamptz,integer) from public, anon, authenticated;
grant execute on function public.fetch_inbox(timestamptz,integer) to authenticated;

create function public.ack_messages(p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); removed integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 100 then
    raise exception 'Invalid acknowledgment batch';
  end if;
  delete from public.message_envelopes where recipient_id = me and id = any(p_ids);
  get diagnostics removed = row_count;
  return removed;
end;
$$;
revoke all on function public.ack_messages(uuid[]) from public, anon, authenticated;
grant execute on function public.ack_messages(uuid[]) to authenticated;

create function public.cleanup_expired()
returns integer language plpgsql security definer set search_path = '' as $$
declare removed integer;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  delete from public.message_envelopes where expires_at < now();
  get diagnostics removed = row_count;
  return removed;
end;
$$;
revoke all on function public.cleanup_expired() from public, anon, authenticated;
grant execute on function public.cleanup_expired() to authenticated;
commit;
