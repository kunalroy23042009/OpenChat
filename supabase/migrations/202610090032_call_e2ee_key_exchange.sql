-- Carry a call media key only as Signal-encrypted ciphertext. LiveKit's SFU
-- and Supabase can route the invitation but cannot recover the media key.
begin;

alter table public.call_invites
  add column encrypted_call_key text not null default 'legacy-disabled'
  check (char_length(encrypted_call_key) between 1 and 8192);
alter table public.call_invites
  alter column encrypted_call_key drop default;

drop function public.place_call(uuid, text);

create function public.place_call(
  p_callee_id uuid,
  p_type text,
  p_encrypted_call_key text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  row public.call_invites;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_callee_id is null or p_callee_id = me then
    raise exception 'Contact unavailable';
  end if;
  if p_type not in ('voice', 'video') then raise exception 'Invalid call type'; end if;
  if p_encrypted_call_key is null
     or char_length(p_encrypted_call_key) not between 1 and 8192 then
    raise exception 'Encrypted call key required';
  end if;
  if not public.messaging_allowed(me, p_callee_id) then
    raise exception 'Contact unavailable';
  end if;
  insert into public.call_invites(
    caller_id, callee_id, room, call_type, encrypted_call_key
  ) values (
    me, p_callee_id,
    'dm_' || least(me::text, p_callee_id::text) || '_' || greatest(me::text, p_callee_id::text),
    p_type,
    p_encrypted_call_key
  ) returning * into row;
  return jsonb_build_object('id', row.id, 'room', row.room);
end;
$$;

revoke all on function public.place_call(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.place_call(uuid, text, text)
  to authenticated;

commit;
