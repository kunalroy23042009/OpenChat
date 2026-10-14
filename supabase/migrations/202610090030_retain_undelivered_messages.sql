-- Keep encrypted direct messages queued until the recipient has durably
-- stored and acknowledged them. Previously, an offline recipient could lose
-- a message after seven days even though neither user deleted it.
--
-- Acknowledged ciphertext is still removed by ack_messages; only its delivery
-- receipt remains. Existing pending envelopes are retained as well.
begin;

update public.message_envelopes
set expires_at = 'infinity'::timestamptz
where expires_at < 'infinity'::timestamptz;

create or replace function public.enqueue_message(
  p_recipient_id uuid,
  p_client_message_id text,
  p_ciphertext text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  used integer;
  envelope public.message_envelopes;
  receipt public.envelope_receipts;
begin
  if me is null then raise exception 'Sign in required'; end if;

  insert into public.message_send_limits as limits(user_id, window_start, attempts)
  values (me, (now() at time zone 'UTC')::date, 1)
  on conflict (user_id) do update set
    attempts = case
      when limits.window_start = excluded.window_start
        then least(limits.attempts + 1, 501)
      else 1
    end,
    window_start = excluded.window_start
  returning attempts into used;

  if used > 500 then return jsonb_build_object('status', 'rate_limited'); end if;
  if p_recipient_id is null or p_recipient_id = me then
    return jsonb_build_object('status', 'unavailable');
  end if;
  if p_client_message_id is null
     or char_length(p_client_message_id) not between 1 and 64
     or p_ciphertext is null
     or char_length(p_ciphertext) not between 1 and 8192 then
    return jsonb_build_object('status', 'invalid');
  end if;
  if not public.messaging_allowed(me, p_recipient_id) then
    return jsonb_build_object('status', 'unavailable');
  end if;

  -- Serialize retries with acknowledgements so an ACK cannot race a retry
  -- and recreate an already-delivered message.
  perform pg_advisory_xact_lock(
    hashtextextended(me::text || ':' || p_client_message_id, 0)
  );

  select * into receipt
  from public.envelope_receipts
  where sender_id = me and client_message_id = p_client_message_id;
  if found then
    if receipt.recipient_id <> p_recipient_id then
      return jsonb_build_object('status', 'invalid');
    end if;
    return jsonb_build_object(
      'status', 'duplicate', 'id', receipt.envelope_id,
      'created_at', receipt.sent_at, 'expires_at', receipt.expires_at
    );
  end if;

  select * into envelope
  from public.message_envelopes
  where sender_id = me and client_message_id = p_client_message_id;
  if found then
    if envelope.recipient_id <> p_recipient_id then
      return jsonb_build_object('status', 'invalid');
    end if;
    return jsonb_build_object(
      'status', 'duplicate', 'id', envelope.id,
      'created_at', envelope.created_at, 'expires_at', envelope.expires_at
    );
  end if;

  insert into public.message_envelopes(
    client_message_id, sender_id, recipient_id, ciphertext, expires_at
  ) values (
    p_client_message_id, me, p_recipient_id, p_ciphertext,
    'infinity'::timestamptz
  ) returning * into envelope;

  return jsonb_build_object(
    'status', 'sent', 'id', envelope.id,
    'created_at', envelope.created_at, 'expires_at', envelope.expires_at
  );
end;
$$;

revoke all on function public.enqueue_message(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.enqueue_message(uuid, text, text)
  to authenticated;

commit;
