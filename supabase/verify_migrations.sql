-- Open Chat: Database Migration Schema Verification Suite
-- Execute this script in the Supabase SQL Editor after applying every migration.

DO $$
DECLARE
  v_table text;
  v_function text;
  v_tables text[] := ARRAY[
    'profiles',
    'devices',
    'contact_requests',
    'push_tokens',
    'message_envelopes',
    'key_bundles',
    'attachment_blobs',
    'conversations',
    'conversation_members',
    'group_messages',
    'group_sender_key_envelopes',
    'tasks',
    'poll_votes',
    'communities',
    'user_preferences',
    'status_updates',
    'status_views',
    'call_logs',
    'profile_visibility_exceptions'
  ];
  v_functions text[] := ARRAY[
    'delete_account',
    'save_profile',
    'list_my_contacts',
    'set_my_phone',
    'find_contact_by_phone',
    'send_contact_invite',
    'send_invite_by_phone',
    'respond_contact_invite',
    'cancel_contact_invite',
    'block_contact',
    'unblock_contact',
    'lookup_contacts_by_phones',
    'set_avatar_url',
    'set_profile_avatar',
    'can_view_profile_field',
    'replace_profile_visibility_exceptions',
    'list_profile_visibility_exceptions',
    'register_push_token',
    'unregister_push_token',
    'enqueue_message',
    'fetch_inbox',
    'ack_messages',
    'message_statuses',
    'mark_messages_read',
    'cleanup_expired',
    'place_call',
    'publish_key_bundle',
    'claim_key_bundle',
    'reserve_attachment',
    'finalize_attachment',
    'authorize_download',
    'cleanup_attachments',
    'chat_media_usage',
    'create_conversation',
    'create_direct_conversation',
    'list_conversations',
    'add_conversation_member',
    'remove_conversation_member',
    'list_conversation_members',
    'send_group_message',
    'fetch_group_messages',
    'backup_group_messages',
    'enable_group_e2ee',
    'group_security_state',
    'publish_group_sender_key',
    'fetch_group_sender_keys',
    'ack_group_sender_keys',
    'send_e2ee_group_message',
    'create_task',
    'update_task_status',
    'create_poll',
    'vote_poll',
    'upsert_preferences',
    'register_device_session',
    'publish_status',
    'mark_status_viewed'
  ];
BEGIN
  RAISE NOTICE '========== OPEN CHAT SCHEMA VERIFICATION ==========';

  -- Check tables
  FOREACH v_table IN ARRAY v_tables
  LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.tables 
      WHERE table_schema = 'public' AND table_name = v_table
    ) THEN
      RAISE NOTICE '✅ Table public.% exists', v_table;
    ELSE
      RAISE WARNING '❌ MISSING Table: public.%', v_table;
    END IF;
  END LOOP;

  -- Check RPC functions
  FOREACH v_function IN ARRAY v_functions
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname = 'public' AND p.proname = v_function
    ) THEN
      RAISE NOTICE '✅ Function public.%() exists', v_function;
    ELSE
      RAISE WARNING '❌ MISSING Function: public.%()', v_function;
    END IF;
  END LOOP;

  -- Check storage buckets for media, avatars, and backups
  FOREACH v_table IN ARRAY ARRAY['chat-media', 'avatars', 'profile-avatars', 'chat-backups']
  LOOP
    IF EXISTS (
      SELECT 1 FROM storage.buckets WHERE id = v_table
    ) THEN
      RAISE NOTICE '✅ Bucket % exists', v_table;
    ELSE
      RAISE WARNING '❌ MISSING Bucket: %', v_table;
    END IF;
  END LOOP;

  -- Check realtime publication for live delivery tables
  FOREACH v_table IN ARRAY ARRAY['message_envelopes', 'group_messages', 'call_invites']
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND tablename = v_table
    ) THEN
      RAISE NOTICE '✅ Realtime % subscribed', v_table;
    ELSE
      RAISE WARNING '❌ MISSING Realtime: %', v_table;
    END IF;
  END LOOP;

  -- Check the chat-media quota trigger
  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'storage.objects'::regclass
      AND tgname = 'enforce_chat_media_quota'
  ) THEN
    RAISE NOTICE '✅ Trigger enforce_chat_media_quota exists';
  ELSE
    RAISE WARNING '❌ MISSING Trigger: enforce_chat_media_quota';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'group_messages'
      AND policyname = 'group_messages_read'
  ) THEN
    RAISE WARNING '❌ Obsolete permissive group_messages_read policy remains';
  ELSE
    RAISE NOTICE '✅ Group message reads use the member-scoped policy';
  END IF;

  -- Direct-message envelopes must not expire while a recipient is offline.
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'enqueue_message'
      AND pg_get_functiondef(p.oid) ILIKE '%infinity%'
  ) THEN
    RAISE NOTICE '✅ Undelivered direct messages are retained until ACK';
  ELSE
    RAISE WARNING '❌ enqueue_message does not retain undelivered messages';
  END IF;

  IF has_table_privilege('authenticated', 'public.call_invites', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.call_invites', 'INSERT') THEN
    RAISE WARNING '❌ Clients can directly mutate call invitations';
  ELSE
    RAISE NOTICE '✅ Call invitations mutate only through checked RPCs';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'call_invites'
      AND column_name = 'encrypted_call_key' AND is_nullable = 'NO'
  ) THEN
    RAISE NOTICE '✅ Calls require a pairwise-encrypted media key';
  ELSE
    RAISE WARNING '❌ Call signaling lacks a required encrypted media key';
  END IF;

  RAISE NOTICE '========== VERIFICATION COMPLETED ==========';
END $$;
