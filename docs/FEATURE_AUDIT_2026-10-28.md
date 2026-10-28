# OpenChat — WhatsApp Feature Audit (201 items)

Audited 2026-10-28 against `lib/`, `android/`, `supabase/` (client + server truth).
Statuses: **✅ implemented**, **🎗️ partial**, **❌ missing**, **➖ N/A** (not implementable by the app).
openchat_web/ excluded (broken legacy mirror). Android is the target; iOS CallKit pending.

## Legend of notable audit-wide findings
- E2EE core is strong (Signal ratchet, EC+Kyber prekeys, sealed media, safety numbers).
- AI suite (8 features) and Business suite (12 features) are absent by design.
- Modern video-call polish (7 features) is absent; calls = LiveKit 1:1 + Telecom.
- Communities/channels are schema-only; "Viewed by", bans, reporting, @all missing.
- Several privacy toggles are UI-only pending client enforcement (read receipts, online status).

## 1. Text messaging, formatting & typing

| # | feature | status | evidence / note |
|---|---|---|---|
| 1 | Plain real-time texting | ✅ | secure_chat_screen.dart:1233-1323 (+ durable outbox, inbox poll/push) |
| 2 | Bold `*text*` | ✅ | widgets/messages_format.dart:25,48-54; formatted_text.dart:115 |
| 3 | Italic `_text_` | ✅ | message_format.dart:55-61; formatted_text.dart:138-141 |
| 4 | Strikethrough `~text~` | ✅ | message_format.dart:62-69 |
| 5 | Monospace triple-backtick | ✅ | message_format.dart:34-40; formatted_text.dart:86-90 |
| 6 | Bulleted lists | ✅ | formatted_text.dart:59-68; `*` bullet degrades |
| 7 | Numbered lists | ✅ | formatted_text.dart:71-83 |
| 8 | Block quotes `>` | 🎗️ | quote bar styled in groups/formatted views; DM path renders `▎` char only (secure_chat_screen.dart:5485) |
| 9 | Inline code | ✅ | formatted_text.dart:150-158 |
| 10 | Combined `*_bold italic_*` | 🎗️ | first-match-wins, no nesting (message_format.dart:21) |
| 11 | Edit within 15-min window | ✅ | chat_store.dart:133-139; enforced at 4000 chars |
| 12 | "Edited" tag | ✅ | secure_chat_screen.dart:5531; group_chat_screen.dart:2378 |
| 13 | Delete for me | ✅ | message_actions.dart:215-224; tombstone restore |
| 14 | Delete for everyone | ✅ 60-hour window (WhatsApp ≈ 60d) |
| 15 | Undo delete (5s snackbar) | ✅ | secure_chat_screen.dart:2740-2758 |
| 16 | Unicode emoji input | ✅ | system keyboard |
| 17 | Emoji keyboard + search | 🎗️ | emoji_picker_flutter wired to reactions only; group composer emoji button is a stub toast; no DM composer emoji keyboard |
| 18 | Skin-tone selector | ✅ | picker default config (enabled) |
| 19 | Predictive-text emoji | ➖ | keyboard-level |
| 20 | Clickable URLs | 🎗️ | styled as links (formatted_text.dart:160-168) but no tap recognizer in bubbles; links tappable in contacts/share bubbles only |
| 21 | URL rich previews | ❌ | no OG-metadata fetch anywhere |
| 22 | In-chat PDF viewer | ❌ | OpenFilex external viewer (document_bubble.dart:32) |
| 23 | Copy message text | ✅ | long-press → Copy |
| 24 | Multi-select copy | ❌ | no selection mode |
| 25 | Push-to-talk record | ✅ | voice_note_recorder.dart:318-351 |
| 26 | Recording lock (swipe up) | ✅ | voice_note_recorder.dart:320-323 |
| 27 | Record pause/resume | ✅ | voice_note_recorder.dart:160-177 |
| 28 | Draft playback before send | ✅ | recorder preview + send/discard |
| 29 | Waveform visualization | ✅ | real mic amplitudes (voice_note_player.dart:17-35) |
| 30 | Playback speed 1x/1.5x/2x | ✅ | voice_note_player.dart:93-97 |
| 31 | Background playback | ❌ | per-bubble player disposed on leave chat |
| 32 | Scrubbable progress | ✅ | Slider seek |
| 33 | Voice transcription | 🎗️ | manual typed transcript + display; automatic STT is a native stub (voice_transcript.dart:47-52) |
| 34 | Instant video notes (60s) | 🎗️ | capped loop playback OK; captured via OS camera app, not in-app circular recorder |
| 35 | Video note lock mode | ❌ | — |
| 36 | Camera flip during video-note capture | 🎗️ | OS camera's own flip only |
| 37 | Video note effects | ❌ | — |
| 38 | Video note backgrounds | ❌ | — |
| 39 | Keyboard mic dictation | ➖ | OS-level (app has an unused live-dictation service) |
| 40 | View-once voice notes | ❌ | view-once covers photo/video only |
| 41 | Camera capture in chat | ✅ | chat_media.dart:442-468 |
| 42 | Gallery picker | 🎗️ | single-select only (no pickMultipleMedia) |
| 43 | HD media toggle | 🎗️ | global pref applied at capture/pick; no per-send HD badge; video HD unaffected |
| 44 | Document transfer (large raw files) | ✅ | 200MB chunked encrypted upload (document_transfer.dart:171-219) |
| 45 | Batch media uploads | ❌ | one-by-one only |
| 46 | Media captions | ✅ | image + video + doc |
| 47 | Image cropping | ❌ | — |
| 48 | Image rotation | ❌ | — |
| 49 | Draw/doodle on photo | ❌ | — |
| 50 | Pixelate/blur tool | ❌ | — |
| 51 | Text overlay on images | ❌ | captions below only |
| 52 | Video trimming | ❌ | — |
| 53 | Strip audio from video | ❌ | — |
| 54 | GIF search & send | ✅ | Giphy picker (needs `GIPHY_API_KEY` define; sent as sealed bytes) |
| 55 | Video→GIF creator | ❌ | — |
| 56 | Sticker packs | 🎗️ | fixed set of 6 static stickers, no pack management |
| 57 | Sticker maker | ❌ | — |
| 58 | Animated stickers | ❌ | static PNG only |
| 59 | Favorite stickers | ❌ | — |
| 60 | Document scanning | ❌ | no scanner code |
| 61 | Forwarded (many times) tag | 🎗️ | authenticated `fwd` flag + "Forwarded"; forwardCount never incremented/rendered |
| 62 | E2EE | ✅ | Signal ratchet, EC+Kyber prekeys, sealed media, safety numbers |

## 2. Privacy, security & authentication

| # | feature | status | evidence / note |
|---|---|---|---|
| 63 | Biometric app lock | ✅ | security/app_lock.dart (local_auth + PIN fallback, relock timeout) |
| 64 | Chat lock (hidden folder) | ✅ | chat_lock.dart + home.dart locked-chats folder |
| 65 | Secret code unlock via search | ✅ | home.dart search == secret code reveals folder |
| 66 | Disappearing messages 24h/7d/90d | ✅ | per-chat override + expiry scheduling; default OFF |
| 67 | Default timer for new chats | ✅ | privacy default (0/24h/7d/90d), synced to backend; legacy 7-day default wiped once |
| 68 | View-once photos/videos | ✅ | one-consume claim + forward blocked |
| 69 | Last-seen hide toggle | ✅ | audience picker + `can_view_profile_field` RPC (fail-closed) |
| 70 | Online status hide toggle | 🎗️ | setting exists; presence published unconditionally, peers read `is_online` unchecked |
| 71 | Read receipts toggle | 🎗️ | toggle + sync exist; `_flushReadReceipts` sends receipts unconditionally |
| 72 | Profile photo privacy | ✅ | full audience machinery + exceptions, enforced server-side |
| 73 | About info privacy | ✅ | same machinery |
| 74 | Live location 15m/1h/8h | 🎗️ | durations + 30s updates, but each update = new static message (no live map bubble, no receiver stop) |
| 75 | Static location pin | ✅ | coordinates + label + Maps deep link |
| 76 | Two-step verification (TOTP+recovery) | ✅ | full management UI; not yet enforced at sign-in (server-side challenge pending) |
| 77 | E2EE security codes | 🎗️ | 60-hex safety numbers + verify + key-change warning; no QR in verify dialog |
| 78 | Silence unknown callers | ❌ | — |
| 79 | Call IP protection (relay) | ❌ | LiveKit direct connect only |
| 80 | Disable link previews | ❌ | no previews exist at all (so toggle moot) |
| 81 | Passkeys | ❌ | — |
| 82 | Strict account protection | ❌ | — |
| 83 | Per-device-restricted chats | ❌ | devices session registry only |
| 84 | Parental controls | ❌ | — |
| 85 | Pin conversations | 🎗️ | works, no 3-pin cap (unlimited) |
| 86 | Archive threads | ✅ | incl. groups + undo snackbar |
| 87 | Keep-chats-archived setting | ❌ | — |
| 88 | Mark as unread | 🎗️ | groups only; 1:1 lacks the flag |
| 89 | Global text search | ✅ | 1:1 + group + chat-list |
| 90 | Filter categories | ✅ | All/Unread/Favourites/Groups/Archived |
| 91 | Search-by-date jump | 🎗️ | 1:1 date filter (filters, not scroll-jump); groups lack it |
| 92 | Custom contact lists | ❌ | broadcast lists ≠ labels |
| 93 | Mute 8h/1w/always | ✅ 1:1; 🎗️ groups (bare toggle, no durations) |
| 94 | Custom per-chat sounds | 🎗️ | picker exists; only Silent changes behavior |
| 95 | Starred messages | ✅ | 1:1 + groups + viewer |
| 96 | Global wallpapers | ✅ | settings picker |
| 97 | Per-chat wallpapers | ✅ | 5 presets + override |
| 98/99 | Dark/Light themes | ✅ | System/Light/Dark control |
| 100 | Clear notifications on open | 🎗️ | per-chat clear + badge recount; no global clear-all on launch |

## 3. Calling

| # | feature | status | evidence / note |
|---|---|---|---|
| 101 | 1:1 voice calls | ✅ | LiveKit SFU + signaling + Android Telecom self-managed ringing (OpenChatConnectionService.kt) |
| 102 | 1:1 video calls | ✅ | VideoProfile, camera flip, renderer |
| 103 | Group calls | 🎗️ | audio-only drop-in rooms; no ringing group video calls |
| 104 | Screen share | ❌ | — |
| 105 | Call links | ❌ | — |
| 106 | Guest browser calling | ❌ | — |
| 107 | Low-light mode | ❌ | — |
| 108 | Video touch-up | ❌ | — |
| 109 | Virtual backgrounds | ❌ | — |
| 110 | Background blur | ❌ | — |
| 111 | In-call media sharing | ❌ | — |
| 112 | Host participant mute | ❌ | self-mute only |
| 113 | In-call side text | ❌ | — |
| 114 | Floating call window (PiP) | ❌ | full-screen route only |
| 115 | Call log history | ✅ | full log w/ direction icons, outcome, duration, missed styling |
| 116 | Missed-call callback | 🎗️ | push + Calls-tab tap + per-row callback buttons; no in-chat banner |

## 4. Groups & communities

| # | feature | status | evidence / note |
|---|---|---|---|
| 117 | Groups up to 1024 | ✅ | server-enforced (migrations 202610090015, 202610150010) |
| 118 | Admin-only messaging | 🎗️ | enforced for e2ee channels only; no group announcement flag/UI |
| 119 | Group invite links + QR | ✅ | rotatable admin-only code + deep link + QR |
| 120 | Join approvals | 🎗️ | `require_approval` hard-block only; no request/approve queue |
| 121 | Communities | 🎗️ | `communities` schema + RLS only; zero app code |
| 122 | Community announcement home | ❌ | column unused |
| 123 | Group polls | ✅ | live tally + realtime votes (create dialog single-choice default; multi reachable via repo) |
| 124 | Single-choice control | ✅ | single replaces prior vote |
| 125 | Group voice chat (drop-in) | ✅ | non-ringing by design, membership-checked RPCs |
| 126 | @mentions | 🎗️ | autocomplete + plain-text insertion; no highlight/notification |
| 127 | @all | ❌ | — |
| 128 | Group events/RSVP | ❌ | — |
| 129 | Silent group exit | 🎗️ | leave is silent even to admins (WhatsApp notifies admins) |
| 130 | Searchable participant list | 🎗️ | roster with roles/remove; not searchable |
| 131 | Membership history | ❌ | — |
| 132 | Group description | ✅ | editable by admins, shown in info/invite |
| 133 | Group bans | ❌ | removed members re-addable |
| 134 | Message reporting | ❌ | telemetry only |
| 135 | 24h status updates | ✅ | realtime fan-out + media bucket |
| 136 | Text status styles | 🎗️ | 6 background colors; fixed font |
| 137 | Voice status | ❌ | rejected server-side |
| 138 | Status music | ❌ | — |
| 139 | Status privacy | ✅ | audience + RLS enforced |
| 140 | Status viewer list | 🎗️ | views recorded server-side; no "Viewed by" UI |
| 141 | Status reply (swipe up) | ❌ | — |
| 142 | Status resharing | ❌ | — |
| 143 | Channels | 🎗️ | data model + e2ee guard + list rendering; no create UI, no follow flow |
| 144 | Channel reactions | 🎗️ | shared group reaction machinery applies |
| 145 | Channel QR invite | ❌ | invite machinery is group-only |
| 146 | Channel video notes | ❌ | — |
| 147 | Broadcast lists | 🎗️ | local CRUD + UI; **send is a stub** |

## 5. Meta AI & smart assistance

| # | feature | status | note |
|---|---|---|---|
| 148-155 | All AI features (assistant, rewrite, translate, /imagine, suggestions, incognito, profile art, agents) | ❌ | AI chatbot deliberately removed; nothing AI-similar exists |

## 6. Multi-device, platform & storage

| # | feature | status | evidence / note |
|---|---|---|---|
| 156 | Companion linking (4 devices) | 🎗️ | cloud session registry + per-session logout; no QR linking/key sharing |
| 157 | Independent web sync | 🎗️ | web sessions register; history stays device-local encrypted SQLite |
| 158 | iPad/tablet app | ❌ | — |
| 159 | Wear OS | ❌ | — |
| 160 | CarPlay / Android Auto | ❌ | — |
| 161 | Cross-platform transfer | ❌ | — |
| 162 | Dual accounts | ❌ | — |
| 163 | Media hub | 🎗️ | global encrypted media browser (All/Images/Voice/Docs); no Links tab / per-chat hub |
| 164 | Storage breakdown | ❌ | per-file sizes + server quota hint only |
| 165 | Bulk storage cleaner | ❌ | automatic orphan cleanup only |
| 166 | Manage downloads | ❌ | — |
| 167 | Auto-download filters | ❌ | on-demand fetching |
| 168 | Low data toggle | 🎗️ | media-quality reduction works; call bitrate unaffected |
| 169 | Chat backup (Drive/cloud) | ✅ | scheduled encrypted snapshots + Google Drive mirror |
| 170 | Encrypted backups (password/64-digit) | ✅ | password-derived + 32-byte media key, 3-snapshot retention |
| 171 | Export chat as .txt | ✅ | written to app dir |

## 7. Business suite

| # | feature | status | note |
|---|---|---|---|
| 172-183 | Business profile, catalogs, collections, cart, greetings, away, quick replies, labels, API segments, ads, payments, AI bots | ❌ | no commerce code of any kind |

## 8. Quality of life & UI details

| # | feature | status | evidence / note |
|---|---|---|---|
| 184 | Swipe-to-reply | ✅ | 1:1 + groups |
| 185 | Double-tap reaction | ✅ | ❤️ |
| 186 | Quick media button | 🎗️ | attach → grid sheet; no always-visible camera button |
| 187 | Pinch-to-zoom video call | ❌ | — |
| 188 | Personal contact QR | ✅ | profile QR + group QR |
| 189 | Message unsaved numbers | 🎗️ | phone lookup routes to invite (no direct chat) |
| 190 | Usernames | 🎗️ | unique @usernames + lookup; no reservation-management flow (it's automatic) |
| 191 | Message info (exact delivered/read) | ✅ | info sheet with timestamps |
| 192 | Vibration patterns | ❌ | fixed channel flags |
| 193 | Lockscreen preview toggle | ❌ | FLAG_SECURE only |
| 194 | Home-screen widgets | ❌ | — |
| 195 | App icon shortcuts | ❌ | — |
| 196 | In-chat media filters | ✅ | type dropdown (img/vid/voice/doc/contact/loc/poll) + date |
| 197 | Network usage stats | ❌ | — |
| 198 | In-app language | ❌ | follows system |
| 199 | Instagram Reels | ❌ | — |
| 200 | Message scheduling | ❌ | durable outbox = retry, not send-later |
| 201 | Default app assignment | ❌ | no tel:/sms: intent filters |

## Scorecard

| Cluster | items | ✅ | 🎗️ | ❌ |
|---|---|---|---|---|
| 1 Text & voice notes & media (1-62) | 62 | 27 | 13 | 20 (+2 N/A) |
| 2 Privacy & chat management (63-100) | 38 | 15 | 11 | 12 |
| 3 Calls (101-116) | 16 | 4 | 2 | 10 |
| 4 Groups, communities, status (117-147) | 31 | 6 | 13 | 12 |
| 5 Meta AI (148-155) | 8 | 0 | 0 | 8 |
| 6 Multi-device & storage (156-171) | 16 | 3 | 5 | 8 |
| 7 Business (172-183) | 12 | 0 | 0 | 12 |
| 8 QoL (184-201) | 18 | 5 | 5 | 8 |
| **Total** | **201** | **60** | **49** | **90 (+2 N/A)** |

### Highest-impact next fixes (recommendation order)
1. **Enforce read-receipt + online-status privacy toggles client-side** (71, 70) — toggles exist but are ignored; silent privacy leak.
2. **Broadcast list real sending** (147) — UI exists, send is a stub.
3. **Multi-image picking & batch upload** (42, 45) — common expectation.
4. **"Viewed by" status viewer list** (140) — data already recorded server-side; UI only.
5. **Clickable links in bubbles** (20) + in-chat PDF viewer (22).
6. **Mark-as-unread for 1:1 chats** (88) + mute durations for groups (93) + searchable roster (130).
7. **Deep polish that is expensive / lower priority**: media editor (47-53), call video effects (107-110), PiP (114), communities (121-122).
