-- Service-only replay protection for event-backed FCM sends.
begin;
create table public.notification_dispatches (
  actor_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('message','call','status')),
  event_id text not null check (char_length(event_id) between 1 and 100),
  attempted_at timestamptz not null default now(),
  attempts integer not null default 1,
  sent boolean not null default false,
  primary key (actor_id, recipient_id, kind, event_id)
);
alter table public.notification_dispatches enable row level security;
revoke all on public.notification_dispatches from public, anon, authenticated;
grant select, update on public.notification_dispatches to service_role;
create function public.claim_notification_dispatch(p_actor uuid, p_recipient uuid, p_kind text, p_event text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare claimed integer;
begin
  insert into public.notification_dispatches as d(actor_id, recipient_id, kind, event_id)
  values (p_actor, p_recipient, p_kind, p_event)
  on conflict (actor_id, recipient_id, kind, event_id) do update
    set attempts = d.attempts + 1, attempted_at = now()
    where not d.sent and d.attempts < 3 and d.attempted_at < now() - interval '30 seconds';
  get diagnostics claimed = row_count;
  return claimed = 1;
end $$;
revoke all on function public.claim_notification_dispatch(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.claim_notification_dispatch(uuid,uuid,text,text) to service_role;
commit;
