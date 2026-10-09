-- Phase 2 account foundation. Apply once in the Supabase SQL editor.
-- No plaintext message table or public user directory is exposed.
begin;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'New member'
    check (char_length(display_name) between 1 and 60),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update(display_name) on public.profiles to authenticated;
create policy profiles_read_self on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create function public.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
revoke all on function public.create_profile() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.create_profile();
insert into public.profiles(id) select id from auth.users on conflict do nothing;

-- Device metadata only. Signal identity material is added after the SDK spike.
create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  label text not null check (char_length(label) between 1 and 60),
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now()
);
create index devices_user_idx on public.devices(user_id);
alter table public.devices enable row level security;
revoke all on public.devices from anon, authenticated;
grant select, delete on public.devices to authenticated;
-- Registration writes will use a rate-limited RPC with a per-account device cap.
create policy devices_read_self on public.devices for select to authenticated
  using (user_id = (select auth.uid()));
create policy devices_delete_self on public.devices for delete to authenticated
  using (user_id = (select auth.uid()));
commit;
