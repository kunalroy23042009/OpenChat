-- Authors can delete their own status updates before expiry.
-- Idempotent: safe to re-run.
begin;
alter table public.status_updates replica identity full;
drop policy if exists status_author_delete on public.status_updates;
create policy status_author_delete on public.status_updates
  for delete to authenticated
  using (author_id = (select auth.uid()));
commit;
