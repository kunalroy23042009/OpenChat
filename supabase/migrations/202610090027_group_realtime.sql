-- Live delivery for group messages. Mirrors 0009 (envelopes): Postgres
-- Changes needs the table in the realtime publication plus a member-only
-- SELECT grant/policy. RPCs remain the write path; row contents stay
-- scoped to conversation members by policy.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
alter table public.group_messages replica identity full;
alter publication supabase_realtime add table public.group_messages;
grant select on public.group_messages to authenticated;
drop policy if exists "group_messages member read" on public.group_messages;
create policy "group_messages member read" on public.group_messages
  for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = group_messages.conversation_id
        and m.user_id = (select auth.uid())
    )
  );
