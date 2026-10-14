-- Enforce a minimal server-visible envelope shape for encrypted groups.
-- Message content must be ciphertext; no parallel media/reply/forward fields
-- or extra plaintext metadata may accompany it.
begin;

create or replace function public.enforce_group_e2ee_content()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  encrypted boolean;
begin
  select c.e2ee_enabled into encrypted
  from public.conversations c where c.id = new.conversation_id;
  if not coalesce(encrypted, false) then
    return new;
  end if;

  if coalesce(new.is_deleted, false)
     and new.content = 'This message was deleted' then
    return new;
  end if;

  if new.metadata->>'e2ee' is distinct from 'true'
     or (new.metadata - array['e2ee', 'epoch']) <> '{}'::jsonb
     or new.content not like 'E2E1:%'
     or new.type <> 'text'
     or new.media_url is not null
     or new.parent_message_id is not null
     or coalesce(new.is_view_once, false)
     or coalesce(new.is_forwarded, false)
     or coalesce(new.forward_count, 0) <> 0 then
    raise exception 'End-to-end encryption is required for all group content';
  end if;
  return new;
end;
$$;

commit;
