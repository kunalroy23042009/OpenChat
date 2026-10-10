# OpenChat — E2EE WhatsApp Clone for Flutter & Supabase

**OpenChat** is a cross-platform, end-to-end encrypted messaging application built with Flutter, Signal Protocol, Supabase, and WebRTC. It mirrors WhatsApp's signature features—including SMS phone authentication, status stories, encrypted voice/video calling, and real-time messaging—all optimized to run on a **$0 free-tier cloud budget**.

---

## 🌟 Key Features

### 📱 WhatsApp-Style Experience & Navigation
- **4-Tab Native Navigation**: Seamlessly switch between **Chats** 💬, **Status** ⭕, **Calls** 📞, and **Settings** ⚙️.
- **SMS Phone Authentication**: Sign in using your international phone number (`+1`, `+91`, `+44`, etc.) via SMS OTP verification.
- **Phone Contact Discovery**: Invite and connect with contacts directly using their E.164 phone numbers or custom `@username`.
- **Status & Stories**: Share 24-hour expiring text or media status updates; view contact stories with a full-screen story viewer.
- **E2EE Voice & Video Calling**: Live WebRTC calling screen featuring mute controls, camera toggle, speaker output, live duration timer, and Signal E2EE security badges.
- **Message Delivery Ticks**: Real-time delivery state indicators:
  - 🕓 **Clock**: Pending / queued locally
  - ✓ **Single Gray Tick**: Sent to server
  - ✓✓ **Double Gray Tick**: Delivered to recipient
  - ✓✓ **Double Blue Tick**: Read by recipient
- **Rich Media Previews**: Photo lightbox with double-tap zoom, interactive audio note player, video player cards, and document attachments.

---

## 🔐 Security & Cryptography Architecture

- **Android Keystore Sealed Keys**: Device Signal identity keys are generated on-device and sealed using Android Keystore AES-256-GCM encryption. Private keys **never leave your device**.
- **Double Ratchet & Prekey Bundles**: E2EE messaging powered by `libsignal-android` (v0.105.0) via Kotlin native bridge (`dev.openchat/security`).
- **Safety Number Verification**: Computes SHA-512 identity fingerprints to verify recipient safety numbers and detect man-in-the-middle attacks.
- **Row-Level Security (RLS)**: Supabase PostgreSQL policies strictly isolate user data; users cannot read or mutate unauthenticated rows.

---

## 🚀 Development Phases & Status

| Phase | Scope | Status | Highlights |
|---|---|---|---|
| **1** | Flutter UI & Local Chat Demo | ✅ **Completed** | Adaptive layout, local persistence store, conversation search, unread filters. |
| **2** | Accounts, Profiles, & **Phone Auth** | ✅ **Completed** | Supabase Auth, WhatsApp SMS OTP, E.164 lookup, profile sync, 20-attempt daily rate limit, block/unblock. |
| **3** | Signal Encryption & Storage | ✅ **Completed** | Android Keystore Kotlin Signal bridge, prekey bundle publish/claim RPCs, persistent ratchet sessions, Safety Number verification. |
| **4** | Real Messaging Between Devices | ✅ **Completed** | Realtime message envelopes (`message_envelopes`), 500 send/day quota, offline catch-up (`fetch_inbox`, `ack_messages`), `SecureChatScreen`. |
| **5** | Encrypted Attachments & Push | ✅ **Completed** | Attachment blob reservation (`reserve_attachment`, 10MB per file), FCM push token sync, background isolate push handler. |
| **6** | E2EE Voice & Video Calling | ✅ **Completed** | LiveKit cloud signaling design, 256-bit media key exchange, interactive `CallScreen` UI widget. |
| **7** | Production Build & Operations | ✅ **Completed** | ProGuard rules (`proguard-rules.pro`), optional release keystore fallback (`build.gradle.kts`), 8-migration verification suite (`verify_migrations.sql`). |

---

## 🛠️ Getting Started

### 1. Run Immediately (Offline Local Demo Mode)

Requires Flutter 3.47.5+ / Dart 3.13+. Launch the app in demo mode without any cloud credentials:

```powershell
flutter pub get
flutter run -d chrome
# OR for Android Emulator / Physical Device:
flutter run -d <DEVICE_ID>
```

### 2. Connect Your Free Supabase Backend

1. Create a **Free** project at [supabase.com](https://supabase.com).
2. Open **SQL Editor** in Supabase and execute the migration files in `supabase/migrations/` **in order**:
   - `202610090001_foundation.sql` (Profiles & base Auth triggers)
   - `202610090002_contacts.sql` (Usernames & contact invitations)
   - `202610090003_profile_about.sql` (Profile about lines)
   - `202610090004_push_tokens.sql` (Device FCM token registration)
   - `202610090005_messaging.sql` (Realtime message envelopes & inbox catchup)
   - `202610090006_kyber_signatures.sql` (Signal prekey bundle exchange)
   - `202610090007_attachments.sql` (Attachment blob reservations & caps)
   - `202610090008_phone_auth.sql` (Phone SMS authentication & lookup)
   *(Or run `supabase/verify_migrations.sql` to verify all 8 migrations at once)*

3. Create `config.json` in the project root:
   ```json
   {
     "SUPABASE_URL": "https://your-project.supabase.co",
     "SUPABASE_ANON_KEY": "your-publishable-anon-key"
   }
   ```

4. Launch with backend credentials:
   ```powershell
   flutter run -d chrome --web-port 7357 --dart-define-from-file=config.json
   ```

---

## 🧪 Testing & Code Quality

Run static analysis and full unit/widget test suite:

```powershell
# Run static analysis (0 errors guaranteed)
flutter analyze

# Run all 46 unit & widget tests
flutter test

# Build production Android APK
flutter build apk --release
```

---

## 📁 Repository Structure

```text
lib/main.dart                         App entry point, theme management, Supabase initialization
lib/src/home.dart                     WhatsApp 4-tab layout (Chats, Status, Calls, Settings)
lib/src/onboarding.dart               First-launch welcome, account, and profile setup
lib/src/auth/phone_auth.dart          SMS OTP authentication service
lib/src/auth/phone_auth_page.dart     WhatsApp phone sign-in UI with country code picker
lib/src/status/status_page.dart       WhatsApp Status / Stories feed and full-screen viewer
lib/src/calling/call_screen.dart     E2EE Voice and Video calling UI with controls & timers
lib/src/calling/call_history_page.dart Call log list and dialer
lib/src/widgets/media_preview.dart   Rich media player & preview cards
lib/src/widgets/status_ticks.dart    WhatsApp single/double/blue read delivery ticks
lib/src/theme/app_theme.dart          Dynamic Light, Dark, Emerald, and System theme controller
lib/src/secure_chat_screen.dart      Realtime Signal E2EE messaging screen
lib/src/security/device_security.dart Android Keystore Signal identity bridge
supabase/migrations/                 Database schema migrations (0001 - 0008)
supabase/verify_migrations.sql       Database verification suite
android/app/proguard-rules.pro        Production release obfuscation rules
docs/DEVELOPMENT_PLAN.md             Comprehensive 7-phase implementation plan
docs/CALLING_PLAN.md                 LiveKit WebRTC signaling specification
```

---

## 📄 License & Attribution

This project incorporates `libsignal-client` and `libsignal-android` (AGPLv3) for Signal E2EE cryptographic operations.
