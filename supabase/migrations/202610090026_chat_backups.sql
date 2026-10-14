-- Encrypted chat backups, WhatsApp-style (#366-373).
-- Each backup is a single AES-256-GCM blob sealed with a password-derived
-- key (Argon2id, client-side); the server only ever sees ciphertext at
-- <ownerUid>/backup.enc. History rows stay on device; media bytes stay in
-- chat-media and re-download on demand after a restore.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
insert into storage.buckets (id, name, public)
values ('chat-backups', 'chat-backups', false)
on conflict (id) do nothing;

drop policy if exists "chat-backups insert own" on storage.objects;
create policy "chat-backups insert own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat-backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat-backups update own" on storage.objects;
create policy "chat-backups update own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'chat-backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'chat-backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat-backups select own" on storage.objects;
create policy "chat-backups select own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat-backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat-backups delete own" on storage.objects;
create policy "chat-backups delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'chat-backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
