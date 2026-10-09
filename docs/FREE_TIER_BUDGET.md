# Free-tier budget

Provider pricing checked on 2026-10-09 where noted. A free allowance is a quota, not an unlimited-service guarantee. Runtime cost controls below are **planned**, not implemented by the UI prototype.

| Service | Allowance / decision | Pilot budget |
| --- | --- | --- |
| Supabase Free database | 500 MB/project; 2 active projects | 300 MB soft stop for new queue/media metadata writes |
| Supabase Auth | 50,000 MAU | 20 invited users initially |
| Supabase Realtime | 200 peak connections; 2 million messages/month | 50 connections, 500,000 events/month |
| Supabase egress | 5 GB egress plus separate cached allowance | 3 GB uncached/month; do not treat cached quota as interchangeable |
| Supabase Edge Functions | 500,000 invocations | 100,000/month |
| R2 Standard | 10 GB-month, 1M Class A, 10M Class B operations; free egress | 5 GB live objects, 100k writes, 1M reads/month |
| Notifications | FCM no-cost messaging; APNs for iOS | Generic notifications, coalesce repeated wake-ups |
| Calls | LiveKit candidate; current quota must be confirmed before use | Disabled until metering and provider quota are configured |
| Static web preview | Free static host candidate | Deploy later; no paid custom domain required |
| Email | Supabase default sender is restricted | Dashboard-created test accounts; configure a free SMTP allowance for public signup |

## Planned enforcement

- Start with 20 pilot users, 1 messaging device each, 10 MB per attachment, 50 MB upload/day/user, 7-day undelivered-message/media expiry, and 4,000-character text limit.
- Per-user upload limits alone are insufficient: reserve bytes atomically against a **global** cap before issuing upload authorization. Count outstanding reservations until expiry; verify actual object sizes.
- Track write/read operations as well as bytes. Private buckets, scoped short-lived URLs, caching, and bounded download authorization reduce abuse; signed URLs can still be replayed until expiry.
- Account for indexes, rows, auth tables, logs, replication, protocol overhead, and receipts. “500 MB” is not 500 MB of usable message text.
- Warn operators at 60% of internal budgets; reject new resource-consuming requests at the internal ceiling. Preserve delivery/cleanup capacity. These checks must live on the server, not solely in Flutter.
- R2 usage beyond included allowances can be billed; dashboard alerts are not a guaranteed hard spending cap. Enable media only once reservation, operation controls, expiry, and usage monitoring are deployed.
- Free Supabase projects can pause after a week of inactivity. Document resumption and client errors; this tier is not an uptime SLA.
- SMS authentication and app-store enrollment are not included in a zero-cloud-cost promise. Android direct APK distribution avoids store enrollment for the pilot; iOS has separate distribution constraints.

## Sources

- Verified Supabase quotas: https://supabase.com/pricing
- Verified R2 Standard allowances: https://developers.cloudflare.com/r2/pricing/
- Recheck notification terms: https://firebase.google.com/pricing
- Verify calling plan at phase 6: https://livekit.io/pricing
- Verify email restrictions before enabling registration: https://supabase.com/docs/guides/auth/auth-smtp
