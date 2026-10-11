-- Repair 202610090010: re-apply 0002 statements lost when the API
-- rejected the multi-statement files, plus a self-healing profile writer.
-- Idempotent and transaction-managed by the caller: no explicit begin/commit.
create or replace function public.cancel_contact_invite(p_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  delete from public.contact_requests where id = p_request_id and sender_id = me and status = 'pending';
  if not found then raise exception 'Invitation unavailable or already handled'; end if;
end;
$$;

create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  delete from public.profiles where id = me;
  delete from auth.users where id = me;
end;
$$;

-- Self-healing writer: creates the profile row when the signup trigger has
-- not run yet instead of silently updating zero rows.
create or replace function public.save_profile(p_display_name text, p_username text, p_about text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_display_name is null or p_username is null or p_about is null
     or char_length(trim(p_display_name)) not between 1 and 60
     or char_length(trim(p_about)) not between 1 and 140
     or lower(trim(p_username)) !~ '^[a-z][a-z0-9_]{2,23}$' then
    raise exception 'Enter a name, a valid username, and a short about line';
  end if;
  insert into public.profiles(id, display_name, username, about)
  values (me, trim(p_display_name), lower(trim(p_username)), trim(p_about))
  on conflict (id) do update set display_name = excluded.display_name,
    username = excluded.username, about = excluded.about;
end;
$$;

revoke all on function public.cancel_contact_invite(uuid) from public, anon, authenticated;
revoke all on function public.delete_account() from public, anon, authenticated;
revoke all on function public.save_profile(text,text,text) from public, anon, authenticated;
grant execute on function public.cancel_contact_invite(uuid) to authenticated;
grant execute on function public.delete_account() to authenticated;
grant execute on function public.save_profile(text,text,text) to authenticated;
