# Android test build — 22 October 2026

## Installed and launched

| Target | Build | Result |
| --- | --- | --- |
| Samsung SM-M307F, Android 11 (USB) | Release, signed with the project's existing release key | Update installed successfully; Android reports OpenChat's activity resumed and visible |
| Pixel emulator, Android 16 (`emulator-5554`) | Debug, x86-64 | Installed successfully; cold launch succeeded and the chat home screen rendered |

Both builds use the same source and `--dart-define-from-file=config.json`.
The phone required release signing because its existing installation rejects the
debug signing key. It was updated in place without uninstalling or clearing data.

APK outputs:

- `build/app/outputs/flutter-apk/app-debug.apk`
- `build/app/outputs/flutter-apk/app-release.apk`

## Fixes in this deployment pass

- Restored the disabled Android `OpenChatConnectionService.kt` source and fixed
  its invalid imports, Telecom API calls, callback signatures, and Kotlin syntax.
  Successful compilation does not establish complete native incoming-call support.
- Corrected the phone-call foreground-service permission name.
- Corrected Status, Calls, and Settings shortcuts after the Broadcasts tab shifted
  their indices; enabled tab switching in the wide layout.
- Fixed the extra SQLite initialization helper's compile errors and dependency
  placement. Android uses native SQLite; web startup has not been verified.
- Included the configured backend in both Android builds.

## Verification

- Android debug and release APK builds succeeded.
- `flutter test test/widget_test.dart test/call_room_test.dart`: **8 passed**.
  Widget tests log an unavailable notification-plugin initialization, which is
  caught by the application; these tests do not verify device notifications.
- `flutter analyze`: **0 errors, 5 warnings, 11 informational lint findings**.
- No Flutter-error or AndroidRuntime-error entries were returned by the checked
  app-process startup logs on either device.
- Cross-device delivery, calls, and background notifications still need manual
  testing; a successful launch does not verify those paths.

## Existing features to test

These implementations predate the latest transcript/group-voice/broadcast work:

- Encrypted direct messaging, formatting, receipts, quoted replies, reactions,
  editing/deletion, and chat organization.
- Direct-chat photos/videos, voice notes, documents, polls, contact cards, static
  location, and view-once media.
- Encrypted group text/replies and group membership/admin tools.
- One-to-one voice/video calling, status updates, and notification handling.

## Incomplete features — correction to earlier completion claims

The following were previously marked complete prematurely:

- **Voice-note transcription:** a model field and service scaffold exist, but
  file transcription returns `null` and the voice-note UI is not connected to a
  working recognizer.
- **Group voice chats:** a button/banner and service scaffold exist, but room
  authorization/signaling, key handling, media ownership, and participant updates
  are incomplete. This is not a working group-call implementation.
- **Broadcasts:** list screens/storage exist, but recipient loading returns an
  empty list and sending does not invoke the encrypted message transport. A
  “Broadcast sent” snackbar in this scaffold is not evidence of delivery.
- **Encrypted-group media, polls, tasks, and edits:** remain explicitly disabled.
- **Live location:** the current timer sends separate location messages while the
  chat is active; durable background tracking is not implemented.
- **Native system call UI/background calling:** still requires end-to-end wiring
  and device verification.

## Two-device testing

1. Use different OpenChat accounts on the phone and emulator.
2. Add the other account by username and accept the contact request.
3. Open the encrypted contact conversation and send messages in both directions.
4. Check receipts, replies, reactions, media, and group text.
5. Test one-to-one voice/video calls, then background message notifications.

Use the encrypted contact conversation for cross-device tests. “Message yourself”
and local demo conversations do not send to the other device.
