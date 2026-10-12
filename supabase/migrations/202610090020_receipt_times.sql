-- Message info sheet: expose server receipt timestamps to senders.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
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
           else 'sent' end as status,
      delivered_at, read_at
    from public.message_envelopes
    where sender_id = me and client_message_id = any(p_ids)
  ) items;
  return result;
end;
$$;
