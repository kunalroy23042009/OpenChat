-- Run with psql -v ON_ERROR_STOP=1 after all five migrations, as DB owner.
-- Verifies key publishing, single-use claims, quotas, blocks, and inbox flow.
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
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select public.save_profile('Eve', 'eve', 'Just looking around.');

-- Alice and Bob connect; Eve stays a stranger.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.send_contact_invite('bob');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.respond_contact_invite((select id from public.contact_requests limit 1), true);

-- Strangers cannot publish-check or claim each other.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
do $$ begin
  begin
    perform public.claim_key_bundle('00000000-0000-0000-0000-000000000001');
    raise exception 'Stranger claim allowed';
  exception when raise_exception then
    if sqlerrm <> 'Contact unavailable' then raise; end if;
  end;
  if public.enqueue_message('00000000-0000-0000-0000-000000000001', 'x', 'cipher')->>'status' <> 'unavailable' then raise exception 'Stranger enqueue allowed'; end if;
end $$;

-- Alice publishes a bundle with 3 one-time and 2 kyber prekeys.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  begin
    perform public.publish_key_bundle(repeat('A', 44), 42, 7, repeat('C', 44), repeat('D', 64), '[]'::jsonb, '[]'::jsonb);
    raise exception 'Empty pools accepted';
  exception when raise_exception then
    if sqlerrm <> 'Invalid key bundle' then raise; end if;
  end;
end $$;
select public.publish_key_bundle(
  repeat('A', 44), 42, 7, repeat('C', 44), repeat('D', 64),
  (select jsonb_agg(jsonb_build_object('id', g, 'key', 'ec-pub-' || g || repeat('E', 40))) from generate_series(1, 3) g),
  (select jsonb_agg(jsonb_build_object('id', g, 'key', 'kyber-pub-' || g || repeat('F', 1590), 'signature', repeat('S', 64))) from generate_series(1, 2) g));

-- Bob claims: distinct one-time prekeys, then exhaustion, bundle always present.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ declare first jsonb; second jsonb; third jsonb; fourth jsonb;
begin
  first := public.claim_key_bundle('00000000-0000-0000-0000-000000000001');
  second := public.claim_key_bundle('00000000-0000-0000-0000-000000000001');
  third := public.claim_key_bundle('00000000-0000-0000-0000-000000000001');
  fourth := public.claim_key_bundle('00000000-0000-0000-0000-000000000001');
  if first->>'identity_key' <> repeat('A', 44) then raise exception 'Bundle identity mismatch'; end if;
  if first->>'prekey' = second->>'prekey' or second->>'prekey' = third->>'prekey' then raise exception 'Prekey reused across claims'; end if;
  if third->>'prekey' is null then raise exception 'Third prekey missing'; end if;
  if first->>'kyber_signature' <> repeat('S', 64) then raise exception 'Kyber signature missing from claim'; end if;
  -- Pool exhausted: no one-time material, but the bundle still comes back
  -- (sessions can start without a one-time prekey).
  if fourth->>'prekey' is not null or fourth->>'kyber' is not null then raise exception 'Exhausted pool issued keys'; end if;
  if fourth->>'signed_prekey' <> repeat('C', 44) then raise exception 'Bundle missing after exhaustion'; end if;
end $$;

-- Messaging round trip with duplicate suppression.
do $$ declare sent jsonb; resent jsonb;
begin
  sent := public.enqueue_message('00000000-0000-0000-0000-000000000001', 'client-1', repeat('G', 100));
  resent := public.enqueue_message('00000000-0000-0000-0000-000000000001', 'client-1', repeat('G', 100));
  if sent->>'status' <> 'sent' then raise exception 'First send failed'; end if;
  if resent->>'status' <> 'duplicate' then raise exception 'Duplicate retry not flagged'; end if;
  if sent->>'id' <> resent->>'id' then raise exception 'Duplicate retry created a second envelope'; end if;
  if (sent->>'expires_at')::timestamptz < now() + interval '6 days' then raise exception 'Expiry too short'; end if;
  if public.enqueue_message('00000000-0000-0000-0000-000000000001', 'x', repeat('H', 8193))->>'status' <> 'invalid' then raise exception 'Oversize envelope accepted'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  if jsonb_array_length(public.fetch_inbox()) <> 1 then raise exception 'Inbox missing envelope'; end if;
  if public.fetch_inbox()->0->>'ciphertext' <> repeat('G', 100) then raise exception 'Ciphertext altered'; end if;
  if public.ack_messages(array[(public.fetch_inbox()->0->>'id')::uuid]) <> 1 then raise exception 'Ack failed'; end if;
  if public.fetch_inbox() <> '[]'::jsonb then raise exception 'Acked message still listed'; end if;
  if public.cleanup_expired() < 0 then raise exception 'Cleanup failed'; end if;
end $$;

-- Blocks stop both directions.
select public.block_contact('00000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ begin
  begin
    perform public.claim_key_bundle('00000000-0000-0000-0000-000000000001');
    raise exception 'Blocked claim allowed';
  exception when raise_exception then
    if sqlerrm <> 'Contact unavailable' then raise; end if;
  end;
  begin
    if public.enqueue_message('00000000-0000-0000-0000-000000000001', 'blocked-1', 'cipher')->>'status' <> 'unavailable' then raise exception 'Blocked enqueue allowed'; end if;
  end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.unblock_contact('00000000-0000-0000-0000-000000000002');
-- Blocking deleted the connection, so reconnect before the quota run.
select public.send_contact_invite('bob');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.respond_contact_invite((select id from public.contact_requests where status = 'pending' limit 1), true);

-- Daily send quota: every attempt counts, including rejected ones (4 used above).
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ begin
  for i in 1..496 loop
    if public.enqueue_message('00000000-0000-0000-0000-000000000001', 'quota-' || i, 'cipher')->>'status' <> 'sent' then raise exception 'Send within quota refused'; end if;
  end loop;
  if public.enqueue_message('00000000-0000-0000-0000-000000000001', 'quota-over', 'cipher')->>'status' <> 'rate_limited' then raise exception 'Quota bypass'; end if;
end $$;

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$ begin
  begin
    perform public.publish_key_bundle('x', 1, 1, 'x', 'x', '[]'::jsonb, '[]'::jsonb);
    raise exception 'Anonymous publish allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.message_envelopes;
    raise exception 'Anonymous envelope read allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.key_bundles;
    raise exception 'Anonymous bundle read allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select 'Messaging transport authorization and lifecycle tests passed' as result;
