-- Pilot media transport on Supabase Storage (free-tier friendly).
-- Files live at <senderUid>/<recipientUid>/<uuid>.jpg inside a private
-- bucket. Only the two chat parties can read; only the sender can
-- write/delete. The object path travels inside the Signal-encrypted
-- message, so the reference is end-to-end encrypted; bytes at rest are
-- access-controlled but NOT E2E sealed (see blobSeal follow-up).
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
insert into storage.buckets (id, name, public)
values ('chat-media', 'chat-media', false)
on conflict (id) do nothing;

drop policy if exists "chat-media insert own" on storage.objects;
create policy "chat-media insert own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat-media select party" on storage.objects;
create policy "chat-media select party" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat-media'
    and (
      auth.uid()::text = (storage.foldername(name))[1]
      or auth.uid()::text = (storage.foldername(name))[2]
    )
  );

drop policy if exists "chat-media delete own" on storage.objects;
create policy "chat-media delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
