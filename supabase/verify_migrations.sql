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
    'tasks',
    'poll_votes',
    'communities',
    'user_preferences',
    'status_updates',
    'status_views',
    'call_logs'
  ];
  v_functions text[] := ARRAY[
    'delete_account',
    'set_username',
    'send_invitation',
    'respond_invitation',
    'block_contact',
    'unblock_contact',
    'register_push_token',
    'unregister_push_token',
    'enqueue_message',
    'fetch_inbox',
    'ack_messages',
    'publish_key_bundle',
    'claim_key_bundle',
    'reserve_attachment',
    'finalize_attachment',
    'authorize_download',
    'send_invite_by_phone',
    'create_conversation',
    'send_group_message',
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

  RAISE NOTICE '========== VERIFICATION COMPLETED ==========';
END $$;
