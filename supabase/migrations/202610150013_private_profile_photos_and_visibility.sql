begin;

-- Profile photos must not share the public group-avatar bucket. Store a
-- private object path and issue signed URLs only after this policy check.
alter table public.profiles add column if not exists avatar_path text
  check (avatar_path is null or char_length(avatar_path) between 1 and 500);

alter table public.user_preferences
  add column if not exists about_privacy varchar(20) not null default 'contacts';
alter table public.user_preferences
  drop constraint if exists user_preferences_last_seen_privacy_check,
  drop constraint if exists user_preferences_profile_photo_privacy_check,
  add constraint user_preferences_last_seen_privacy_check
    check (last_seen_privacy in ('everyone','contacts','except','only','nobody')),
  add constraint user_preferences_profile_photo_privacy_check
    check (profile_photo_privacy in ('everyone','contacts','except','only','nobody')),
  add constraint user_preferences_about_privacy_check
    check (about_privacy in ('everyone','contacts','except','only','nobody'));

create table if not exists public.profile_visibility_exceptions (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  field text not null check (field in ('profile_photo','about','last_seen')),
  subject_id uuid not null references public.profiles(id) on delete cascade,
  primary key (owner_id, field, subject_id),
  check (owner_id <> subject_id)
);
alter table public.profile_visibility_exceptions enable row level security;
revoke all on public.profile_visibility_exceptions from public, anon, authenticated;

create or replace function public.can_view_profile_field(
  p_owner_id uuid,
  p_viewer_id uuid,
  p_field text
)
returns boolean stable language plpgsql security definer set search_path = '' as $$
declare audience text := 'contacts'; is_contact boolean;
begin
  if p_owner_id is null or p_viewer_id is null then return false; end if;
  if p_owner_id = p_viewer_id then return true; end if;
  if p_field not in ('profile_photo','about','last_seen') then return false; end if;
  if exists (
    select 1 from public.contact_blocks b
    where (b.owner_id = p_owner_id and b.blocked_id = p_viewer_id)
       or (b.owner_id = p_viewer_id and b.blocked_id = p_owner_id)
  ) then return false; end if;

  select case p_field
    when 'profile_photo' then coalesce(pref.profile_photo_privacy, 'contacts')
    when 'about' then coalesce(pref.about_privacy, 'contacts')
    else coalesce(pref.last_seen_privacy, 'contacts')
  end into audience
  from public.user_preferences pref where pref.user_id = p_owner_id;
  audience := coalesce(audience, 'contacts');
  if audience = 'everyone' then return true; end if;
  if audience = 'nobody' then return false; end if;
  if audience = 'only' then
    return exists (
      select 1 from public.profile_visibility_exceptions e
      where e.owner_id = p_owner_id and e.field = p_field and e.subject_id = p_viewer_id
    );
  end if;

  select exists (
    select 1 from public.contact_requests c
    where c.status = 'accepted'
      and ((c.sender_id = p_owner_id and c.recipient_id = p_viewer_id)
        or (c.recipient_id = p_owner_id and c.sender_id = p_viewer_id))
  ) into is_contact;
  if not is_contact then return false; end if;
  if audience = 'except' then
    return not exists (
      select 1 from public.profile_visibility_exceptions e
      where e.owner_id = p_owner_id and e.field = p_field and e.subject_id = p_viewer_id
    );
  end if;
  return true;
end;
$$;
revoke all on function public.can_view_profile_field(uuid,uuid,text) from public, anon;
grant execute on function public.can_view_profile_field(uuid,uuid,text) to authenticated;

create or replace function public.replace_profile_visibility_exceptions(
  p_field text,
  p_subject_ids uuid[] default '{}'
)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); ids uuid[] := coalesce(p_subject_ids, '{}');
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_field not in ('profile_photo','about','last_seen') then
    raise exception 'Invalid profile visibility field';
  end if;
  if coalesce(array_length(ids, 1), 0) > 500 then
    raise exception 'Choose no more than 500 contacts';
  end if;
  if exists (
    select 1 from unnest(ids) subject
    where subject = me or not exists (
      select 1 from public.contact_requests c
      where c.status = 'accepted'
        and ((c.sender_id = me and c.recipient_id = subject)
          or (c.recipient_id = me and c.sender_id = subject))
    )
  ) then raise exception 'Choose accepted contacts only'; end if;

  delete from public.profile_visibility_exceptions
  where owner_id = me and field = p_field;
  insert into public.profile_visibility_exceptions(owner_id, field, subject_id)
  select me, p_field, subject from unnest(ids) subject
  on conflict do nothing;
end;
$$;
revoke all on function public.replace_profile_visibility_exceptions(text,uuid[]) from public, anon;
grant execute on function public.replace_profile_visibility_exceptions(text,uuid[]) to authenticated;

create or replace function public.list_profile_visibility_exceptions(p_field text)
returns uuid[] language sql security definer set search_path = '' as $$
  select coalesce(array_agg(subject_id order by subject_id), '{}'::uuid[])
  from public.profile_visibility_exceptions
  where owner_id = auth.uid() and field = p_field;
$$;
revoke all on function public.list_profile_visibility_exceptions(text) from public, anon;
grant execute on function public.list_profile_visibility_exceptions(text) to authenticated;

insert into storage.buckets(id, name, public)
values ('profile-avatars', 'profile-avatars', false)
on conflict (id) do update set public = false;

drop policy if exists "profile avatars insert own" on storage.objects;
create policy "profile avatars insert own" on storage.objects for insert to authenticated
with check (
  bucket_id = 'profile-avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);
drop policy if exists "profile avatars update own" on storage.objects;
create policy "profile avatars update own" on storage.objects for update to authenticated
using (bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = auth.uid()::text)
with check (bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "profile avatars delete own" on storage.objects;
create policy "profile avatars delete own" on storage.objects for delete to authenticated
using (bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "profile avatars read by audience" on storage.objects;
create policy "profile avatars read by audience" on storage.objects for select to authenticated
using (
  bucket_id = 'profile-avatars'
  and public.can_view_profile_field((storage.foldername(name))[1]::uuid, auth.uid(), 'profile_photo')
);

create or replace function public.set_profile_avatar(p_path text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_path is not null and (
    p_path not like me::text || '/%'
    or char_length(p_path) not between 1 and 500
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'profile-avatars' and name = p_path
    )
  ) then raise exception 'Invalid profile photo'; end if;
  update public.profiles set avatar_path = p_path, avatar_url = null where id = me;
end;
$$;
revoke all on function public.set_profile_avatar(text) from public, anon;
grant execute on function public.set_profile_avatar(text) to authenticated;

create or replace function public.upsert_preferences(p_values jsonb)
returns public.user_preferences language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result public.user_preferences;
begin
  if me is null then raise exception 'Sign in required'; end if;
  insert into public.user_preferences(user_id) values(me) on conflict do nothing;
  update public.user_preferences set
    read_receipts = coalesce((p_values->>'read_receipts')::boolean, read_receipts),
    last_seen_privacy = coalesce(p_values->>'last_seen_privacy', last_seen_privacy),
    profile_photo_privacy = coalesce(p_values->>'profile_photo_privacy', profile_photo_privacy),
    about_privacy = coalesce(p_values->>'about_privacy', about_privacy),
    status_privacy = coalesce(p_values->>'status_privacy', status_privacy),
    default_disappearing_seconds = case when p_values ? 'default_disappearing_seconds'
      then (p_values->>'default_disappearing_seconds')::integer else default_disappearing_seconds end,
    focus_mode = coalesce((p_values->>'focus_mode')::boolean, focus_mode),
    focus_message = case when p_values ? 'focus_message' then p_values->>'focus_message' else focus_message end,
    updated_at = now()
  where user_id = me returning * into result;
  return result;
end;
$$;
revoke all on function public.upsert_preferences(jsonb) from public, anon;
grant execute on function public.upsert_preferences(jsonb) to authenticated;

create or replace function public.list_my_contacts()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at desc), '[]'::jsonb) into result from (
    select r.id as request_id, p.id as user_id, p.display_name, p.username,
      case when public.can_view_profile_field(p.id, me, 'about') then p.about end as about,
      case when public.can_view_profile_field(p.id, me, 'profile_photo') then p.avatar_path end as avatar_path,
      r.status, (r.recipient_id = me) as incoming, r.created_at
    from public.contact_requests r join public.profiles p
      on p.id = case when r.sender_id = me then r.recipient_id else r.sender_id end
    where me in (r.sender_id,r.recipient_id) and r.status in ('pending','accepted')
      and not exists(select 1 from public.contact_blocks b where (b.owner_id = me and b.blocked_id = p.id) or (b.owner_id = p.id and b.blocked_id = me))
    union all
    select null::uuid, p.id, p.display_name, p.username, null::text, null::text, 'blocked', false, p.created_at
    from public.contact_blocks b join public.profiles p on p.id = b.blocked_id where b.owner_id = me
  ) items;
  return result;
end;
$$;
revoke all on function public.list_my_contacts() from public, anon;
grant execute on function public.list_my_contacts() to authenticated;

create or replace function public.find_contact_by_phone(p_phone text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); row public.profiles;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select * into row from public.profiles where phone_number = trim(p_phone);
  if not found or row.id = me or exists(select 1 from public.contact_blocks
    where (owner_id = me and blocked_id = row.id) or (owner_id = row.id and blocked_id = me)) then return null; end if;
  return jsonb_build_object('user_id', row.id, 'username', row.username,
    'display_name', row.display_name,
    'about', case when public.can_view_profile_field(row.id, me, 'about') then row.about end,
    'avatar_path', case when public.can_view_profile_field(row.id, me, 'profile_photo') then row.avatar_path end);
end;
$$;
revoke all on function public.find_contact_by_phone(text) from public, anon;
grant execute on function public.find_contact_by_phone(text) to authenticated;

create or replace function public.lookup_contacts_by_phones(p_phones text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_phones is null or coalesce(array_length(p_phones, 1), 0) not between 1 and 500 then
    raise exception 'Provide 1-500 phone numbers.';
  end if;
  select coalesce(jsonb_agg(to_jsonb(items)), '[]'::jsonb) into result from (
    select p.id as user_id, p.display_name, p.username,
      case when public.can_view_profile_field(p.id, me, 'about') then p.about end as about,
      case when public.can_view_profile_field(p.id, me, 'profile_photo') then p.avatar_path end as avatar_path,
      p.phone_number as phone
    from public.profiles p
    where p.phone_number = any(p_phones) and p.id <> me
      and not exists(select 1 from public.contact_blocks b
        where (b.owner_id = me and b.blocked_id = p.id) or (b.owner_id = p.id and b.blocked_id = me))
  ) items;
  return result;
end;
$$;
revoke all on function public.lookup_contacts_by_phones(text[]) from public, anon;
grant execute on function public.lookup_contacts_by_phones(text[]) to authenticated;

create or replace function public.list_conversation_members(p_conversation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()) then
    raise exception 'Not a member';
  end if;
  return (select coalesce(jsonb_agg(to_jsonb(r) order by r.joined_at), '[]'::jsonb)
    from (select m.user_id, m.role, m.joined_at, p.display_name, p.username,
      case when public.can_view_profile_field(p.id, auth.uid(), 'profile_photo') then p.avatar_path end as avatar_path
      from public.conversation_members m join public.profiles p on p.id = m.user_id
      where m.conversation_id = p_conversation_id) r);
end;
$$;
revoke all on function public.list_conversation_members(uuid) from public, anon;
grant execute on function public.list_conversation_members(uuid) to authenticated;

create or replace function public.fetch_group_messages(
  p_conversation_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if not exists(select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = me) then
    raise exception 'Not a member of this conversation';
  end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at), '[]'::jsonb) into result from (
    select gm.id, gm.conversation_id, gm.sender_id, gm.parent_message_id,
      gm.content, gm.type, gm.media_url, gm.metadata, gm.is_edited, gm.edited_at,
      gm.is_deleted, gm.is_view_once, gm.is_forwarded, gm.forward_count, gm.created_at,
      p.display_name as sender_name,
      case when public.can_view_profile_field(p.id, me, 'profile_photo') then p.avatar_path end as sender_avatar_path,
      (select coalesce(jsonb_agg(jsonb_build_object('emoji', r.emoji, 'user_id', r.user_id)), '[]'::jsonb)
        from public.message_reactions r where r.message_id = gm.id) as reactions
    from public.group_messages gm join public.profiles p on p.id = gm.sender_id
    where gm.conversation_id = p_conversation_id
      and (p_before is null or gm.created_at < p_before)
      and not coalesce((gm.metadata->'deleted_for'->>me::text)::boolean, false)
    order by gm.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) items;
  insert into public.group_message_receipts(message_id, user_id, status)
  select gm.id, me, 'delivered' from public.group_messages gm
  where gm.conversation_id = p_conversation_id and gm.sender_id <> me
    and not exists (select 1 from public.group_message_receipts r where r.message_id = gm.id and r.user_id = me)
  on conflict (message_id, user_id) do nothing;
  return result;
end;
$$;
revoke all on function public.fetch_group_messages(uuid,timestamptz,integer) from public, anon;
grant execute on function public.fetch_group_messages(uuid,timestamptz,integer) to authenticated;

commit;
