-- Receipt metadata survives ciphertext acknowledgement. No message bodies,
-- attachment keys or quoted text are retained in this table.
begin;
create table public.envelope_receipts (
  envelope_id uuid primary key,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  client_message_id text not null,
  sent_at timestamptz not null,
  delivered_at timestamptz not null default now(),
  read_at timestamptz,
  expires_at timestamptz not null default (now() + interval '30 days'),
  unique(sender_id, client_message_id)
);
alter table public.envelope_receipts enable row level security;
revoke all on public.envelope_receipts from public, anon, authenticated;
create index envelope_receipts_expiry on public.envelope_receipts(expires_at);

-- Fetch alone does not prove local delivery. Only an ACK after a durable
-- write creates a delivery receipt; no unrelated inbox rows get stamped.
create or replace function public.fetch_inbox(p_since timestamptz default null, p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at, items.id), '[]'::jsonb)
  into result from (
    select id, client_message_id, sender_id, ciphertext, protocol_version, created_at, expires_at
    from public.message_envelopes
    where recipient_id = me and expires_at > now()
      and (p_since is null or created_at > p_since)
    order by created_at, id limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) items;
  return result;
end $$;

create or replace function public.ack_messages(p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); removed integer; item record;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 100 then
    raise exception 'Invalid acknowledgment batch';
  end if;
  for item in select sender_id, client_message_id from public.message_envelopes
    where recipient_id = me and id = any(p_ids) order by sender_id, client_message_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(item.sender_id::text || ':' || item.client_message_id, 0));
  end loop;
  -- INSERT and DELETE are one transaction: a failed receipt write cannot
  -- remove a queued ciphertext. Lock rows to serialize overlapping ACKs.
  insert into public.envelope_receipts(envelope_id, sender_id, recipient_id, client_message_id, sent_at)
  select e.id, e.sender_id, e.recipient_id, e.client_message_id, e.created_at
  from public.message_envelopes e where e.recipient_id = me and e.id = any(p_ids)
  order by e.id for update
  on conflict (envelope_id) do nothing;
  delete from public.message_envelopes where recipient_id = me and id = any(p_ids);
  get diagnostics removed = row_count;
  return removed;
end $$;

-- A retry after ACK must not recreate a delivered envelope. The same
-- per-message transaction lock is used above so ACK/retry cannot race.
create or replace function public.enqueue_message(p_recipient_id uuid, p_client_message_id text, p_ciphertext text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); used integer; envelope public.message_envelopes; receipt public.envelope_receipts;
begin
  if me is null then raise exception 'Sign in required'; end if;
  -- Every attempt counts toward the daily quota, including retries and
  -- rejected sends, exactly like the original transport.
  insert into public.message_send_limits as limits(user_id, window_start, attempts)
  values (me, (now() at time zone 'UTC')::date, 1)
  on conflict (user_id) do update set
    attempts = case when limits.window_start = excluded.window_start then least(limits.attempts + 1, 501) else 1 end,
    window_start = excluded.window_start
  returning attempts into used;
  if used > 500 then return jsonb_build_object('status', 'rate_limited'); end if;
  if p_recipient_id is null or p_recipient_id = me then return jsonb_build_object('status', 'unavailable'); end if;
  if p_client_message_id is null or char_length(p_client_message_id) not between 1 and 64
     or p_ciphertext is null or char_length(p_ciphertext) not between 1 and 8192 then
    return jsonb_build_object('status', 'invalid');
  end if;
  if not public.messaging_allowed(me, p_recipient_id) then return jsonb_build_object('status', 'unavailable'); end if;
  perform pg_advisory_xact_lock(hashtextextended(me::text || ':' || p_client_message_id, 0));
  select * into receipt from public.envelope_receipts where sender_id = me and client_message_id = p_client_message_id;
  if found then
    if receipt.recipient_id <> p_recipient_id then return jsonb_build_object('status', 'invalid'); end if;
    return jsonb_build_object('status', 'duplicate', 'id', receipt.envelope_id, 'created_at', receipt.sent_at, 'expires_at', receipt.expires_at);
  end if;
  select * into envelope from public.message_envelopes where sender_id = me and client_message_id = p_client_message_id;
  if found then
    if envelope.recipient_id <> p_recipient_id then return jsonb_build_object('status', 'invalid'); end if;
    return jsonb_build_object('status', 'duplicate', 'id', envelope.id, 'created_at', envelope.created_at, 'expires_at', envelope.expires_at);
  end if;
  insert into public.message_envelopes(client_message_id, sender_id, recipient_id, ciphertext, expires_at)
  values (p_client_message_id, me, p_recipient_id, p_ciphertext, now() + interval '7 days') returning * into envelope;
  return jsonb_build_object('status', 'sent', 'id', envelope.id, 'created_at', envelope.created_at, 'expires_at', envelope.expires_at);
end $$;

create function public.mark_messages_read(p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); marked integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 100 then
    raise exception 'Invalid read batch';
  end if;
  if exists (select 1 from public.user_preferences where user_id = me and not read_receipts) then
    return 0;
  end if;
  update public.envelope_receipts set read_at = coalesce(read_at, now())
  where recipient_id = me and envelope_id = any(p_ids) and expires_at > now() and read_at is null;
  get diagnostics marked = row_count;
  return marked;
end $$;
revoke all on function public.mark_messages_read(uuid[]) from public, anon, authenticated;
grant execute on function public.mark_messages_read(uuid[]) to authenticated;

-- Older clients cannot mark unfetched/undecrypted messages read by sender.
create or replace function public.mark_read(p_sender_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  return 0;
end $$;

create or replace function public.message_statuses(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 50 then
    raise exception 'Invalid status batch';
  end if;
  select coalesce(jsonb_agg(to_jsonb(items)), '[]'::jsonb) into result from (
    select r.client_message_id as id,
      case when r.read_at is null then 'delivered' else 'read' end as status,
      r.delivered_at, r.read_at
    from public.envelope_receipts r
    where r.sender_id = me and r.client_message_id = any(p_ids) and r.expires_at > now()
    union all
    select e.client_message_id, 'sent', null::timestamptz, null::timestamptz
    from public.message_envelopes e
    where e.sender_id = me and e.client_message_id = any(p_ids)
      and not exists (select 1 from public.envelope_receipts r where r.sender_id = me and r.client_message_id = e.client_message_id)
  ) items;
  return result;
end $$;

create or replace function public.cleanup_expired()
returns integer language plpgsql security definer set search_path = '' as $$
declare removed integer;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  delete from public.message_envelopes where expires_at < now();
  get diagnostics removed = row_count;
  delete from public.envelope_receipts where expires_at < now();
  return removed;
end $$;
commit;
