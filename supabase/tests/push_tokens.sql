-- Run with psql -v ON_ERROR_STOP=1 after all four migrations, as DB owner.
-- Verifies push-token isolation, single-device cap, and validation.
begin;
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.save_profile('Alice', 'alice', 'Coffee first.');
select public.register_push_token('alice-android-token-000000000000000001', 'android');
select public.register_push_token('alice-android-token-000000000000000002', 'android');
do $$ begin
  if (select count(*) from public.push_tokens) <> 1 then raise exception 'Single-device cap failed'; end if;
  if (select token from public.push_tokens) <> 'alice-android-token-000000000000000002' then raise exception 'Newest token not kept'; end if;
  begin
    perform public.register_push_token('x', 'android');
    raise exception 'Short token accepted';
  exception when raise_exception then
    if sqlerrm <> 'Invalid push token' then raise; end if;
  end;
  begin
    perform public.register_push_token('alice-android-token-000000000000000003', 'desktop');
    raise exception 'Bad platform accepted';
  exception when raise_exception then
    if sqlerrm <> 'Invalid push token' then raise; end if;
  end;
  begin
    insert into public.push_tokens(user_id, token, platform)
      values ('00000000-0000-0000-0000-000000000002', 'direct-write-token-00000000000001', 'android');
    raise exception 'Direct token write allowed';
  exception when insufficient_privilege then null; end;
end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.save_profile('Bob', 'bob', 'Trail runner.');
do $$ begin
  if (select count(*) from public.push_tokens) <> 0 then raise exception 'Cross-user token leak'; end if;
  begin
    perform public.register_push_token('alice-android-token-000000000000000002', 'android');
    raise exception 'Foreign token adopted';
  exception when raise_exception then
    if sqlerrm <> 'Token unavailable' then raise; end if;
  end;
  begin
    delete from public.push_tokens;
  exception when insufficient_privilege then null; end;
end $$;
select public.register_push_token('bob-ios-token-00000000000000000000001', 'ios');
select public.unregister_push_token('bob-ios-token-00000000000000000000001');
do $$ begin
  if (select count(*) from public.push_tokens) <> 0 then raise exception 'Unregister failed'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$ begin
  -- Bob's delete attempt above must not have removed Alice's token.
  if (select count(*) from public.push_tokens) <> 1 then raise exception 'Foreign delete removed token'; end if;
  if (select token from public.push_tokens) <> 'alice-android-token-000000000000000002' then raise exception 'Wrong token survived'; end if;
end $$;

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$ begin
  begin
    perform public.register_push_token('anon-token-00000000000000000000000001', 'web');
    raise exception 'Anonymous token registration allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select 'Push-token isolation, cap, and validation tests passed' as result;
