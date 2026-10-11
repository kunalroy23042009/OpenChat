-- OpenChat AI quota: one counter row per user per day for the keyless
-- assistant. Only the ai_chat_quota RPC touches it; no client privileges.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
create table if not exists public.ai_daily_usage (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null default ((now() at time zone 'UTC')::date),
  count integer not null default 0,
  primary key (user_id, day)
);
alter table public.ai_daily_usage enable row level security;
revoke all on public.ai_daily_usage from anon, authenticated;

create or replace function public.ai_chat_quota(p_limit integer default 50)
returns boolean language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); used integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  insert into public.ai_daily_usage as u(user_id, day, count)
  values (me, ((now() at time zone 'UTC')::date), 1)
  on conflict (user_id, day)
  do update set count = public.ai_daily_usage.count + 1
  returning public.ai_daily_usage.count into used;
  return used <= least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;
revoke all on function public.ai_chat_quota(integer) from public, anon, authenticated;
grant execute on function public.ai_chat_quota(integer) to authenticated;
