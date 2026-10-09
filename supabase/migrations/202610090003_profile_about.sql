-- Apply after 202610090002_contacts.sql.
begin;
alter table public.profiles add column about text not null
  default 'Hey there! I am using Open Chat.'
  check (char_length(about) between 0 and 140);

-- Replace two-argument profile writer with name/username/about version.
revoke all on function public.save_profile(text,text) from public, anon, authenticated;
drop function public.save_profile(text,text);
create function public.save_profile(p_display_name text, p_username text, p_about text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_display_name is null or p_username is null or p_about is null
     or char_length(trim(p_display_name)) not between 1 and 60
     or char_length(trim(p_about)) not between 1 and 140
     or lower(trim(p_username)) !~ '^[a-z][a-z0-9_]{2,23}$' then
    raise exception 'Enter a name, a valid username, and a short about line';
  end if;
  update public.profiles
    set display_name = trim(p_display_name),
        username = lower(trim(p_username)),
        about = trim(p_about)
    where id = me;
end;
$$;
revoke all on function public.save_profile(text,text,text) from public, anon, authenticated;
grant execute on function public.save_profile(text,text,text) to authenticated;

-- Include about lines in the scoped contact listing. No global directory.
create or replace function public.list_my_contacts()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by items.created_at desc), '[]'::jsonb) into result from (
    select r.id as request_id, p.id as user_id, p.display_name, p.username, p.about, r.status,
      (r.recipient_id = me) as incoming, r.created_at
    from public.contact_requests r join public.profiles p
      on p.id = case when r.sender_id = me then r.recipient_id else r.sender_id end
    where me in (r.sender_id,r.recipient_id) and r.status in ('pending','accepted')
      and not exists(select 1 from public.contact_blocks b where (b.owner_id = me and b.blocked_id = p.id) or (b.owner_id = p.id and b.blocked_id = me))
    union all
    select null::uuid, p.id, p.display_name, p.username, p.about, 'blocked', false, p.created_at
    from public.contact_blocks b join public.profiles p on p.id = b.blocked_id where b.owner_id = me
  ) items;
  return result;
end;
$$;
commit;
