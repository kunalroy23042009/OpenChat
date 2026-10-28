-- Signal-standard resilience for drained one-time key pools.
--
-- publish_key_bundle is a one-shot wipe-and-replace at install, and
-- one-time keys are consumed by every incoming session. Once a peer's
-- pools drain, claim_key_bundle handed out null parts and senders failed
-- with "Contact must reopen the app to refresh one-time keys" until the
-- peer happened to reopen their app.
--
-- Real Signal solves this with long-lived signed prekeys: the bundle
-- always carries a reusable Kyber prekey (PQXDH needs it), while the
-- one-time EC prekey is optional (X3DH proceeds from the signed prekey).
-- This migration adds exactly that:
--   * key_bundles gains persistent signed-Kyber columns, captured from
--     the first Kyber entry of every publish and top-up.
--   * claim_key_bundle falls back to them when the one-time pool is
--     empty — without consuming anything. Reuse across senders is safe:
--     the client store keeps Kyber records forever and replay detection
--     keys on the handshake's ephemeral base key.
--   * Existing users are backfilled from their published Kyber rows.
begin;

alter table public.key_bundles
  add column if not exists signed_kyber_id integer,
  add column if not exists signed_kyber text,
  add column if not exists signed_kyber_signature text;

-- Backfill: existing users keep every Kyber record on-device (their store
-- never deletes them), so any published row works as the persistent key.
-- Prefer an unclaimed row, else the newest one.
with picked as (
  select distinct on (kp.user_id)
    kp.user_id, kp.prekey_id, kp.public_key, kp.signature
  from public.kyber_prekeys kp
  order by kp.user_id, (kp.claimed_at is null) desc, kp.prekey_id desc
)
update public.key_bundles kb
set signed_kyber_id = p.prekey_id,
    signed_kyber = p.public_key,
    signed_kyber_signature = p.signature
from picked p
where kb.user_id = p.user_id;

-- Publish: store the first Kyber entry as the long-lived signed prekey
-- alongside the one-shot pools.
create or replace function public.publish_key_bundle(
  p_identity_key text, p_registration_id integer,
  p_signed_prekey_id integer, p_signed_prekey text, p_signed_prekey_signature text,
  p_prekeys jsonb, p_kyber jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); kyber0 jsonb := p_kyber->0;
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
            where e->>'id' is null or e->>'key' is null or e->>'signature' is null
               or char_length(e->>'key') not between 256 and 4096
               or char_length(e->>'signature') not between 32 and 256) then
    raise exception 'Invalid kyber prekey';
  end if;
  insert into public.key_bundles as bundle(user_id, identity_key, registration_id, signed_prekey_id, signed_prekey, signed_prekey_signature, signed_kyber_id, signed_kyber, signed_kyber_signature, updated_at)
  values (me, p_identity_key, p_registration_id, p_signed_prekey_id, p_signed_prekey, p_signed_prekey_signature, (kyber0->>'id')::integer, kyber0->>'key', kyber0->>'signature', now())
  on conflict (user_id) do update set identity_key = excluded.identity_key, registration_id = excluded.registration_id,
    signed_prekey_id = excluded.signed_prekey_id, signed_prekey = excluded.signed_prekey,
    signed_prekey_signature = excluded.signed_prekey_signature,
    signed_kyber_id = excluded.signed_kyber_id, signed_kyber = excluded.signed_kyber,
    signed_kyber_signature = excluded.signed_kyber_signature, updated_at = now();
  delete from public.one_time_prekeys where user_id = me;
  delete from public.kyber_prekeys where user_id = me;
  insert into public.one_time_prekeys(user_id, prekey_id, public_key)
  select me, (e->>'id')::integer, e->>'key' from jsonb_array_elements(p_prekeys) e;
  insert into public.kyber_prekeys(user_id, prekey_id, public_key, signature)
  select me, (e->>'id')::integer, e->>'key', e->>'signature' from jsonb_array_elements(p_kyber) e;
end;
$$;
revoke all on function public.publish_key_bundle(text,integer,integer,text,text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.publish_key_bundle(text,integer,integer,text,text,jsonb,jsonb) to authenticated;

-- Claim: when the one-time Kyber pool is empty, serve the long-lived
-- signed Kyber prekey instead of null. Nothing is consumed in that path,
-- so every sender gets a usable bundle. The one-time EC prekey may still
-- be null; senders build those sessions from the signed prekey alone.
create or replace function public.claim_key_bundle(p_user_id uuid)
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
    'kyber_id', coalesce(ky.prekey_id, bundle.signed_kyber_id),
    'kyber', coalesce(ky.public_key, bundle.signed_kyber),
    'kyber_signature', coalesce(ky.signature, bundle.signed_kyber_signature));
end;
$$;
revoke all on function public.claim_key_bundle(uuid) from public, anon, authenticated;
grant execute on function public.claim_key_bundle(uuid) to authenticated;

-- Top-up: while refilling one-time pools, also heal the persistent
-- signed-Kyber prekey when it is missing (users whose install predates
-- the persistent columns).
create or replace function public.top_up_prekeys(p_prekeys jsonb, p_kyber jsonb)
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
  update public.key_bundles
    set signed_kyber_id = (p_kyber->0->>'id')::integer,
        signed_kyber = p_kyber->0->>'key',
        signed_kyber_signature = p_kyber->0->>'signature'
    where user_id = me and signed_kyber_id is null;
  return jsonb_build_object('ec_added', added_ec, 'kyber_added', added_kyber);
end;
$$;
revoke all on function public.top_up_prekeys(jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.top_up_prekeys(jsonb,jsonb) to authenticated;

commit;
