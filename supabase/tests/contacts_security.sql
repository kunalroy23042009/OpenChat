-- Run with psql -v ON_ERROR_STOP=1 after all three migrations, as DB owner.
-- Uses simulated JWT subjects and real PostgreSQL roles/RLS. Rolls back fixtures.
begin;
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.save_profile('Alice', 'alice', 'Coffee first.');
do $$ begin
  if (select count(*) from public.profiles) <> 1 then raise exception 'RLS profile leak'; end if;
  if (select about from public.profiles) <> 'Coffee first.' then raise exception 'About line missing'; end if;
  begin
    update public.profiles set username = 'bypass';
    raise exception 'Direct username writes allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.contact_requests(sender_id,recipient_id) values(auth.uid(),'00000000-0000-0000-0000-000000000002');
    raise exception 'Direct invite writes allowed';
  exception when insufficient_privilege then null; end;
end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.save_profile('Bob', 'bob', 'Trail runner.');
do $$ begin
  begin
    perform public.save_profile('Bob', 'alice', 'Taken.');
    raise exception 'Duplicate username allowed';
  exception when unique_violation then null; end;
  begin
    perform public.save_profile('Bob', 'bob', '');
    raise exception 'Empty about allowed';
  exception when raise_exception then
    if sqlerrm <> 'Enter a name, a valid username, and a short about line' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select public.save_profile('Eve', 'eve', 'Just looking around.');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  if public.send_contact_invite('BOB') <> 'sent' then raise exception 'Invitation failed'; end if;
  if public.send_contact_invite('bob') <> 'already_sent' then raise exception 'Duplicate invitation'; end if;
  if jsonb_array_length(public.list_my_contacts()) <> 1 then raise exception 'Outgoing invite missing'; end if;
  begin
    perform public.respond_contact_invite((select id from public.contact_requests limit 1), true);
    raise exception 'Sender accepted own invitation';
  exception when raise_exception then
    if sqlerrm <> 'Invitation unavailable' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
do $$ begin
  if (select count(*) from public.contact_requests) <> 0 then raise exception 'Third-party invitation leak'; end if;
  if public.list_my_contacts() <> '[]'::jsonb then raise exception 'Third-party contact leak'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ begin
  if public.send_contact_invite('alice') <> 'incoming_pending' then raise exception 'Cross-invite duplicated'; end if;
  perform public.respond_contact_invite((select id from public.contact_requests limit 1), true);
  if public.list_my_contacts()->0->>'status' <> 'accepted' then raise exception 'Accept failed'; end if;
  if public.list_my_contacts()->0->>'about' <> 'Coffee first.' then raise exception 'Contact about missing'; end if;
  perform public.block_contact('00000000-0000-0000-0000-000000000001');
  if public.list_my_contacts()->0->>'status' <> 'blocked' then raise exception 'Block missing'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  if public.send_contact_invite('bob') <> 'unavailable' then raise exception 'Block bypass'; end if;
  if public.list_my_contacts() <> '[]'::jsonb then raise exception 'Blocked contact visible'; end if;
  perform public.unblock_contact('00000000-0000-0000-0000-000000000002');
  if public.send_contact_invite('bob') <> 'unavailable' then raise exception 'Other user unblocked blocker'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.unblock_contact('00000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  if public.send_contact_invite('bob') <> 'sent' then raise exception 'Reinvite after unblock failed'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.respond_contact_invite((select id from public.contact_requests limit 1), false);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  if public.send_contact_invite('bob') <> 'unavailable' then raise exception 'Declined invitation resent'; end if;
end $$;

-- Failed username probes consume the same daily budget as successful invites.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
do $$ begin
  for i in 1..20 loop
    if public.send_contact_invite('missing_person') <> 'unavailable' then raise exception 'Unexpected budget cutoff'; end if;
  end loop;
  if public.send_contact_invite('alice') <> 'rate_limited' then raise exception 'Rate cap bypass'; end if;
end $$;

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$ begin
  begin
    perform public.list_my_contacts();
    raise exception 'Anonymous RPC allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.profiles;
    raise exception 'Anonymous table read allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select 'Contact authorization, lifecycle, and rate-limit tests passed' as result;
