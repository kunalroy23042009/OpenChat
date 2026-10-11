-- Apply after 202610090007_attachments.sql. Email-realtime pilot.
-- Live delivery for ciphertext envelopes: Postgres Changes needs the table
-- in the realtime publication plus a recipient-only SELECT grant/policy.
-- RPCs remain the write path; no plaintext or keys are exposed here.
begin;
alter table public.message_envelopes replica identity full;
alter publication supabase_realtime add table public.message_envelopes;
grant select on public.message_envelopes to authenticated;
create policy envelopes_recipient_read on public.message_envelopes
  for select to authenticated
  using (recipient_id = (select auth.uid()));
commit;
