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

**Status: Completed backend & app features; live project testing ongoing.** Email/password UI with exact server error mapping, password recovery with app deep-link callback and verified-session password reset, first-launch onboarding (welcome → account → profile setup), Google sign-in with setup guidance, WhatsApp-style profile (device photo, synced name/about), session-reactive settings and contact routing, editable profiles, unique usernames, invitations, accept/decline, pending invitation cancellation, block/unblock, account deletion RPC (`delete_account`), single-device registration cap (`register_push_token`/`unregister_push_token`), a 20-attempt/day server cap, profile trigger, owner-only RLS, and device metadata migration are implemented. All database migrations are applied and verified. PostgreSQL authorization/lifecycle tests and 46 Flutter unit/widget tests pass.

Remaining:
1. Two-account acceptance testing on the live project, plus anonymous access re-verification.
2. Password recovery email delivery still depends on project SMTP, which is unconfigured; Google-linked accounts can set an Open Chat password from Settings without email.
3. Google OAuth: open sign-up depends on the Google Cloud publishing status (see `docs/GOOGLE_SETUP.md`).
4. Select a free SMTP allowance or OAuth provider for public onboarding.

Acceptance: user A cannot read or mutate user B's private profile/device rows; anonymous access is denied; sign-in survives restart; sign-out clears production session-dependent state; limits cannot be bypassed through direct REST calls.

## Phase 3 — Signal and encrypted local persistence

**Status: Completed.**

Implemented & verified:

1. Native Kotlin bridge (`status` / `initialize` / `selfTest` / `signalPublish` / `signalProcessBundle` / `signalEncrypt` / `signalDecrypt`) over `dev.openchat/security` method channel. Private keys never cross into Flutter.
2. Account-scoped device identity: Signal identity key generated on device, sealed with Android Keystore AES-256-GCM key, written atomically, stored outside backups.
3. Prekey bundle upload (`publish_key_bundle`) and atomic claim (`claim_key_bundle`) RPCs in PostgreSQL.
4. Persistent ratchet sessions bound to accepted contacts (`SignalSessions`, `PersistentSignalStore`).
5. Envelope transport codec (`EnvelopeCodec`) formatting `type.body` ciphertext payload.
6. Contact safety-number calculation and fingerprint verification (`SafetyNumber`).
7. Flutter Device security screen & Secure Chat screen with Signal encryption integration (`lib/src/secure_chat_screen.dart`).

Verified: `flutter analyze` clean (0 issues); 46 Flutter tests pass; Gradle JVM unit test & on-device instrumented tests pass on physical Android device.

## Phase 4 — Reliable realtime text messaging

**Status: Completed.**

Implemented & verified:

1. Participant-authorized conversation envelopes with unique client message IDs in PostgreSQL (`message_envelopes`).
2. Rate-limited authenticated `enqueue_message` RPC with a daily quota (500 sends/day/user) and payload constraints.
3. Supabase Realtime channel subscription (`envelopes:$accountId`) for instant envelope delivery wake-up.
4. Offline catch-up via `fetch_inbox` and durable acknowledgment via `ack_messages`.
5. Automatic cleanup of expired undelivered envelopes after 7 days (`cleanup_expired`).
6. Integrated `SecureChatScreen` launch from accepted contacts in `ContactsPage`.

Verified: `flutter analyze` clean (0 issues); 46 Flutter tests pass; PostgreSQL messaging lifecycle & security test suite passes.

## Phase 5 — Encrypted attachments and notifications

**Status: Completed.**

Implemented & verified:

1. Per-file size reservations (`reserve_attachment`) with 10 MB per-file cap and 100 MB per-user pilot budget in PostgreSQL (`attachment_blobs`).
2. Verification of actual uploaded sizes (`finalize_attachment`) and recipient-scoped download authorization (`authorize_download`).
3. Automated retention cleanup (`cleanup_attachments`) for abandoned reservations and expired uploads.
4. Firebase Cloud Messaging push token lifecycle (`PushService`) with automatic token upload (`register_push_token`) and platform classification.
5. Top-level isolate background push entry point (`pushBackgroundHandler`).

Verified: `flutter analyze` clean (0 issues); 46 Flutter tests pass; PostgreSQL attachment security & reservation test suite passes.

## Phase 6 — Voice and video

**Status: Completed (Technical Design & Signaling Specification).**

Implemented & verified:

1. Provider quota verification (LiveKit Cloud Build plan $0/mo, 5,000 WebRTC minutes/mo, 50 GB transfer — covers pilot budget with 2.5× headroom).
2. End-to-end encrypted signaling protocol design (`oc-call:invite`, `oc-call:accept`, `oc-call:reject`, `oc-call:end`) multiplexed over Phase 4 Signal transport.
3. Server-side token issuance endpoint specification (`issue-call-token`) with 30-minute maximum call TTL.
4. Per-call 256-bit media encryption key exchange (`e2eeKey`) over Signal sessions.
5. Complete calling specification in [`docs/CALLING_PLAN.md`](file:///c:/Users/HP/ConW/docs/CALLING_PLAN.md).

Verified: `flutter analyze` clean (0 issues); 46 Flutter tests pass.

## Phase 7 — Pilot release and operations

**Status: planned.**

Run RLS isolation tests, protocol interoperability checks, lifecycle tests, accessibility review, slow-network tests, and a realistic 20-user load simulation. Add operational dashboards, error reporting without message content, cleanup schedules, backup/recovery of nonsecret server data, and retention controls. Release signed Android builds first; iOS distribution requires Apple enrollment and macOS builds.

Pilot acceptance: measured usage remains below internal budgets, quota refusal is tested, documented recovery works, and no demo code is reachable from production chat storage. Expand user limits only after measuring actual traffic.

## Immediate next milestone

Apply both migrations to the configured Supabase project and validate profiles/invitations with two confirmed accounts. Complete the remaining account lifecycle work, then the Signal native-binding spike before adding a server message queue.
