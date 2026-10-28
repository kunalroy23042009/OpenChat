-- Drop-in group voice rooms (WhatsApp-style). A row's presence means "an
-- audio room is ongoing for this group"; realtime publication lets every
-- member's app show the join banner. Room names reuse the 1:1 `call_<32 hex>`
-- shape so the livekit-token edge function mints tokens without changes.
-- Membership is enforced by the join/leave RPCs, not the room name.
-- Apply after 202610280001_realtime_profiles_recovery_observability.sql.
begin;

create table if not exists public.group_voice_rooms (
  conversation_id uuid primary key references public.conversations(id) on delete cascade,
  room_name text not null check (room_name ~ '^call_[0-9a-f]{32}$'),
  started_by uuid not null references public.profiles(id) on delete cascade,
  participant_count integer not null default 1 check (participant_count between 1 and 1000),
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.group_voice_rooms enable row level security;
grant select, insert, update, delete on public.group_voice_rooms to authenticated;

drop policy if exists group_voice_rooms_read on public.group_voice_rooms;
create policy group_voice_rooms_read on public.group_voice_rooms
  for select to authenticated using (
    exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = group_voice_rooms.conversation_id
        and cm.user_id = (select auth.uid())
    )
  );

drop policy if exists group_voice_rooms_member_write on public.group_voice_rooms;
create policy group_voice_rooms_member_write on public.group_voice_rooms
  for all to authenticated using (
    exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = group_voice_rooms.conversation_id
        and cm.user_id = (select auth.uid())
    )
  ) with check (
    exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = group_voice_rooms.conversation_id
        and cm.user_id = (select auth.uid())
    )
  );

-- Joining bumps the participant count. A room left stale (client crashed
-- without a clean leave) resets on the next join instead of growing forever.
create or replace function public.join_group_voice(p_conversation_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  room text := 'call_' || md5(p_conversation_id::text || ':group-voice');
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then raise exception 'Not a member of this conversation'; end if;
  insert into public.group_voice_rooms(conversation_id, room_name, started_by, participant_count)
  values (p_conversation_id, room, me, 1)
  on conflict (conversation_id) do update set
    participant_count = case
      when public.group_voice_rooms.updated_at < now() - interval '2 hours' then 1
      else least(public.group_voice_rooms.participant_count + 1, 1000)
    end,
    updated_at = now();
  return room;
end;
$$;
revoke all on function public.join_group_voice(uuid) from public, anon, authenticated;
grant execute on function public.join_group_voice(uuid) to authenticated;

create or replace function public.leave_group_voice(p_conversation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if me is null then return; end if;
  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me
  ) then return; end if;
  update public.group_voice_rooms
    set participant_count = greatest(participant_count - 1, 0), updated_at = now()
    where conversation_id = p_conversation_id;
  delete from public.group_voice_rooms
    where conversation_id = p_conversation_id and participant_count <= 0;
end;
$$;
revoke all on function public.leave_group_voice(uuid) from public, anon, authenticated;
grant execute on function public.leave_group_voice(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_voice_rooms'
  ) then
    alter publication supabase_realtime add table public.group_voice_rooms;
  end if;
end $$;

commit;
