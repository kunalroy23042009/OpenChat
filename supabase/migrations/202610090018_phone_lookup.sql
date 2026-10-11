-- Phone-number identity & lookup. Numbers are self-asserted until an SMS
-- provider is enabled; the invite path reuses the username flow so rate
-- limits, blocks, and duplicate handling stay identical.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
alter table public.profiles
  add column if not exists phone_number text unique;
create index if not exists idx_profiles_phone_number
  on public.profiles (phone_number);

create or replace function public.set_my_phone(p_phone text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_phone is null or p_phone = '' then
    update public.profiles set phone_number = null where id = me;
    return;
  end if;
  if p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Enter a valid phone number (e.g. +14155552671).';
  end if;
  update public.profiles set phone_number = p_phone where id = me;
end;
$$;

create or replace function public.find_contact_by_phone(p_phone text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); row public.profiles;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select * into row from public.profiles
  where phone_number = trim(p_phone);
  if not found or row.id = me then return null; end if;
  if exists(select 1 from public.contact_blocks
    where (owner_id = me and blocked_id = row.id)
       or (owner_id = row.id and blocked_id = me)) then return null; end if;
  return jsonb_build_object(
    'user_id', row.id, 'username', row.username,
    'display_name', row.display_name);
end;
$$;

create or replace function public.send_invite_by_phone(p_phone text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); target uuid; uname text;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select id, username into target, uname from public.profiles
  where phone_number = trim(p_phone);
  if target is null or target = me then return 'unavailable'; end if;
  if exists(select 1 from public.contact_blocks
    where (owner_id = me and blocked_id = target)
       or (owner_id = target and blocked_id = me)) then return 'unavailable'; end if;
  if uname is not null and uname <> '' then
    return public.send_contact_invite(uname);
  end if;
  if exists(select 1 from public.contact_requests
    where least(sender_id, recipient_id) = least(me, target)
      and greatest(sender_id, recipient_id) = greatest(me, target)) then
    return 'already_sent';
  end if;
  insert into public.contact_requests(sender_id, recipient_id)
  values (me, target);
  return 'sent';
end;
$$;

revoke all on function public.set_my_phone(text) from public, anon, authenticated;
revoke all on function public.find_contact_by_phone(text) from public, anon, authenticated;
revoke all on function public.send_invite_by_phone(text) from public, anon, authenticated;
grant execute on function public.set_my_phone(text) to authenticated;
grant execute on function public.find_contact_by_phone(text) to authenticated;
grant execute on function public.send_invite_by_phone(text) to authenticated;
