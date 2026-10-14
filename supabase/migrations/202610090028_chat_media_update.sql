-- chat-media upsert fix. Images and videos upload with upsert:true, which
-- issues an UPDATE when the object already exists; without an update
-- policy those overwrites were denied. Chunks and backups use
-- insert-only paths and are unaffected.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
drop policy if exists "chat-media update own" on storage.objects;
create policy "chat-media update own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
