-- Missing client-facing RPCs surfaced by the feature audit:
--   * two-factor (the 202610230001 migration is recorded as applied but its
--     objects are absent; its verify_totp also depended on hmac_sha1 and
--     base32 decode(), neither of which exists on this server)
--   * direct_unread_counts (chat-list unread badges)
-- Idempotent: safe to re-run.
begin;

alter table public.user_preferences
  add column if not exists totp_secret text,
  add column if not exists totp_enabled boolean not null default false,
  add column if not exists recovery_codes text[] default '{}';

-- Base32 (RFC 4648) decoder for TOTP secrets.
create or replace function public.base32_decode(p_input text)
returns bytea
language plpgsql
immutable
as $$
declare
  v_clean text := upper(coalesce(regexp_replace(p_input, '[^A-Za-z2-7]', '', 'g'), ''));
  alphabet text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  acc bit varying := B'';
  result bytea := ''::bytea;
  i int;
  idx int;
  full_bytes int;
  b int;
begin
  if v_clean = '' then
    return ''::bytea;
  end if;
  for i in 1 .. length(v_clean) loop
    idx := strpos(alphabet, substr(v_clean, i, 1));
    if idx > 0 then
      acc := acc || (idx - 1)::bit(5);
    end if;
  end loop;
  full_bytes := floor(length(acc) / 8);
  for i in 0 .. full_bytes - 1 loop
    b := (substring(acc from i * 8 + 1 for 8)::bit(8))::int;
    result := result || ('\x' || lpad(upper(to_hex(b)), 2, '0'))::bytea;
  end loop;
  return result;
end $$;

-- RFC 6238 TOTP: SHA1, 30s steps, 6 digits. Accepts the previous, current
-- and next time step so small clock drift never locks the user out.
create or replace function public.verify_totp(p_secret text, p_code text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  time_step bigint;
  step int;
  mac bytea;
  mac_offset int;
  code int;
begin
  if p_secret is null or p_code is null then
    return false;
  end if;
  if p_code !~ '^[0-9]{6}$' then
    return false;
  end if;
  time_step := floor(extract(epoch from clock_timestamp()) / 30)::bigint;
  for step in -1 .. 1 loop
    mac := extensions.hmac(
      public.base32_decode(p_secret),
      int8send(time_step + step),
      'sha1'
    );
    mac_offset := get_byte(mac, 19) & 15;
    code := (
      ((get_byte(mac, mac_offset) & 127) << 24) |
      ((get_byte(mac, mac_offset + 1) & 255) << 16) |
      ((get_byte(mac, mac_offset + 2) & 255) << 8) |
      (get_byte(mac, mac_offset + 3) & 255)
    ) % 1000000;
    if code = p_code::int then
      return true;
    end if;
  end loop;
  return false;
end $$;

-- Enable 2FA: the code from the authenticator app is verified against the
-- secret BEFORE anything is stored, so a mistyped secret can never lock
-- the account.
create or replace function public.enable_totp(
  p_secret text,
  p_recovery_codes text[],
  p_code text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_secret is null or length(p_secret) < 16 then
    raise exception 'Invalid setup key';
  end if;
  if not public.verify_totp(p_secret, p_code) then
    raise exception 'Invalid code';
  end if;
  insert into public.user_preferences (user_id, totp_secret, totp_enabled, recovery_codes)
    values (me, p_secret, true, coalesce(p_recovery_codes, '{}'))
    on conflict (user_id) do update
      set totp_secret = excluded.totp_secret,
          totp_enabled = true,
          recovery_codes = excluded.recovery_codes;
end $$;
revoke all on function public.enable_totp(text, text[], text) from public, anon;
grant execute on function public.enable_totp(text, text[], text) to authenticated;

create or replace function public.disable_totp(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  secret text;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select totp_secret into secret from public.user_preferences where user_id = me;
  if secret is null or not public.verify_totp(secret, p_code) then
    raise exception 'Invalid code';
  end if;
  update public.user_preferences
    set totp_secret = null, totp_enabled = false, recovery_codes = '{}'
    where user_id = me;
end $$;
revoke all on function public.disable_totp(text) from public, anon;
grant execute on function public.disable_totp(text) to authenticated;

create or replace function public.use_recovery_code(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  codes text[];
begin
  if me is null then raise exception 'Sign in required'; end if;
  select recovery_codes into codes from public.user_preferences where user_id = me;
  if codes is null or p_code = any(codes) is not true then
    raise exception 'Invalid recovery code';
  end if;
  codes := array_remove(codes, p_code);
  update public.user_preferences
    set recovery_codes = codes, totp_enabled = false, totp_secret = null
    where user_id = me;
end $$;
revoke all on function public.use_recovery_code(text) from public, anon;
grant execute on function public.use_recovery_code(text) to authenticated;

-- Chat-list unread dots: pending encrypted activity per peer, keyed by
-- sender id. Includes transport controls on purpose (callers show a dot,
-- not an exact count).
create or replace function public.direct_unread_counts()
returns json
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return '{}'::json;
  end if;
  return (
    select coalesce(jsonb_object_agg(sender_id::text, n), '{}'::jsonb)::json
    from (
      select sender_id, count(*)::int as n
      from public.message_envelopes
      where recipient_id = me
        and read_at is null
        and (expires_at is null or expires_at > now())
      group by sender_id
    ) t
  );
end $$;
revoke all on function public.direct_unread_counts() from public, anon;
grant execute on function public.direct_unread_counts() to authenticated;

commit;
