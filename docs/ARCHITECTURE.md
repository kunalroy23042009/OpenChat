# Architecture and boundaries

## Implemented now

```text
Flutter chat UI → ChatStore → shared preferences (fictional demo data only)
Flutter account UI → Supabase Auth (optional configured project)
Supabase Auth trigger → owner-private profile
Flutter People & profile → authenticated profile/contact RPCs → PostgreSQL
```

Cloud authentication and the local demo are independent. A signed-in user does not upload demo history. Auth tokens use the SDK's default persistence in this prototype; native secure token persistence is part of production hardening.

Implemented contact RPCs: `save_profile`, `send_contact_invite`, `respond_contact_invite`, `block_contact`, `unblock_contact`, and `list_my_contacts`. Security-definer functions pin the search path, require an authenticated subject, and expose only related contact names/usernames. Clients cannot directly write contact tables. A unique unordered account pair prevents duplicate/crossed requests, pair-scoped transaction locks serialize invite/response/block operations, and an atomic per-account counter includes failed discovery attempts. Own profiles remain RLS-private; contact names are returned through the scoped RPC. Signing out or changing identity discards the account-scoped contacts widget.

## Target secure system

```text
Flutter UI
 ├─ encrypted local database / durable outbox
 ├─ Signal native bridge → platform-protected private key storage
 ├─ authenticated Supabase RPC → public prekey bundles / ciphertext queue
 │                            └─ private Realtime hints
 ├─ client-encrypted file → short-lived signed upload → private R2
 └─ encrypted call media → LiveKit SFU

Backend event → FCM / APNs → generic wake-up notification → cursor sync
```

### Signal library decision (Phase 3, Android)

Native libsignal 0.105.0 (`org.signal:libsignal-android` + `libsignal-client`, Signal's Maven repository), used directly through a Kotlin bridge covering `status`, `initialize`, and `selfTest`. Signal marks third-party use as unsupported and licenses the library under **AGPLv3** — this project's releases carry that obligation. Version is pinned in `android/app/build.gradle.kts`; do not float it without re-running the protocol checks.

`IdentityVault` (Kotlin): per-account identity, Keystore-wrapped AES-256-GCM envelope with account-bound AAD, atomic file writes, `noBackupFilesDir` storage, `allowBackup=false`. Only a fingerprint and status flags leave the native layer.

`SignalDiagnostics` (Kotlin): ephemeral in-memory stores only; never touches user key material or messages. Asserts round-trip decryption in both directions, one-time prekey consumption, out-of-order delivery, duplicate-message rejection, ciphertext tamper rejection, and rejection of sessions built from an unexpected identity.

### Trust model

Message content and attachment/call keys stay client-side. Servers necessarily see some routing metadata, account identifiers, timestamps, IP addresses, and public keys. E2EE does not hide all metadata or protect an already-compromised unlocked endpoint. Authenticating the server alone does not stop malicious public-key substitution; identity verification and key-change handling are required.

### Durable transport contract (planned)

Envelope: `id`, `client_message_id`, `sender_device_id`, `recipient_device_id`, `conversation_id`, `ciphertext`, `protocol_version`, `created_at`, `expires_at`. Enforce sender ownership, recipient membership, payload size, expiry, block lists, and uniqueness server-side. No raw plaintext columns.

Realtime signals mean “sync needed.” Fetch paginated envelopes, decrypt locally, commit message and ratchet state, then acknowledge. Never acknowledge before durable local storage. Store read receipts and media pointers inside encrypted content where feasible. Presence remains ephemeral with short TTLs.

### APIs to implement by phase

| Phase | Operations |
| --- | --- |
| 2 | register/revoke device, edit profile, resolve invite, accept/block contact |
| 3 | upload signed public bundle, atomically claim prekey, replenish keys |
| 4 | enqueue ciphertext, fetch device inbox, acknowledge, expiry cleanup |
| 5 | reserve media bytes, authorize upload/download, finalize/delete object, push-token registration |
| 6 | authorize call, issue scoped token, reserve call budget, end call |

Privileged provider secrets live only in server-side secret stores. All privileged endpoints verify the user token and authorization; a valid login alone does not grant access to another user's resources. SQL grants and RLS are both required. The initial migration exposes only self-profile reads/name updates and self-device reads/deletes; device creation is deliberately reserved for a capped registration RPC.

### Platform scope

Android/iOS are the target secure clients. Web currently exercises the UI and optional Auth. Secure browser key storage, protocol binding support, browser notification behavior, and linking a web device need their own reviewed implementation. Cross-platform Flutter rendering does not automatically provide cross-platform cryptography.
