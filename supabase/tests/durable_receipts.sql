-- Run after migration 0021 on a disposable local database as DB owner.
begin;
insert into auth.users(id) values
 ('00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000002'),
 ('00000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.save_profile('Alice', 'alice', 'Coffee first.');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.save_profile('Bob', 'bob', 'Trail runner.');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.send_contact_invite('bob');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.respond_contact_invite((select id from public.contact_requests limit 1), true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.enqueue_message('00000000-0000-0000-0000-000000000002', 'first', 'ciphertext');
select public.enqueue_message('00000000-0000-0000-0000-000000000002', 'second', 'ciphertext');

-- Fetching only one row must not deliver or read either row.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ begin
  if jsonb_array_length(public.fetch_inbox(null, 1)) <> 1 then raise exception 'Pagination broken'; end if;
  if public.mark_read('00000000-0000-0000-0000-000000000001') <> 0 then raise exception 'Legacy read marked unseen rows'; end if;
end $$;
reset role;
do $$ begin
  if exists(select 1 from public.message_envelopes where delivered_at is not null or read_at is not null) then raise exception 'Fetch generated a receipt'; end if;
end $$;
select set_config('test.envelope', (select id::text from public.message_envelopes where client_message_id = 'first'), true);
set local role authenticated;

-- A stranger cannot ACK, read, query status or directly select receipts.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
do $$ begin
  if public.ack_messages(array[current_setting('test.envelope')::uuid]) <> 0 then raise exception 'Forged ACK accepted'; end if;
  if public.mark_messages_read(array[current_setting('test.envelope')::uuid]) <> 0 then raise exception 'Forged read accepted'; end if;
  if public.message_statuses(array['first']) <> '[]'::jsonb then raise exception 'Stranger read sender receipts'; end if;
  begin
    perform 1 from public.envelope_receipts;
    raise exception 'Direct receipt SELECT allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ACK persists metadata while removing the ciphertext; repeating is safe.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ begin
  if public.mark_messages_read(array[current_setting('test.envelope')::uuid]) <> 0 then raise exception 'Read before durable ACK'; end if;
  if public.ack_messages(array[current_setting('test.envelope')::uuid]) <> 1 then raise exception 'ACK failed'; end if;
  if public.ack_messages(array[current_setting('test.envelope')::uuid]) <> 0 then raise exception 'Repeated ACK failed'; end if;
  if jsonb_array_length(public.fetch_inbox()) <> 1 then raise exception 'ACK removed unrelated row'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ declare status jsonb; begin
  status := public.message_statuses(array['first'])->0;
  if status->>'status' is distinct from 'delivered' or status->>'delivered_at' is null or status->>'read_at' is not null then raise exception 'Delivered receipt lost after ACK'; end if;
  if public.enqueue_message('00000000-0000-0000-0000-000000000002', 'first', 'retry')->>'status' is distinct from 'duplicate' then raise exception 'ACK broke send idempotency'; end if;
  if public.message_statuses(array['second'])->0->>'status' is distinct from 'sent' then raise exception 'Unrelated row marked delivered'; end if;
end $$;

-- Privacy switch and per-envelope read scoping.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.upsert_preferences('{"read_receipts":false}');
do $$ begin
  if public.mark_messages_read(array[current_setting('test.envelope')::uuid]) <> 0 then raise exception 'Privacy ignored'; end if;
end $$;
select public.upsert_preferences('{"read_receipts":true}');
do $$ begin
  if public.mark_messages_read(array[current_setting('test.envelope')::uuid]) <> 1 then raise exception 'Read missing'; end if;
  if public.mark_messages_read(array[current_setting('test.envelope')::uuid]) <> 0 then raise exception 'Repeated read changed timestamp'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  if public.message_statuses(array['first'])->0->>'status' is distinct from 'read' then raise exception 'Read receipt lost'; end if;
  if public.message_statuses(array['second'])->0->>'status' is distinct from 'sent' then raise exception 'Unrelated row marked read'; end if;
end $$;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$ begin
  begin
    perform public.message_statuses(array['first']);
    raise exception 'Anonymous status RPC allowed';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
