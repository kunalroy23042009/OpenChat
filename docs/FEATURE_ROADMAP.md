# OpenChat — 200-feature roadmap vs. WhatsApp spec

Tracker for the 200-item list. Status values: **Done** (implemented +
tested), **Partial** (in code but incomplete or unverified on devices),
**Queued** (not started). Pilot scope is Android-first, single-device,
1:1 E2EE chat; groups/status/calls beyond 1:1 are best-effort.

Shipped in the current batch: quoted replies (long-press + swipe-right),
copy, forward with secure re-upload, star/unstar + Starred dialog, 3-slot
message pins + banner, message-info sheet (sent/delivered/read times),
delete-for-me (metadata-only), delete-for-everyone (1-hour author window,
in-place tombstone), durable receipts migration
`202610090021_durable_receipts.sql` (ACK creates the delivery receipt;
reads are per-envelope and visible-only; receipts survive ACK).

Shipped next: emoji reactions with explicit set/remove state, in-place
editing (15-minute author window), in-chat search, inline formatting
(bold/italic/strikethrough/monospace/code), per-chat drafts (with home
preview + failed-send retention), manual mark-unread for encrypted chats,
a local-only Message-Yourself thread, and the WhatsApp-style notification
stack: runtime permission, message/status/call channels, foreground
realtime watchers (name-only nudges, no decryption outside the open chat),
full-screen call ringing, tap routing (chat/status/calls), background FCM
rendering, poke-on-send, and the `notify-send` Edge Function (data-only
payloads; FCM_SERVICE_ACCOUNT configured and verified).

**Device-verified on 2026-10-12:** two-device messaging (phone → emulator
message arrived), blue read ticks, 😂 reaction chip, full message action
sheet (Reply/React/Copy/Forward/Star/Pin/Info/Delete), FCM background
notification delivered and posted (`numPostedByApp=1`), notification
channels registered with correct importance.

## Basic messaging & text formatting (1–31)

| # | Feature | Status | Note |
|---|---------|--------|------|
| 1 | Text messaging | Done | 1:1 E2EE, realtime + polled inbox, 500/day quota |
| 2 | Bold | Done | `*bold*` renders in bubbles |
| 3 | Italic | Done | `_italic_` renders in bubbles |
| 4 | Strikethrough | Done | `~strike~` renders in bubbles |
| 5 | Monospace | Done | Triple-backtick blocks render monospace |
| 6 | Bulleted lists | Queued | — |
| 7 | Numbered lists | Queued | — |
| 8 | Block quotes | Partial | Reply quotes exist; no `>` syntax |
| 9 | Inline code | Done | Single-backtick spans render monospace |
| 10 | Edit sent messages | Done | 15-minute author window, in-place |
| 11 | Delete for everyone | Done | 1-hour author window, tombstone |
| 12 | Delete for me | Done | Body erased, dedupe retained |
| 13 | Star messages | Done | Per-chat Starred dialog |
| 14 | Message yourself | Done | Local-only personal notes thread |
| 15 | Message unsaved numbers | Partial | Phone lookup/invite; numbers self-asserted, no SMS verify |
| 16 | Reactions | Done | 1:1 emoji reactions, tap chip to toggle |
| 17 | Quoting | Done | Swipe-right + long-press reply |
| 18 | Forwarding | Done | One contact picker; media re-sealed for recipient |
| 19 | Forwarding limits | Partial | Single-target picker only; no viral flag |
| 20 | Search chats | Partial | Conversation-name search; no message-content search |
| 21 | Search inside a chat | Done | Filter + empty-state counts in encrypted chats |
| 22 | Search by date | Queued | — |
| 23 | Copy text | Done | — |
| 24 | Pin chats (3) | Done | Local pins + 3-slot message pins |
| 25 | Archive chats | Done | Local archive + filter |
| 26 | Keep chats archived | Queued | New-message behavior unverified |
| 27 | Mark as unread | Done | Manual flag on encrypted chats + home dot |
| 28 | Mark as read | Done | Local + auto-read on open chat |
| 29 | Draft indicators | Done | Per-chat drafts with home "Draft" prefix; failed sends keep text |
| 30 | Typing indicators | Partial | Local AI typing only |
| 31 | Online status | Queued | No presence system by design (pilot) |

## Voice & video calling (32–46)

| # | Feature | Status | Note |
|---|---------|--------|------|
| 32 | Voice calls | Partial | LiveKit wired, secrets set; no confirmed call yet |
| 33 | HD video calls | Partial | Same; camera/mic permissions wired |
| 34 | Group voice (32) | Queued | 1:1 rooms only |
| 35 | Group video (32) | Queued | — |
| 36 | Call links | Queued | Fake-link UI removed |
| 37 | Screen sharing | Queued | — |
| 38 | Landscape mode | Queued | — |
| 39 | Picture-in-picture | Queued | — |
| 40 | Mute participants | Partial | Self mute/controls only |
| 41 | Message a caller in-call | Queued | — |
| 42 | Call history | Done | `call_logs` + history page + redial |
| 43 | Add participants | Queued | — |
| 44 | Silence unknown callers | Queued | — |
| 45 | Low data mode | Queued | — |
| 46 | Join missed group calls | Queued | — |
| — | Call E2EE label | Partial | UI says encrypted; media path is SFU DTLS-SRTP, no per-call E2EE keys yet |

## Media sharing & camera (47–67)

| # | Feature | Status | Note |
|---|---------|--------|------|
| 47 | Photo sharing | Done | Sealed, 10 MB cap, tap-to-zoom |
| 48 | HD photos | Partial | Fixed 1600px/85%; no HD toggle |
| 49 | Video sharing | Done | Sealed, 64 MB cap, temp-file playback |
| 50 | HD video | Queued | — |
| 51 | View-once media | Queued | — |
| 52 | Block view-once screenshots | Queued | — |
| 53 | Documents (2 GB) | Queued | Images/video only |
| 54 | Send media as document | Queued | — |
| 55 | In-app cropping | Queued | — |
| 56 | Rotation | Queued | — |
| 57 | Text on images | Queued | — |
| 58 | Draw on media | Queued | — |
| 59 | Stickers on media | Queued | — |
| 60 | Blur tool | Queued | — |
| 61 | GIF search | Queued | — |
| 62 | Sticker maker | Queued | — |
| 63 | Animated stickers | Queued | — |
| 64 | Avatar stickers | Queued | — |
| 65 | Audio sharing | Queued | — |
| 66 | Location sharing | Queued | — |
| 67 | Contact (vCard) sharing | Queued | — |

## Voice notes & audio (68–76)

All Queued: push-to-talk, hands-free lock, preview, pause/resume, speed
modifiers, out-of-chat playback, waveforms, transcripts, voice status.

## Privacy & core security (77–95)

| # | Feature | Status | Note |
|---|---------|--------|------|
| 77 | E2EE | Done | 1:1 text/media/polls via Signal; calls excluded (see above) |
| 78 | Encrypted cloud backups | Queued | — |
| 79 | Hide last seen | Queued | No presence system |
| 80 | Hide online | Queued | — |
| 81 | Read-receipts toggle | Partial | Server honors `read_receipts`; no settings toggle yet |
| 82 | Profile-photo privacy | Queued | Column exists, unenforced |
| 83 | About privacy | Queued | — |
| 84 | Chat lock | Partial | PIN for local chats; no biometrics |
| 85 | Secret code | Queued | — |
| 86 | 2FA | Queued | — |
| 87 | Passkeys | Queued | — |
| 88 | Recovery email | Partial | Password recovery deep-link exists; SMTP unconfigured |
| 89 | Disappearing timer | Partial | Schema exists; no UI/enforcement |
| 90 | Default timer | Queued | — |
| 91 | Keep in chat | Queued | — |
| 92 | Block contacts | Done | Both-directions enforcement |
| 93 | Report chats/media | Queued | — |
| 94 | IP protection in calls | Queued | — |
| 95 | Flash calls / auto verify | Queued | Phone auth SMS path disabled |

## Groups (96–111)

Schema (`0014`–`0016`) and basic group UI landed in parallel work but are
unverified on devices: 96–100, 102, 104–105, 108 Partial; 101, 103, 106–107,
109–111 Queued. Group E2EE/polls reuse the 1:1 protocol work where applicable.

## Communities & channels (112–119)

All Queued. No community/channel UI or RPCs in pilot scope.

## Status (120–127)

| # | Feature | Status | Note |
|---|---------|--------|------|
| 120 | 24-hour status | Partial | Cloud text + local photo/video; no cloud media pipeline |
| 121 | Status privacy | Partial | Audience columns + RLS; picker unverified |
| 122 | Views counter | Partial | `status_views` + `mark_status_viewed`; viewer UI unverified |
| 123 | Mute status | Queued | — |
| 124 | Text customization | Done | Six colors + fonts for text cards |
| 125 | Status interactions | Queued | — |
| 126 | Profile rings | Queued | — |
| 127 | Links on status | Queued | — |

## Device linking & sync (128–136)

All Queued — single-device pilot by design (128–131). No cloud/local backup
pipelines yet (132–134); no transfer tools (135–136).

## UI & personalization (137–147)

| # | Feature | Status | Note |
|---|---------|--------|------|
| 137 | Dark mode | Done | System/Light/Dark + persisted |
| 138 | Chat wallpapers | Queued | — |
| 139 | Doodle overlay | Queued | — |
| 140 | Font sizing | Queued | — |
| 141 | Custom tones | Queued | Channels exist; per-chat tones not wired |
| 142 | Vibration controls | Queued | Call channel vibrates; no user controls |
| 143 | Pop-up notifications | Partial | Heads-up message/call/status notifications; no lock-screen toggle |
| 144 | Homescreen shortcuts | Queued | — |
| 145 | Multi-account | Queued | Single account per install |
| 146 | Change number | Queued | — |
| 147 | App language | Queued | Follows system |

## Storage & data (148–154)

All Queued (148–149 manager/bulk-delete, 150 auto-download, 151 usage
dashboard, 152 proxy, 153 export, 154 save-to-gallery).

## AI & utilities (155–161)

155 Done (BYO multi-provider AI chats: OpenAI/Anthropic/Gemini/DeepSeek).
156–160 Queued (no in-chat generation/editing/search/identify/translate
tools). 161 Queued.

## Business (162–176)

All Queued. No business profiles, catalogs, automation, payments, or API.

## System integration & accessibility (177–200)

Queued except: 191 Partial (server timestamps, local rendering; no TZ sync
test), 197 Partial (username/phone lookup; no address-book scan), 199 Done
(`delete_account` RPC). Push stack: foreground realtime watchers, channels,
tap routing, background FCM handler, and `notify-send` sender are Done;
background delivery additionally needs the `FCM_SERVICE_ACCOUNT` secret
(not yet provided). Inline notification actions/reply (179) and per-chat
mute/tone controls remain Queued; lockscreen previews (180) follow channel
importance with no separate toggle. Biometric lock (184), share sheet (185),
badges (181), and desktop/watch clients are all Queued.
