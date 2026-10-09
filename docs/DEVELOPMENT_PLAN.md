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

**Status: in progress.** Email/password UI, password recovery with app deep-link callback, first-launch onboarding (welcome → account → profile setup), WhatsApp-style profile (device photo, synced name/about), session-reactive settings and contact routing, editable profiles, unique usernames, invitations, accept/decline, block/unblock, a 20-attempt/day server cap, profile trigger, owner-only RLS, and device metadata migration are implemented. All three migrations are applied to the live project and verified. PostgreSQL authorization/lifecycle tests and 18 Flutter tests pass.

Remaining:
1. Two-account acceptance testing on the live project, plus anonymous access re-verification.
2. Live verification of the recovery email round trip (needs a real mailbox; production needs SMTP).
3. Select a free SMTP allowance or OAuth provider for public onboarding; keep confirmed dashboard test accounts for private development.
4. Add pending invitation cancellation and reviewed re-invitation rules. Contact refresh is manual/on-resume for now.
5. Implement device registration RPC capped at one active device; account/device revocation; account deletion.

Acceptance: user A cannot read or mutate user B's private profile/device rows; anonymous access is denied; sign-in survives restart; sign-out clears production session-dependent state; limits cannot be bypassed through direct REST calls.

## Phase 3 — Signal and encrypted local persistence

**Status: in progress (Android foundation implemented and device-verified).**

Implemented on Android (libsignal 0.105.0, pinned; AGPLv3 — see `docs/ARCHITECTURE.md`):

1. Native Kotlin bridge (`status` / `initialize` / `selfTest`) over a `dev.openchat/security` method channel. Private keys never cross into Flutter.
2. Account-scoped device identity: Signal identity key generated on device, sealed with an Android Keystore AES-256-GCM key, written atomically, stored outside backups. Tampered state fails closed and is never silently replaced. Fingerprint (SHA-256 of public identity) is displayable.
3. On-device diagnostics (ephemeral test identities, not user data): two-way encrypt/decrypt round trip, one-time prekey consumption, out-of-order delivery, replay rejection, tamper rejection, unexpected-identity-change rejection.
4. Flutter Device security screen: identity creation, fingerprint display, on-demand encryption checks.

Verified: `flutter analyze` clean; all 10 Flutter tests pass; Gradle JVM unit test passes; both on-device instrumented tests pass on a physical Samsung M30s (Android 11) — including Keystore persistence and tamper-fails-closed behavior.

Still pending before network messaging:

1. Prekey bundle upload/claim/replenishment RPCs (server-side, atomic single-consumer claims).
2. Persistent ratchet sessions bound to accepted contacts; crash/out-of-order/replay coverage against real stored state.
3. Encrypted local message database replacing demo shared-preferences storage.
4. Safety-number/QR contact verification and identity-change warnings in the UI.
5. iOS and web native bindings (currently Android-only).

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
