-- Two-factor authentication (TOTP) and recovery codes
-- Apply after 202610150013_private_profile_photos_and_visibility.sql
begin;

alter table public.user_preferences
  add column if not exists totp_secret text,
  add column if not exists totp_enabled boolean not null default false,
  add column if not exists recovery_codes text[] default '{}';

create or replace function public.enable_totp(p_secret text, p_recovery_codes text[])
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  update public.user_preferences
    set totp_secret = p_secret, totp_enabled = true, recovery_codes = p_recovery_codes
    where user_id = me;
end $$;
grant execute on function public.enable_totp(text,text[]) to authenticated;

create or replace function public.disable_totp(p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); secret text; valid boolean;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select totp_secret into secret from public.user_preferences where user_id = me;
  if secret is null then return false; end if;
  -- Verify TOTP code (30s window, SHA1, 6 digits)
  valid := public.verify_totp(secret, p_code);
  if not valid then return false; end if;
  update public.user_preferences
    set totp_secret = null, totp_enabled = false, recovery_codes = '{}'
    where user_id = me;
  return true;
end $$;
grant execute on function public.disable_totp(text) to authenticated;

create or replace function public.use_recovery_code(p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); codes text[];
begin
  if me is null then raise exception 'Sign in required'; end if;
  select recovery_codes into codes from public.user_preferences where user_id = me;
  if codes is null or p_code = any(codes) is not true then return false; end if;
  codes := array_remove(codes, p_code);
  update public.user_preferences
    set recovery_codes = codes, totp_enabled = false, totp_secret = null
    where user_id = me;
  return true;
end $$;
grant execute on function public.use_recovery_code(text) to authenticated;

-- TOTP verification helper (RFC 6238, SHA1, 30s, 6 digits)
create or replace function public.verify_totp(p_secret text, p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  time_step bigint := floor(extract(epoch from now()) / 30)::bigint;
  hmac bytea;
  offset int;
  code int;
begin
  -- secret is base32 encoded, decode it
  hmac := hmac_sha1(decode(p_secret, 'base32'), time_step::bigint::bytea);
  offset := (get_byte(hmac, 19) & 15) + 1;
  code := ((get_byte(hmac, offset) & 127) << 24 |
           (get_byte(hmac, offset + 1) & 255) << 16 |
           (get_byte(hmac, offset + 2) & 255) << 8 |
           (get_byte(hmac, offset + 3) & 255)) % 1000000;
  return code = p_code::int;
end $$;

commit;