# Google setup: OAuth sign-in and push notifications (FCM)

Supabase Auth is the sign-in system. Google Cloud provides the Google
identity (OAuth) and, through Firebase, the push-messaging service (FCM).
Both parts need a few values from consoles only you can open.

## Part A — Google sign-in (OAuth)

Do these once in the [Google Cloud Console](https://console.cloud.google.com/):

1. Create (or open) a project, for example `OpenChat`.
2. **APIs & Services → OAuth consent screen**:
   - User type: **External**.
   - App name `Open Chat`, your email as developer contact.
   - Add yourself as a **test user** (required while the app is in testing mode).
   - Scopes: the defaults (`email`, `profile`, `openid`) are enough.
3. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Web application**.
   - Name: `OpenChat Supabase`.
   - Under **Authorized redirect URIs**, add exactly:
     `https://piufbcpxulyvdjpcqfjm.supabase.co/auth/v1/callback`
   - Create, then copy the **Client ID** and **Client secret**.
4. Hand them to this project **without pasting them into chat**:
   add two lines to `C:\Users\HP\ConW\.env.local` (already excluded from Git):
   ```env
   GOOGLE_CLIENT_ID=paste_client_id_here
   GOOGLE_CLIENT_SECRET=paste_client_secret_here
   ```
   Then say **“google saved”**. The secrets are applied to Supabase
   through the admin API and never committed to the repo.
   (Alternative: open Supabase → Authentication → Sign In / Providers →
   Google → enable it and paste the ID and secret there yourself.)
5. Rebuild/reinstall the app, then tap **Continue with Google**.
   The browser opens Google, and the app signs in on return.

Current status: the app button and the `dev.openchat.openchat://auth-callback`
redirect are implemented and the redirect is allow-listed, but the Google
provider is still switched off server-side, so the button explains that
until step 4 is done.

## Part B — Push notifications (FCM, later milestone)

Needed before background message notifications can be built:

1. Open [Firebase Console](https://console.firebase.google.com/).
2. **Add project** and select your existing Google Cloud project
   (`OpenChat`) so OAuth and FCM share it.
3. **Add an Android app**: package name `dev.openchat.open_chat`,
   nickname `Open Chat`.
4. Download **`google-services.json`** and place it at:
   `C:\Users\HP\ConW\android\app\google-services.json`
   (that filename is ignored by Git; never commit it).
5. Say **“google-services saved”**. The FCM wiring
   (`firebase_messaging`, token registration, notification handling)
   is then implemented and the app rebuilt.

iOS push additionally needs an Apple Developer membership and an APNs key;
that is a separate paid step and is out of scope for the Android pilot.

## Status: Firebase connected

`android/app/google-services.json` is installed (gitignored) for
`dev.openchat.open_chat`. The app registers its FCM token to the
`push_tokens` table on sign-in (one device per user). Generic server-sent
message alerts will use these tokens once messaging lands. No further
console action is needed for the pilot.

## What stays in Supabase

- Email/password accounts with instant confirmation for the pilot
  (`mailer_autoconfirm=true`, reversible). Production should switch to a
  real SMTP sender plus required confirmation.
- Profiles, usernames, invitations, blocks, and (next) prekey/message
  storage — unchanged by this setup.
