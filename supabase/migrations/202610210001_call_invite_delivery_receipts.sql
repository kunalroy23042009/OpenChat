-- Call invite delivery receipts & retry logic
-- Adds delivery tracking like messages have (envelope_receipts)
-- Compatible with existing place_call(p_callee_id, p_type, p_encrypted_call_key)

-- Ensure expires_at exists and defaults to 120 seconds (2 min ringing window)
alter table public.call_invites
  add column if not exists expires_at timestamptz
    not null default (now() + interval '120 seconds');

-- Delivery receipt columns
alter table public.call_invites
  add column if not exists delivery_status text not null default 'pending'
    check (delivery_status in ('pending', 'delivered', 'read')),
  add column if not exists delivered_at timestamptz;

create index if not exists call_invites_pending_delivery
  on public.call_invites (callee_id, delivery_status, created_at desc)
  where delivery_status = 'pending';

-- Callee can update delivery status when they receive the invite
create or replace function public.mark_call_invite_delivered(p_invite_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  update public.call_invites
  set delivery_status = 'delivered',
      delivered_at = now()
  where id = p_invite_id
    and callee_id = me
    and delivery_status = 'pending';
end;
$$;

revoke all on function public.mark_call_invite_delivered(uuid) from public, anon, authenticated;
grant execute on function public.mark_call_invite_delivered(uuid) to authenticated;

-- Server-side retry: reset stale pending invites so they can be re-notified
-- Called by pg_cron or Edge Function cron
create or replace function public.retry_pending_call_invites(p_max_age_seconds int default 30)
returns int language plpgsql security definer set search_path = '' as $$
declare updated_count int := 0;
begin
  update public.call_invites
  set delivery_status = 'pending',
      created_at = now() -- reset for retry (re-notify will pick up new created_at)
  where delivery_status = 'pending'
    and status = 'ringing'
    and now() - created_at > make_interval(secs => p_max_age_seconds);
  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;

revoke all on function public.retry_pending_call_invites(int) from public, anon, authenticated;
grant execute on function public.retry_pending_call_invites(int) to authenticated;

-- Update place_call to use 120 second expiry (was 60) and keep encrypted_call_key param
create or replace function public.place_call(p_callee_id uuid, p_type text, p_encrypted_call_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); invite public.call_invites;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_callee_id is null or p_callee_id = me or not public.messaging_allowed(me,p_callee_id) then
    raise exception 'Contact unavailable';
  end if;
  if p_type is null or p_type not in ('voice','video') then raise exception 'Invalid call type'; end if;
  if p_encrypted_call_key is null or length(p_encrypted_call_key) not between 1 and 8192 then
    raise exception 'Encrypted call key required';
  end if;
  -- Serialize setup involving either participant, including simultaneous calls.
  perform id from public.profiles where id in (me,p_callee_id) order by id for update;
  update public.call_invites set status = 'ended'
    where status in ('ringing','accepted') and expires_at <= now()
      and (caller_id in (me,p_callee_id) or callee_id in (me,p_callee_id));
  if exists (select 1 from public.call_invites where status in ('ringing','accepted')
    and expires_at > now() and (caller_id in (me,p_callee_id) or callee_id in (me,p_callee_id))) then
    raise exception 'A participant is already in a call';
  end if;
  insert into public.call_invites(caller_id,callee_id,room,call_type,encrypted_call_key,expires_at)
    values (me,p_callee_id,'call_' || replace(gen_random_uuid()::text,'-',''),p_type,
      p_encrypted_call_key,now() + interval '120 seconds') returning * into invite;
  return jsonb_build_object('id',invite.id,'room',invite.room,'expires_at',invite.expires_at);
end;
$$;

revoke all on function public.place_call(uuid,text,text) from public, anon, authenticated;
grant execute on function public.place_call(uuid,text,text) to authenticated;