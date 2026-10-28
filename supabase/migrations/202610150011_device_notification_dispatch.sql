begin;
-- Per-device claims: a successful push to one phone must not consume another
-- phone's delivery. Store a digest, never a second copy of the FCM token.
create table if not exists public.device_notification_dispatches (
  actor_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('message','group','call','status','missed_call')),
  event_id text not null check (length(event_id) between 1 and 100),
  device_hash text not null,
  attempted_at timestamptz not null default now(),
  attempts integer not null default 1,
  sent boolean not null default false,
  primary key (actor_id,recipient_id,kind,event_id,device_hash)
);
alter table public.device_notification_dispatches enable row level security;
revoke all on public.device_notification_dispatches from public, anon, authenticated;
grant select, update, delete on public.device_notification_dispatches to service_role;

create or replace function public.claim_device_notification(
  p_actor uuid,p_recipient uuid,p_kind text,p_event text,p_device_hash text
) returns boolean language plpgsql security definer set search_path = '' as $$
declare claimed integer;
begin
  insert into public.device_notification_dispatches as d(actor_id,recipient_id,kind,event_id,device_hash)
    values(p_actor,p_recipient,p_kind,p_event,p_device_hash)
  on conflict (actor_id,recipient_id,kind,event_id,device_hash) do update
    set attempts = d.attempts + 1, attempted_at = now()
    where not d.sent and d.attempts < 3 and d.attempted_at < now() - interval '30 seconds';
  get diagnostics claimed = row_count;
  return claimed = 1;
end $$;
revoke all on function public.claim_device_notification(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.claim_device_notification(uuid,uuid,text,text,text) to service_role;
commit;
