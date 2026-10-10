-- Migration 202610090008: WhatsApp-style Phone Number Authentication & Lookup

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS phone_number text UNIQUE;

CREATE INDEX IF NOT EXISTS idx_profiles_phone_number ON public.profiles (phone_number);

-- Phone number invitation lookup RPC
CREATE OR REPLACE FUNCTION public.send_invite_by_phone(p_phone text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_id uuid := auth.uid();
  v_target_id uuid;
  v_target_username text;
BEGIN
  IF v_sender_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required.' USING ERRCODE = '42501';
  END IF;

  SELECT id, username INTO v_target_id, v_target_username
  FROM public.profiles
  WHERE phone_number = p_phone;

  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'No user found with that phone number.' USING ERRCODE = 'P0001';
  END IF;

  IF v_target_id = v_sender_id THEN
    RAISE EXCEPTION 'You cannot invite yourself.' USING ERRCODE = 'P0001';
  END IF;

  IF v_target_username IS NOT NULL AND v_target_username <> '' THEN
    RETURN public.send_contact_invite(v_target_username);
  ELSE
    -- Direct invitation fallback if username is blank
    INSERT INTO public.invitations (sender_id, recipient_id, status)
    VALUES (v_sender_id, v_target_id, 'pending')
    ON CONFLICT (sender_id, recipient_id) DO NOTHING;
    RETURN 'Invitation sent successfully to phone contact.';
  END IF;
END;
$$;
