-- Run with psql -v ON_ERROR_STOP=1 after all seven migrations, as DB owner.
-- Verifies reservation budgets, size verification, recipient-scoped
-- downloads, blocks, expiry cleanup, and anonymous denial.
begin;
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000012'),
  ('00000000-0000-0000-0000-000000000013');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select public.save_profile('Amy', 'amy', 'Sketches.');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
select public.save_profile('Ben', 'ben', 'Sourdough.');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000013', true);
select public.save_profile('Gil', 'gil', 'Stranger.');

-- Amy and Ben connect; Gil stays a stranger.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select public.send_contact_invite('ben');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
select public.respond_contact_invite((select id from public.contact_requests limit 1), true);

-- Strangers can neither reserve nor download.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000013', true);
do $$ begin
  begin
    perform public.reserve_attachment('00000000-0000-0000-0000-000000000011', 1000);
    raise exception 'Stranger reserve allowed';
  exception when raise_exception then
    if sqlerrm <> 'Contact unavailable' then raise; end if;
  end;
end $$;

-- Size bounds: zero, negative, and over 10 MiB are rejected.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
do $$ declare s integer; begin
  foreach s in array array[0, -5, 10485761] loop
    begin
      perform public.reserve_attachment('00000000-0000-0000-0000-000000000012', s);
      raise exception 'Bad size accepted: %', s;
    exception when raise_exception then
      if sqlerrm <> 'Invalid attachment size' then raise; end if;
    end;
  end loop;
end $$;

-- Reserve, finalize, and download as both parties.
do $$ declare res jsonb; fin jsonb; auth jsonb;
begin
  res := public.reserve_attachment('00000000-0000-0000-0000-000000000012', 5000);
  if res->>'object_key' is null then raise exception 'Missing object key'; end if;
  if (res->>'expected_bytes')::integer <> 5000 then raise exception 'Size mismatch'; end if;
  -- Recipient cannot download before finalization.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
  begin
    perform public.authorize_download((res->>'id')::uuid);
    raise exception 'Pre-finalize download allowed';
  exception when raise_exception then
    if sqlerrm <> 'Attachment unavailable' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
  -- Oversize finalization is rejected even within the 10 MiB cap.
  begin
    perform public.finalize_attachment((res->>'id')::uuid, 6000);
    raise exception 'Oversize finalize accepted';
  exception when raise_exception then
    if sqlerrm <> 'Uploaded size exceeds reservation' then raise; end if;
  end;
  fin := public.finalize_attachment((res->>'id')::uuid, 4000);
  if (fin->>'actual_bytes')::integer <> 4000 then raise exception 'Finalize mismatch'; end if;
  if (fin->>'retained_until')::timestamptz < now() + interval '29 days' then raise exception 'Retention too short'; end if;
  auth := public.authorize_download((res->>'id')::uuid);
  if auth->>'object_key' <> res->>'object_key' then raise exception 'Coordinate mismatch'; end if;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
  auth := public.authorize_download((res->>'id')::uuid);
  if (auth->>'actual_bytes')::integer <> 4000 then raise exception 'Recipient view mismatch'; end if;
  -- Finalizing twice is rejected.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
  begin
    perform public.finalize_attachment((res->>'id')::uuid, 4000);
    raise exception 'Double finalize accepted';
  exception when raise_exception then
    if sqlerrm <> 'Reservation unavailable' then raise; end if;
  end;
  -- Stash the id for later blocks (direct table reads are revoked).
  perform set_config('test.blob_id', res->>'id', false);
end $$;

-- Stranger cannot download someone else's file.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000013', true);
do $$ begin
  begin
    perform public.authorize_download(current_setting('test.blob_id')::uuid);
    raise exception 'Stranger download allowed';
  exception when raise_exception then
    if sqlerrm <> 'Attachment unavailable' then raise; end if;
  end;
end $$;

-- Budget: 10 x 10 MiB reserves fill the 100 MiB pilot budget; the 11th fails.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
do $$ declare i integer;
begin
  for i in 1..10 loop
    perform public.reserve_attachment('00000000-0000-0000-0000-000000000011', 10485760);
  end loop;
  begin
    perform public.reserve_attachment('00000000-0000-0000-0000-000000000011', 1);
    raise exception 'Budget bypass';
  exception when raise_exception then
    if sqlerrm <> 'Attachment budget exhausted' then raise; end if;
  end;
end $$;

-- Blocks stop reservations in both directions.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select public.block_contact('00000000-0000-0000-0000-000000000012');
do $$ begin
  begin
    perform public.reserve_attachment('00000000-0000-0000-0000-000000000012', 100);
    raise exception 'Blocked reserve allowed';
  exception when raise_exception then
    if sqlerrm <> 'Contact unavailable' then raise; end if;
  end;
end $$;
select public.unblock_contact('00000000-0000-0000-0000-000000000012');
-- Blocking deleted the connection, so reconnect before cleanup reserves.
select public.send_contact_invite('ben');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
select public.respond_contact_invite((select id from public.contact_requests where status = 'pending' limit 1), true);

-- Cleanup removes abandoned reservations and reports counts.
-- Backdate as table owner (direct writes are revoked for app roles).
reset role;
update public.attachment_blobs set expires_at = now() - interval '1 hour'
where owner_id = '00000000-0000-0000-0000-000000000012' and status = 'reserved';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
do $$ declare cleaned jsonb;
begin
  cleaned := public.cleanup_attachments();
  if (cleaned->>'abandoned')::integer < 10 then raise exception 'Abandoned rows kept'; end if;
  if (cleaned->>'expired')::integer <> 0 then raise exception 'Live rows collected'; end if;
  -- Budget freed: a fresh reserve works again.
  perform public.reserve_attachment('00000000-0000-0000-0000-000000000011', 100);
end $$;

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$ begin
  begin
    perform public.reserve_attachment('00000000-0000-0000-0000-000000000011', 100);
    raise exception 'Anonymous reserve allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.attachment_blobs;
    raise exception 'Anonymous blob read allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select 'Attachment reservation authorization and lifecycle tests passed' as result;
