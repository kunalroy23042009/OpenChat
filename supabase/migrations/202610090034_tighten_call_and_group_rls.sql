-- Remove an older ambiguous group_messages policy whose unqualified
-- conversation_id resolved to the inner table, making the predicate tautology.
drop policy if exists group_messages_read on public.group_messages;

-- Call invites are written only through membership-checked SECURITY DEFINER
-- RPCs. Clients need SELECT for Realtime/status UI, not direct table writes.
drop policy if exists call_invites_caller_write on public.call_invites;
drop policy if exists call_invites_callee_update on public.call_invites;
drop policy if exists call_invites_caller_update on public.call_invites;
revoke insert, update on public.call_invites from authenticated;
