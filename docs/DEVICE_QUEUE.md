# Device-required task queue

No physical device is available right now. These tasks are queued and must
not be marked complete without hardware runs.

## 1. Two-device live messaging test (Phase 4 acceptance)
- Publish keys on device A and B; claim, process bundle, send A→B and B→A.
- Verify offline catch-up via `fetch_inbox` + `ack_messages` after restart.
- Verify quota refusal, blocked-contact refusal, and duplicate-send single bubble.
- Verify undecryptable envelope is dropped (acked) without a poison poll loop.

## 2. Native diagnostics on hardware (Phase 3 acceptance)
- Run the in-app `selfTest` on a physical Android device.
- Confirm Keystore persistence across restarts and tamper-fails-closed behavior.
- Confirm `signalHasSession` no longer burns peer one-time prekeys on screen open.

## 3. Safety-number verification round trip
- Compare the verification sheet fingerprints on both devices character by character.
- Mark verified on A, rotate B's identity (reinstall), confirm A shows the key-changed warning.

## 4. Push and background sync (Phase 5)
- Background notification receipt, foreground catch-up, notification navigation.
- Document force-quit behavior per OS restrictions.

## 5. Encrypted local DB export check
- Export app data and confirm no plaintext message bodies or private keys.

## 7. Calling implementation and acceptance (design in `docs/CALLING_PLAN.md`)
- Human step first: create the LiveKit Cloud project, confirm the Build-plan
  allowance is granted; calling stays disabled otherwise.
- Implement `issue-call-token` Edge Function to spec; add `livekit_client`
  ^2.13.0, platform permissions, and the call screen.
- Two physical devices across different NATs: invite/accept/reject/timeout,
  interruption/reconnect, ciphertext-only at the provider, TTL cutoff,
  force-quit behavior.

## 6. Attachment end-to-end (Phase 5 client; server tables land in `202610090007`)
- R2 Edge Function issuing presigned URLs from `reserve_attachment` /
  `authorize_download` coordinates (server never sees file keys).
- Client-side file encryption with independent random key/nonce; key, integrity
  data, and object reference travel inside the Signal-encrypted message.
- Verify actual uploaded size via `finalize_attachment`; confirm R2 admin sees
  ciphertext only and unauthorized URLs fail.
