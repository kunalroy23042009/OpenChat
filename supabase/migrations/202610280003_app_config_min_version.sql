-- Server-driven client version gate. `min_app_version` is the oldest
-- versionName the server still accepts; clients below it show an update
-- screen instead of the app. Reads are open to any signed-in user; writes
-- stay with the service role / SQL editor only (no grants below).
begin;

create table if not exists public.app_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.app_config enable row level security;
grant select on public.app_config to authenticated;

drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config
  for select to authenticated using (true);

insert into public.app_config(key, value)
values ('min_app_version', '1.0.1')
on conflict (key) do nothing;

commit;
