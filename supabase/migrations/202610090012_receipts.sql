-- Delivery receipts pilot: delivered/read tracking without new tables.
-- fetch_inbox stamps delivery server-side; mark_read stamps reads;
-- message_statuses lets senders poll ticks for their own messages.
-- ack policy moves to read-only deletion (plus expiry); clients must
-- only ack durably stored envelopes to avoid silent loss.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
alter table public.message_envelopes
  add column if not exists delivered_at timestamptz,
  add column if not exists read_at timestamptz;

create or replace function public.fetch_inbox(p_since timestamptz default null, p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  update public.message_envelopes set delivered_at = coalesce(delivered_at, now())
  where recipient_id = me and expires_at > now() and delivered_at is null;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at), '[]'::jsonb) into result from (
    select id, client_message_id, sender_id, ciphertext, protocol_version, created_at, expires_at
    from public.message_envelopes
    where recipient_id = me and expires_at > now()
    order by created_at limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) items;
  return result;
end;
$$;

create or replace function public.mark_read(p_sender_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); marked integer;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_sender_id is null then raise exception 'Invalid sender'; end if;
  update public.message_envelopes set read_at = coalesce(read_at, now())
  where recipient_id = me and sender_id = p_sender_id
    and expires_at > now() and read_at is null;
  get diagnostics marked = row_count;
  return marked;
end;
$$;

create or replace function public.message_statuses(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) not between 1 and 50 then
    raise exception 'Invalid status batch';
  end if;
  select coalesce(jsonb_agg(to_jsonb(items)), '[]'::jsonb) into result from (
    select client_message_id as id,
      case when read_at is not null then 'read'
           when delivered_at is not null then 'delivered'
           else 'sent' end as status
    from public.message_envelopes
    where sender_id = me and client_message_id = any(p_ids)
  ) items;
  return result;
end;
$$;

revoke all on function public.mark_read(uuid) from public, anon, authenticated;
revoke all on function public.message_statuses(text[]) from public, anon, authenticated;
grant execute on function public.mark_read(uuid) to authenticated;
grant execute on function public.message_statuses(text[]) to authenticated;
