# OpenChat — Android Team Messaging with Signal E2EE

Flutter + Signal Protocol + Supabase + LiveKit. 1:1 chats and newly created group text chats are end-to-end encrypted. Legacy groups are server-readable and labeled as such in-app.

> Pilot status: works for team testing, **not** production-certified. Real-device call/group-E2EE verification, load tests, and recovery drills are still pending.

## Features

- **Chats**: 1:1 Signal E2EE messaging (text, replies, polls, media, voice, documents, view-once), delivery ticks (sent/delivered/read), offline catch-up.
- **Groups**: new groups use Signal Sender Keys for text/replies with epoch rotation on membership/identity change. Media, polls, tasks, and edits are disabled in encrypted groups rather than sent in plaintext.
- **Contacts**: WhatsApp-style list with search (name, @username, about), phone-book sync, invitations, block/unblock.
- **Status**: 24-hour text/media stories with audience controls.
- **Calls**: 1:1 voice/video over LiveKit with per-call keys exchanged via Signal. Group calls are not supported (the UI says so instead of failing silently).
- **Backup**: password-encrypted snapshots (Argon2id + AES-256-GCM) in Supabase Storage (`chat-backups`), covering 1:1 history, group history, and referenced media. Three generations retained; restore needs only the password.

## Sign-in (current)

- **Phone OTP is temporarily hidden**: Firebase requires Blaze billing for real SMS (`BILLING_NOT_ENABLED`). Flip `kPhoneAuthEnabled` in `lib/src/auth/phone_auth.dart` after upgrading.
- Use **Google Sign-In or email**, or Firebase **test numbers** for dev.

## Security model

- Identity keys in Android Keystore (AES-256-GCM); private keys never leave the device.
- 1:1 via Signal Double Ratchet + prekey bundles (`libsignal 0.105.0`, `dev.openchat/security` bridge).
- Group text via Signal Sender Keys; server stores ciphertext + pairwise-encrypted key envelopes only.
- Local history in transactional SQLite as AES-256-GCM ciphertext; key in platform secure storage.
- Supabase RLS isolates all user data; call/group writes go through membership-checked RPCs.
- Safety-number fingerprints for MITM detection.

## Setup

```powershell
flutter pub get
flutter run --dart-define-from-file=config.json   # SUPABASE_URL + SUPABASE_ANON_KEY; optional GIPHY_API_KEY for GIF search
```

Apply `supabase/migrations/` **in order**, then run `supabase/verify_migrations.sql` (plus `supabase/tests/durability_security.sql` for the retention/E2EE assertions).

## Verify

```powershell
flutter analyze
flutter test
cd android; .\gradlew.bat :app:testDebugUnitTest
flutter build apk --release --dart-define-from-file=config.json
```

Shareable pilot APK: `build/app/outputs/flutter-apk/app-release.apk`.

## License

Incorporates `libsignal-client` / `libsignal-android` (AGPLv3).
