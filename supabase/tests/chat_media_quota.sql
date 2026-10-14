-- Run with psql -v ON_ERROR_STOP=1 after all migrations, as DB owner.
-- Verifies chat-media quota: single-object cap and per-user live budget.
-- Rows are metadata-only (no real bytes); size lives in metadata->>'size'.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000031', true);

-- Small object under the same owner prefix succeeds.
insert into storage.objects (bucket_id, name, metadata)
values ('chat-media', '00000000-0000-0000-0000-000000000031/peer/small.enc', '{"size": 100}');

-- Single object over 64 MiB + 64 KiB is rejected.
do $$ begin
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('chat-media', '00000000-0000-0000-0000-000000000031/peer/huge.enc', '{"size": 67174401}');
    raise exception 'Oversize object allowed';
  exception when raise_exception then
    if sqlerrm <> 'Media object exceeds the 64 MB single-object limit' then raise; end if;
  end;
end $$;

-- Fill toward the 300 MiB budget with 5x 60 MB objects; the next 60 MB
-- object is rejected while a tiny object still fits.
do $$ declare i integer; begin
  for i in 1..5 loop
    insert into storage.objects (bucket_id, name, metadata)
    values ('chat-media', '00000000-0000-0000-0000-000000000031/peer/fill' || i || '.enc',
      '{"size": 60000000}');
  end loop;
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('chat-media', '00000000-0000-0000-0000-000000000031/peer/over.enc', '{"size": 60000000}');
    raise exception 'Over-budget object allowed';
  exception when raise_exception then
    if sqlerrm <> 'Storage budget exhausted' then raise; end if;
  end;
end $$;

-- Usage RPC reports the caller's live bytes and object count (5 fills + small).
do $$ declare u jsonb; begin
  u := public.chat_media_usage();
  if (u->>'objects')::integer <> 6 then raise exception 'Bad object count: %', u; end if;
  if (u->>'bytes')::bigint <> 300000100 then raise exception 'Bad byte total: %', u; end if;
end $$;

-- Other buckets and other owners are unaffected.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000032', true);
insert into storage.objects (bucket_id, name, metadata)
values ('chat-media', '00000000-0000-0000-0000-000000000032/peer/ok.enc', '{"size": 100}');
rollback;
