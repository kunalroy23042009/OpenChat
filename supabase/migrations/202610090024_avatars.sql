-- Profile photos for 1:1 contacts, WhatsApp-style.
-- LocalProfile/ProfilePage keep a device copy; this migration wires the
-- cloud half: a public avatars bucket, a set_avatar_url writer, and
-- avatar_url in the scoped contact listing. Photo privacy stays unenforced
-- (see profile_photo_privacy in 0017); avatars are visible to any signed-in
-- user who can already see the contact, matching the default 'everyone'.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
alter table public.profiles add column if not exists avatar_url text
  check (avatar_url is null or char_length(avatar_url) between 1 and 500);

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists "avatars insert own" on storage.objects;
create policy "avatars insert own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars update own" on storage.objects;
create policy "avatars update own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars delete own" on storage.objects;
create policy "avatars delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'avatars');

-- Points the caller's profile at an https avatar URL (usually a public
-- avatars-bucket URL). Null clears the photo back to initials.
create or replace function public.set_avatar_url(p_url text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_url is not null
     and (char_length(p_url) not between 1 and 500
          or p_url !~ '^https://') then
    raise exception 'Invalid avatar URL';
  end if;
  update public.profiles set avatar_url = p_url where id = me;
end;
$$;
revoke all on function public.set_avatar_url(text) from public, anon, authenticated;
grant execute on function public.set_avatar_url(text) to authenticated;

-- Same scoped listing as 0003, now including avatar_url. No global directory.
create or replace function public.list_my_contacts()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at desc), '[]'::jsonb) into result from (
    select r.id as request_id, p.id as user_id, p.display_name, p.username, p.about, p.avatar_url, r.status,
      (r.recipient_id = me) as incoming, r.created_at
    from public.contact_requests r join public.profiles p
      on p.id = case when r.sender_id = me then r.recipient_id else r.sender_id end
    where me in (r.sender_id,r.recipient_id) and r.status in ('pending','accepted')
      and not exists(select 1 from public.contact_blocks b where (b.owner_id = me and b.blocked_id = p.id) or (b.owner_id = p.id and b.blocked_id = me))
    union all
    select null::uuid, p.id, p.display_name, p.username, p.about, p.avatar_url, 'blocked', false, p.created_at
    from public.contact_blocks b join public.profiles p on p.id = b.blocked_id where b.owner_id = me
  ) items;
  return result;
end;
$$;
