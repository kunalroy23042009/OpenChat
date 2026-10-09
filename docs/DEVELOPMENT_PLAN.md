# Phase-wise development plan

## Product decisions

- Flutter/Dart; Android-first production client, iOS next. Web currently previews the UI; browser E2EE requires a separate SDK/storage assessment.
- One-to-one conversations, one active messaging device per user for the first secure release. Multi-device and groups follow later.
- Supabase Free for Auth, PostgreSQL, private Realtime, and bounded Edge Function work.
- Email/password for initial development; username/invite-based discovery. Phone SMS and uploaded address books are deferred because of cost/privacy requirements.
- Cloudflare R2 Standard for encrypted attachments, FCM/APNs for notifications, LiveKit as the candidate calling provider.
- Preserve a zero-dollar **bounded pilot** by refusing new resource-consuming operations before configured quotas; unlimited usage is not a requirement.

## Phase 1 — Runnable UI and local demo

**Status: implemented.**

Deliverables: adaptive chat list/detail, sample contacts, search, unread filtering, compose, persistent local demo history, new chat, settings, reset. Palette: signal blue `#245CDB`, slate ink `#22334E`, cloud `#F8FAFD`, mist `#EDF1F7`, per-contact pastel identity markers. Heavy compact headings and quiet utility labels keep the message content primary.

Acceptance: launch without credentials; send a message and retain it across restarts; search and unread filters work; narrow and wide layouts remain usable. Local-only labeling must be visible. No fake delivery ticks or online status.

## Phase 2 — Accounts, profiles, backend access

**Status: in progress.** Email/password UI, session-reactive settings and contact routing, editable profiles, unique usernames, invitations, accept/decline, block/unblock, a 20-attempt/day server cap, profile trigger, owner-only RLS, and device metadata migration are implemented. PostgreSQL authorization/lifecycle tests pass locally. Hosted migrations and two-account acceptance testing remain pending.

Remaining:
1. Provision development project and run migration; test with two users plus anonymous access.
2. Add password recovery, native auth redirects, and account deletion.
3. Select a free SMTP allowance or OAuth provider for public onboarding; keep confirmed dashboard test accounts for private development.
4. Validate the implemented username/invitation/block flows on two real accounts; add pending invitation cancellation and reviewed re-invitation rules. Contact refresh is manual/on-resume for now.
5. Implement device registration RPC capped at one active device; account/device revocation.

Acceptance: user A cannot read or mutate user B's private profile/device rows; anonymous access is denied; sign-in survives restart; sign-out clears production session-dependent state; limits cannot be bypassed through direct REST calls.

## Phase 3 — Signal and encrypted local persistence

**Status: planned; prerequisite for network messaging.**

1. Time-box an SDK compatibility spike: evaluate maintained libsignal native bindings, Android/iOS build integration, license obligations, supported protocol versions, and upstream test vectors. Do not invent a Dart replacement protocol.
2. Generate private identity/session keys on device; protect their wrapping key using Android Keystore / iOS Keychain. Choose and validate encrypted SQLite integration for local history; shared preferences remains demo-only.
3. Publish authenticated public bundles: identity key, signed prekey, signature, and one-time prekeys. Implement atomic single-consumer prekey claiming and replenishment.
4. Establish sessions, ratchet messages, handle out-of-order delivery, bound skipped keys, and persist ratchet state transactionally with the outbox.
5. Safety-number/QR verification and identity-change warnings. Session reset does not silently preserve trust.

Acceptance: two real devices exchange SDK-validated ciphertext; corrupted payloads fail; a DB export contains no plaintext message bodies or private keys; crash/replay/out-of-order tests pass; key change and lost-device behavior are documented. Forward secrecy and recovery claims must match the actual protocol and conditions.

## Phase 4 — Reliable realtime text messaging

**Status: planned.**

1. Add participant-authorized conversation records and per-device ciphertext envelopes with unique client message IDs.
2. Rate-limited authenticated enqueue RPC, bounded payload length, recipient/block checks, and hard queue quotas.
3. Private Realtime wake-up events plus cursor-based durable catch-up; websocket events alone are not the message store.
4. Transactional decrypt-and-store, deduplication, durable acknowledgment, retries with backoff, delivery/read receipts.
5. Delete acknowledged device envelopes; expire undelivered envelopes after seven days and show expiry accurately. Retain bounded dedupe tombstones for the retry window.
6. Presence and typing scoped to accepted contacts, opt-out, TTL expiry, and throttling.

Acceptance: two accounts exchange encrypted messages across reconnects and app restarts; offline recipients catch up; retries create one visible message; blocked/nonparticipants cannot enqueue/read; simulated quota exhaustion refuses new sends clearly.

## Phase 5 — Encrypted attachments and notifications

**Status: planned.**

1. Private R2 bucket, authenticated short-lived upload/download authorization, 10 MB attachment limit, per-user byte/operation reservations.
2. Client-side authenticated file encryption with independent random keys/nonces. Send key, integrity data, object reference, and metadata inside the Signal-encrypted message.
3. Verify actual uploaded size, finalize reservations, expire abandoned uploads, garbage collect after retention, and validate decryption before display.
4. FCM token lifecycle and APNs setup; server sends a generic new-message notification with no plaintext or decryption keys.
5. Foreground/background catch-up and notification navigation; test OS restrictions instead of assuming silent wake-up.

Acceptance: R2 admin sees encrypted objects only; unauthorized URLs fail; uploads cannot bypass budgets; background notification and resumed sync work on physical Android/iOS devices. Force-quit cases have documented behavior.

## Phase 6 — Voice and video

**Status: planned.**

1. Verify the currently available LiveKit free plan and quotas before activation; use a server-side token endpoint with participant checks.
2. Call invitation/accept/reject/timeout, mic/camera permissions, mute, camera switch, audio routing, and teardown.
3. Enable supported media E2EE and exchange call keys over verified Signal sessions. An SFU relays media; ordinary WebRTC transport encryption alone is not SFU-resistant E2EE.
4. Measure TURN/SFU bandwidth and participant minutes; enforce pilot call admission and maximum duration server-side.

Acceptance: physical-device calls across different NATs, denial paths, interruption/reconnect behavior, inaccessible media keys at the provider, and quota cutoff. Calling stays disabled if free allowance is unavailable.

## Phase 7 — Pilot release and operations

**Status: planned.**

Run RLS isolation tests, protocol interoperability checks, lifecycle tests, accessibility review, slow-network tests, and a realistic 20-user load simulation. Add operational dashboards, error reporting without message content, cleanup schedules, backup/recovery of nonsecret server data, and retention controls. Release signed Android builds first; iOS distribution requires Apple enrollment and macOS builds.

Pilot acceptance: measured usage remains below internal budgets, quota refusal is tested, documented recovery works, and no demo code is reachable from production chat storage. Expand user limits only after measuring actual traffic.

## Immediate next milestone

Apply both migrations to the configured Supabase project and validate profiles/invitations with two confirmed accounts. Complete the remaining account lifecycle work, then the Signal native-binding spike before adding a server message queue.
