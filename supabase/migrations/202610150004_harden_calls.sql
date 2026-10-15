-- Harden 1:1 calling:
--   * Per-invite random room so a room name never reveals the participant pair
--     and cannot be reused across calls.
--   * expires_at so a token can only be minted for a live invitation.
--   * answer_call extends the window once the callee accepts.

alter table public.call_invites
  add column if not exists expires_at timestamptz not null default (now() + interval '120 seconds');

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

  -- Stop any stale ringing invites from this caller before placing a new one.
  update public.call_invites
  set status = 'ended'
  where caller_id = me and status = 'ringing';

  insert into public.call_invites(caller_id, callee_id, room, call_type, expires_at)
  values (
    me,
    p_callee_id,
    'call_' || replace(gen_random_uuid()::text, '-', ''),
    p_type,
    now() + interval '120 seconds'
  )
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
  set status = case when p_accept then 'accepted' else 'declined' end,
      expires_at = case
        when p_accept then now() + interval '6 hours'
        else expires_at
      end
  where id = p_invite_id and callee_id = me and status = 'ringing';
  if not found then raise exception 'Call unavailable'; end if;
end;
$$;

-- Returns true when [p_user_id] is a party to a live invite on [p_room].
-- Used by the livekit-token Edge Function to authorise token minting.
create or replace function public.authorize_call_room(p_room text, p_user_id uuid)
returns boolean language sql security definer set search_path = '' as $$
  select exists (
    select 1 from public.call_invites
    where room = p_room
      and status in ('ringing', 'accepted')
      and expires_at > now()
      and (caller_id = p_user_id or callee_id = p_user_id)
  );
$$;

revoke all on function public.place_call(uuid, text) from public, anon, authenticated;
revoke all on function public.answer_call(uuid, boolean) from public, anon, authenticated;
revoke all on function public.authorize_call_room(text, uuid) from public, anon, authenticated;
grant execute on function public.place_call(uuid, text) to authenticated;
grant execute on function public.answer_call(uuid, boolean) to authenticated;
grant execute on function public.authorize_call_room(text, uuid) to authenticated;
