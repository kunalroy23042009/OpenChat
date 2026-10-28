-- Run with psql -v ON_ERROR_STOP=1 after the profile-visibility migration.
-- Uses the local auth.uid() stub and rolls back all fixtures.
begin;
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000041'),
  ('00000000-0000-0000-0000-000000000042'),
  ('00000000-0000-0000-0000-000000000043');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select public.save_profile('Owner', 'owner_visibility', 'Owner about');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000042', true);
select public.save_profile('Contact', 'contact_visibility', 'Contact about');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000043', true);
select public.save_profile('Stranger', 'stranger_visibility', 'Stranger about');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select public.send_contact_invite('contact_visibility');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000042', true);
select public.respond_contact_invite((select id from public.contact_requests limit 1), true);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select public.upsert_preferences('{"profile_photo_privacy":"contacts","about_privacy":"contacts"}'::jsonb);
do $$ begin
  if not public.can_view_profile_field('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000042', 'profile_photo') then
    raise exception 'Accepted contact could not see a contacts-only photo';
  end if;
  if public.can_view_profile_field('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000043', 'profile_photo') then
    raise exception 'Non-contact could see a contacts-only photo';
  end if;
end $$;

select public.upsert_preferences('{"profile_photo_privacy":"except"}'::jsonb);
select public.replace_profile_visibility_exceptions(
  'profile_photo', array['00000000-0000-0000-0000-000000000042']::uuid[]
);
do $$ begin
  if public.can_view_profile_field('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000042', 'profile_photo') then
    raise exception 'Excluded contact could see a photo';
  end if;
end $$;

select public.upsert_preferences('{"about_privacy":"only"}'::jsonb);
select public.replace_profile_visibility_exceptions(
  'about', array['00000000-0000-0000-0000-000000000042']::uuid[]
);
do $$ begin
  if not public.can_view_profile_field('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000042', 'about') then
    raise exception 'Selected contact could not see about';
  end if;
  if public.can_view_profile_field('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000043', 'about') then
    raise exception 'Unselected non-contact could see about';
  end if;
end $$;

reset role;
rollback;
select 'Profile visibility tests passed' as result;
