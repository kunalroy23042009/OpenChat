-- Apply after 202610090005_messaging.sql.
-- Session setup verifies the kyber prekey signature, so claims must carry it.
begin;
alter table public.kyber_prekeys
  add column signature text not null check (char_length(signature) between 32 and 256);

create or replace function public.publish_key_bundle(
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
            where e->>'id' is null or e->>'key' is null or e->>'signature' is null
               or char_length(e->>'key') not between 256 and 4096
               or char_length(e->>'signature') not between 32 and 256) then
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
  insert into public.kyber_prekeys(user_id, prekey_id, public_key, signature)
  select me, (e->>'id')::integer, e->>'key', e->>'signature' from jsonb_array_elements(p_kyber) e;
end;
$$;

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
    'kyber_id', ky.prekey_id, 'kyber', ky.public_key,
    'kyber_signature', ky.signature);
end;
$$;
commit;
