-- Live call signaling for 1:1 voice/video. Rooms are deterministic per
-- pair (`dm_<min>_<max>`); only messaging-allowed pairs may ring.
-- Callee discovery is via Realtime on this table (recipient-filtered).
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
create table if not exists public.call_invites (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  room text not null,
  call_type text not null check (call_type in ('voice', 'video')),
  status text not null default 'ringing'
    check (status in ('ringing', 'accepted', 'declined', 'ended')),
  created_at timestamptz not null default now(),
  check (caller_id <> callee_id)
);
create index if not exists call_invites_callee
  on public.call_invites (callee_id, created_at desc);
alter table public.call_invites enable row level security;
alter table public.call_invites replica identity full;
revoke all on public.call_invites from anon, authenticated;
grant select, insert, update on public.call_invites to authenticated;

drop policy if exists call_invites_caller_write on public.call_invites;
create policy call_invites_caller_write on public.call_invites
  for insert to authenticated
  with check (caller_id = (select auth.uid()));

drop policy if exists call_invites_party_read on public.call_invites;
create policy call_invites_party_read on public.call_invites
  for select to authenticated
  using ((select auth.uid()) in (caller_id, callee_id));

drop policy if exists call_invites_callee_update on public.call_invites;
create policy call_invites_callee_update on public.call_invites
  for update to authenticated
  using (callee_id = (select auth.uid()))
  with check (callee_id = (select auth.uid()));

drop policy if exists call_invites_caller_update on public.call_invites;
create policy call_invites_caller_update on public.call_invites
  for update to authenticated
  using (caller_id = (select auth.uid()))
  with check (caller_id = (select auth.uid()));

alter publication supabase_realtime add table public.call_invites;

create or replace function public.place_call(p_callee_id uuid, p_type text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); row public.call_invites;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_callee_id is null or p_callee_id = me then
    raise exception 'Contact unavailable';
  end if;
  if p_type not in ('voice', 'video') then raise exception 'Invalid call type'; end if;
  if not public.messaging_allowed(me, p_callee_id) then
    raise exception 'Contact unavailable';
  end if;
  insert into public.call_invites(caller_id, callee_id, room, call_type)
  values (me, p_callee_id,
    'dm_' || least(me::text, p_callee_id::text) || '_' || greatest(me::text, p_callee_id::text),
    p_type)
  returning * into row;
  return jsonb_build_object('id', row.id, 'room', row.room);
end;
$$;

create or replace function public.answer_call(p_invite_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  update public.call_invites
  set status = case when p_accept then 'accepted' else 'declined' end
  where id = p_invite_id and callee_id = me and status = 'ringing';
  if not found then raise exception 'Call unavailable'; end if;
end;
$$;

create or replace function public.end_call(p_invite_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  update public.call_invites set status = 'ended'
  where id = p_invite_id and status in ('ringing', 'accepted')
    and (caller_id = me or callee_id = me);
end;
$$;

revoke all on function public.place_call(uuid, text) from public, anon, authenticated;
revoke all on function public.answer_call(uuid, boolean) from public, anon, authenticated;
revoke all on function public.end_call(uuid) from public, anon, authenticated;
grant execute on function public.place_call(uuid, text) to authenticated;
grant execute on function public.answer_call(uuid, boolean) to authenticated;
grant execute on function public.end_call(uuid) to authenticated;
