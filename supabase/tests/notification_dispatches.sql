-- Disposable local database only; migration 0022 already applied.
begin;
insert into auth.users(id) values
 ('00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000002');
set local role authenticated;
do $$ begin
  begin
    perform public.claim_notification_dispatch('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','message','event');
    raise exception 'Client could claim push dispatch';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role service_role;
do $$ begin
  if not public.claim_notification_dispatch('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','message','event') then raise exception 'Initial claim denied'; end if;
  if public.claim_notification_dispatch('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','message','event') then raise exception 'Duplicate claimed'; end if;
end $$;
reset role;
update public.notification_dispatches set attempted_at = now() - interval '1 minute';
set local role service_role;
do $$ begin
  if not public.claim_notification_dispatch('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','message','event') then raise exception 'Retry denied'; end if;
end $$;
reset role;
update public.notification_dispatches set attempted_at = now() - interval '1 minute', sent = true;
set local role service_role;
do $$ begin
  if public.claim_notification_dispatch('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','message','event') then raise exception 'Sent event replayed'; end if;
end $$;
rollback;
