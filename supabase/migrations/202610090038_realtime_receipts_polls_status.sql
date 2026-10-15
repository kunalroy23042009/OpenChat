-- Instant ticks + live polls/status: realtime publication plus sender/member SELECT.
-- RPCs remain write path; realtime is read-only live updates.
-- Idempotent: safe to re-run (checks publication membership first).
begin;
alter table public.envelope_receipts replica identity full;
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'envelope_receipts'
  ) then
    alter publication supabase_realtime add table public.envelope_receipts;
  end if;
end $$;
grant select on public.envelope_receipts to authenticated;
drop policy if exists envelope_receipts_sender_read on public.envelope_receipts;
create policy envelope_receipts_sender_read on public.envelope_receipts
  for select to authenticated
  using (
    sender_id = (select auth.uid()) or recipient_id = (select auth.uid())
  );

alter table public.poll_votes replica identity full;
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'poll_votes'
  ) then
    alter publication supabase_realtime add table public.poll_votes;
  end if;
end $$;

alter table public.status_updates replica identity full;
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'status_updates'
  ) then
    alter publication supabase_realtime add table public.status_updates;
  end if;
end $$;
commit;
