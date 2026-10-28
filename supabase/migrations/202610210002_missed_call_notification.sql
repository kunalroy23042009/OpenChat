-- Missed call notification queue + cron Edge Function
-- When caller ends a ringing call, insert into queue; cron Edge Function sends FCM

create table if not exists public.missed_call_notifications (
  id uuid primary key default gen_random_uuid(),
  invite_id uuid not null references public.call_invites(id) on delete cascade,
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  call_type text not null check (call_type in ('voice', 'video')),
  caller_name text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0
);
create index if not exists missed_call_notifications_pending
  on public.missed_call_notifications (created_at)
  where sent_at is null;

alter table public.missed_call_notifications enable row level security;
alter table public.missed_call_notifications replica identity full;
revoke all on public.missed_call_notifications from anon, authenticated;
grant select, insert on public.missed_call_notifications to authenticated;

drop policy if exists missed_call_notifications_insert on public.missed_call_notifications;
create policy missed_call_notifications_insert on public.missed_call_notifications
  for insert to authenticated
  with check (caller_id = (select auth.uid()));

drop policy if exists missed_call_notifications_select on public.missed_call_notifications;
create policy missed_call_notifications_select on public.missed_call_notifications
  for select to authenticated
  using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

-- Trigger: when caller ends a ringing call, queue missed call notification
create or replace function public.queue_missed_call_on_end()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_caller_name text;
begin
  if TG_OP = 'UPDATE' and OLD.status = 'ringing' and NEW.status = 'ended'
    and NEW.caller_id = (select auth.uid()) then
    select display_name into v_caller_name
    from public.profiles where id = NEW.caller_id;
    insert into public.missed_call_notifications (
      invite_id, caller_id, callee_id, call_type, caller_name
    ) values (
      NEW.id, NEW.caller_id, NEW.callee_id, NEW.call_type,
      coalesce(v_caller_name, 'New contact')
    ) on conflict do nothing;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trigger_queue_missed_call on public.call_invites;
create trigger trigger_queue_missed_call
after update on public.call_invites
for each row execute function public.queue_missed_call_on_end();

-- Cron Edge Function: processes missed call notification queue
-- Deploy as a scheduled Edge Function (e.g., every 30 seconds)
-- Sends FCM for unsent notifications, marks sent.