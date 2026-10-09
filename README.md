# Open Chat

Flutter + Dart messaging application, developed in phases against a free-tier backend budget.

## Current implementation

**Phase 1 and phase 2 are implemented; phase 3 (Android encryption foundation) is in progress.**

- First-launch onboarding: welcome screen, account sign-in/creation, and profile setup (name, about, optional photo).
- WhatsApp-style profile screen: photo, name, about line, and account info. The photo stays on the device; name/about sync to the cloud account when signed in.
- Password recovery over email with an app deep-link callback (`dev.openchat.openchat://auth-callback`).
- Responsive mobile chat screens and desktop/tablet split view.
- Conversation search, unread filter, new demo conversations, send text, local persistence, reset.
- Optional Supabase email/password registration, sign-in, sign-out, and session restoration.
- Owner-only profile/device SQL foundation with row-level security (RLS).
- Live People & profile screen: save a unique username, send invitations, accept/decline, block/unblock, and refresh contacts. Contact about lines are visible to connected contacts only.
- Server-enforced 20 invitation attempts per UTC day; exact-username discovery without a public user directory.
- Android device security screen: Keystore-wrapped Signal identity, public-key fingerprint, and on-device encryption checks (libsignal 0.105.0, AGPLv3). iOS/web bindings are pending.
- Android, iOS, and web project scaffolds.

The chat workspace is a **local demo**, even when signed in. It does not send messages to another person. Demo data is plaintext in shared preferences. Network messaging, encrypted local storage, prekey exchange, attachments, push, and calls are pending. Do not use demo storage for private communications.

## Run immediately

Requires Flutter 3.47.5 / Dart 3.13 or compatible newer SDK.

```powershell
flutter pub get
flutter run -d chrome
```

For Android, start an emulator or connect a USB-debugging device, run `flutter devices`, then `flutter run -d DEVICE_ID`. iOS builds require macOS and Xcode.

## Connect a free Supabase project

1. Create a **Free** Supabase project. Save the database password privately.
2. In SQL Editor, execute these files **in order, once each**:
   - `supabase/migrations/202610090001_foundation.sql`
   - `supabase/migrations/202610090002_contacts.sql`
   - `supabase/migrations/202610090003_profile_about.sql`
   The first migration creates profiles for both new and existing Auth users. The second adds usernames and the contact RPCs; the third adds about lines. Do not execute `supabase/tests/local_auth_stub.sql` on your hosted project; it is a local test fixture.
3. Enable email/password Auth. For a private development project, create confirmed test users in the dashboard. Supabase's built-in mail sender has delivery restrictions and rate limits; public registration requires a configured SMTP provider with an appropriate free allowance. Do not assume unrestricted free email delivery.
4. Create `config.json` based on `config.example.json`. Set the project URL and **publishable/anon** client key. This file is ignored by Git. Never put a service-role key, database password, SMTP secret, or R2 credential in Flutter defines: client configuration is extractable.
5. Set the Auth Site URL to your development web origin, for example `http://localhost:7357`. Confirmation is completed in the browser; return to the app and sign in with the confirmed account. Native automatic deep-link sign-in and password recovery are phase 2 follow-ups.
6. Run:

```powershell
flutter run -d chrome --web-port 7357 --dart-define-from-file=config.json
```

Open the settings icon to register or sign in, then **People & profile**. Save your display name and username. Sign in with a second account on another device/browser, save its username, and invite it from the first account. Refresh on the recipient, accept, then refresh on the sender. Contact data comes from Supabase; the main chat list remains the local demo. Contacts refresh manually or when the app resumes, not over Realtime yet. Device registration and account deletion remain follow-ups.

Password recovery uses Supabase's email sender. On a private project, test it with a real address; public use needs a configured SMTP provider. The reset link must be opened on the same device so the app can receive the callback and let you set the new password.

Declined invitations cannot be resent for the same account pair in this pilot. Blocking removes the connection; unblocking requires a new invitation and does not restore it automatically.

## Checks and builds

```powershell
flutter analyze
flutter test
flutter build web
flutter build apk --debug
```

Web output is in `build/web`; it can later be deployed to a free static-hosting tier. Android release signing, app-store distribution, and production hosting are not configured. App-store developer fees are separate from cloud costs.

## Project map

```text
lib/main.dart                 Bootstrap, theme, optional Supabase connection
lib/src/chat_store.dart       Local demo models and persistence
lib/src/home.dart             Responsive chat UI and composer
lib/src/settings.dart         Cloud account and local demo settings
lib/src/onboarding.dart       First-launch landing, account, and profile setup
lib/src/profile_page.dart     WhatsApp-style profile (photo, name, about)
lib/src/recovery_page.dart    Password recovery over email deep link
lib/src/local_profile.dart    Device-local name/about/photo store
lib/src/contacts_page.dart    Live profile, invitations, and contacts UI
lib/src/contacts_repository.dart  Typed Supabase RPC adapter
supabase/migrations/          Database foundation and RLS
docs/DEVELOPMENT_PLAN.md      Phases, deliverables, acceptance criteria
docs/ARCHITECTURE.md          Data flows and security boundaries
docs/FREE_TIER_BUDGET.md      Verified allowances and planned limits
test/widget_test.dart        User-flow and persistence checks
test/contacts_page_test.dart Contact UI success/failure checks
supabase/tests/              PostgreSQL authorization and lifecycle tests
```

See [the phase plan](docs/DEVELOPMENT_PLAN.md) for the build sequence. Cloud services have not been provisioned or deployed by this repository.

## Database verification without cloud credentials

The migrations and authorization tests can run against disposable PostgreSQL with Docker. The auth stub simulates Supabase subjects and roles; it does not test hosted Auth or PostgREST itself.

```powershell
docker run --name openchat-phase2-db --detach --rm -e POSTGRES_PASSWORD=openchat-local-test-only postgres:17-alpine
# Wait until this reports accepting connections:
docker exec openchat-phase2-db pg_isready -U postgres
docker cp supabase openchat-phase2-db:/tmp/openchat-supabase
docker exec openchat-phase2-db psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/openchat-supabase/tests/local_auth_stub.sql -f /tmp/openchat-supabase/migrations/202610090001_foundation.sql -f /tmp/openchat-supabase/migrations/202610090002_contacts.sql -f /tmp/openchat-supabase/tests/contacts_security.sql
docker stop openchat-phase2-db
```
