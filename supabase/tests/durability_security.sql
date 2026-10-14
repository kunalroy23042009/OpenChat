-- Read-only production schema assertions for the durability/security fixes.
-- Run with: supabase db query --linked --file supabase/tests/durability_security.sql
do $$
begin
  if to_regprocedure('public.enqueue_message(uuid,text,text)') is null
     or position(
       'infinity' in pg_get_functiondef(
         'public.enqueue_message(uuid,text,text)'::regprocedure
       )
     ) = 0 then
    raise exception 'Undelivered message retention is not installed';
  end if;

  if exists (
    select 1 from public.message_envelopes
    where expires_at <> 'infinity'::timestamptz
  ) then
    raise exception 'There are pending messages that still expire';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'group_messages'
      and policyname = 'group_messages_read'
  ) then
    raise exception 'Obsolete broad group-message policy is still installed';
  end if;

  if not has_table_privilege(
       'authenticated', 'public.group_messages', 'SELECT'
     ) or not has_table_privilege(
       'authenticated', 'public.call_invites', 'SELECT'
     ) then
    raise exception 'Authenticated read access required by app is missing';
  end if;

  if has_table_privilege('authenticated', 'public.call_invites', 'INSERT')
     or has_table_privilege('authenticated', 'public.call_invites', 'UPDATE') then
    raise exception 'Clients can bypass checked call-signaling RPCs';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'call_invites'
      and column_name = 'encrypted_call_key' and is_nullable = 'NO'
  ) then
    raise exception 'Call invites do not require encrypted media keys';
  end if;

  if to_regprocedure(
       'public.backup_group_messages(uuid,timestamp with time zone,uuid,integer)'
     ) is null then
    raise exception 'Stable-cursor group backup RPC is missing';
  end if;

  if position(
       'metadata - array' in pg_get_functiondef(
         'public.enforce_group_e2ee_content()'::regprocedure
       )
     ) = 0 then
    raise exception 'Encrypted group payload shape is not enforced';
  end if;

  if to_regprocedure('public.send_e2ee_group_message(uuid,uuid,integer,text)') is null
     or to_regprocedure('public.publish_group_sender_key(uuid,integer,uuid,jsonb)') is null
     or to_regprocedure('public.fetch_group_sender_keys(uuid,integer)') is null then
    raise exception 'Signal Sender-Key group RPCs are incomplete';
  end if;

  if to_regprocedure('public.group_security_state(uuid)') is null
     or to_regprocedure('public.enable_group_e2ee(uuid)') is null
     or not exists (
       select 1 from pg_trigger
       where tgrelid = 'public.group_messages'::regclass
         and tgname = 'group_messages_require_e2ee'
         and not tgisinternal
     ) then
    raise exception 'Encrypted group epoch or content enforcement is incomplete';
  end if;

  if has_table_privilege(
       'authenticated', 'public.group_sender_key_envelopes', 'SELECT'
     ) then
    raise exception 'Clients can bypass member-scoped sender-key RPCs';
  end if;
end;
$$;
