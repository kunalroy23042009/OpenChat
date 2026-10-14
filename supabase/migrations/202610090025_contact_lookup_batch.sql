-- Batch address-book lookup for WhatsApp-style contact sync. The caller
-- submits E.164 numbers from the device address book; only matching
-- profiles come back (no global directory). Self and blocked users are
-- excluded, mirroring find_contact_by_phone.
-- Idempotent, transaction-managed by the caller: no explicit begin/commit.
create or replace function public.lookup_contacts_by_phones(p_phones text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in required'; end if;
  if p_phones is null or coalesce(array_length(p_phones, 1), 0) not between 1 and 500 then
    raise exception 'Provide 1-500 phone numbers.';
  end if;
  select coalesce(jsonb_agg(to_jsonb(items)), '[]'::jsonb) into result from (
    select p.id as user_id, p.display_name, p.username, p.about, p.avatar_url, p.phone_number as phone
    from public.profiles p
    where p.phone_number = any(p_phones)
      and p.id <> me
      and not exists(select 1 from public.contact_blocks b
        where (b.owner_id = me and b.blocked_id = p.id)
           or (b.owner_id = p.id and b.blocked_id = me))
  ) items;
  return result;
end;
$$;
revoke all on function public.lookup_contacts_by_phones(text[]) from public, anon, authenticated;
grant execute on function public.lookup_contacts_by_phones(text[]) to authenticated;
