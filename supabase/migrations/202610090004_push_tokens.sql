-- Apply after 202610090003_profile_about.sql.
-- Stores FCM/APNs tokens so the server can target devices later.
-- Tokens authenticate the device to receive pushes; rows are self-only.
begin;
create table public.push_tokens (
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text primary key check (char_length(token) between 32 and 4096),
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens(user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;
grant select, delete on public.push_tokens to authenticated;
create policy push_tokens_read_self on public.push_tokens for select to authenticated
  using (user_id = (select auth.uid()));
create policy push_tokens_delete_self on public.push_tokens for delete to authenticated
  using (user_id = (select auth.uid()));

create function public.register_push_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_token is null or char_length(p_token) not between 32 and 4096
     or p_platform not in ('android', 'ios', 'web') then
    raise exception 'Invalid push token';
  end if;
  if exists(select 1 from public.push_tokens where token = p_token and user_id <> me) then
    raise exception 'Token unavailable';
  end if;
  insert into public.push_tokens(user_id, token, platform) values (me, p_token, p_platform)
  on conflict (token) do update set platform = excluded.platform, created_at = now();
  -- One messaging device per user for the pilot: the just-registered token wins.
  delete from public.push_tokens where user_id = me and token <> p_token;
end;
$$;
revoke all on function public.register_push_token(text,text) from public, anon, authenticated;
grant execute on function public.register_push_token(text,text) to authenticated;

create function public.unregister_push_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  delete from public.push_tokens where user_id = me and token = p_token;
end;
$$;
revoke all on function public.unregister_push_token(text) from public, anon, authenticated;
grant execute on function public.unregister_push_token(text) to authenticated;
commit;
