# CRM shell: layout, speed and connection health (Phase 1 of the redesign, 2026-11-18)

## What changed for people using the CRM

- **Home** is the start page: leads this week, leads not contacted yet, follow-ups due, Google clicks (for people with ADS access), one "Needs your attention" list, and folded details.
- **Grouped sidebar** on laptops (1024 px and wider): Home, People (Leads, Students, Tasks, Team, Attendance), Growth (Google Ads, Meta Ads, Amazon, FlightBridge AI), Setup (Settings, Policy Docs, My Profile, My Leave, Account). Phones and tablets keep the bottom bar, starting with Home; the "More" sheet uses the same groups. Old links keep working, `#/academy` included.
- **Signal indicator** in the top bar: Fast / Slow / Very slow / Weak internet / CRM not responding / Offline. Tap it for details: your internet, how fast the CRM server answers, the last refresh, and a "Check again" button.
- **Calm look**: the colour wash behind the app is gone (flat light grey), and the accent blue is #0A63CE, which has enough contrast on white for text.

## Why the CRM used to get stuck (measured 2026-11-18)

The server was healthy: in the last 24 hours, Postgres logged 0 errors, the database API answered in about 100–330 ms on average, and 1 of about 39,000 requests ended in a 5xx error. The problems were in the browser:

1. **No time limit on database calls.** `apiFetch` had a 20 s timeout, but in Supabase mode every `/api` call is answered in the browser by `backend/router.js`, which ignored that timeout. A dropped connection left the screen spinning forever. Now every Supabase request has a hard limit: 25 s for database and sign-in calls, 150 s for Edge Functions.
2. **Logged out after a Wi-Fi blip.** When the sign-in was refreshing while the network was down (a laptop waking up, Wi-Fi switching networks), the app answered 401 and signed the person out. Now:
   - an offline browser gets 503 "check your internet", not 401;
   - before signing anyone out, the session is renewed once (one shared renewal for all screens) and the request is retried;
   - the person is signed out only if the server really rejects the session.
3. **One failed refresh replaced the leads with an error wall.** Now the leads stay on screen with a quiet note ("Couldn't refresh. Showing leads from 12:31"). The app retries after 10 s, 20 s, 40 s and then every 60 s, and offers "Retry now".
4. **Polling while hidden.** The 60-second refresh now pauses while the tab is hidden. It runs at once when the tab comes back or the internet returns (if the data is more than 20 s old). Only one refresh runs at a time.
5. **Blank screen after a deploy.** A tab opened before a new version tried to load section files that no longer exist. On Vite's `vite:preloadError` event the CRM now reloads once (at most once a minute).
6. **One crashing section blanked everything.** Each section now sits inside an error guard. The rest of the CRM keeps working, and the section offers "Try again", or "Reload" when a newer version is out.
7. **Silent save failures.** Saving a lead's contact, follow-up or closure used to ignore errors. Now a failed save shows "Not saved: …" and keeps what was typed.

## How the signal indicator decides

`frontend/src/utils/netStatus.js` keeps the last 12 timings of real database requests, plus a light `/auth/v1/health` ping every 30 s. The ping runs only while the tab is visible and nothing else has talked to the server recently.

| What the CRM sees | Shown as |
| --- | --- |
| Median answer time 1.2 s or less | Fast |
| Median answer time above 1.2 s, or one failed request | Slow |
| Median answer time above 3.5 s, or a 2G connection | Very slow / Weak internet |
| Two or more failed requests in a row | CRM not responding |
| Browser offline, or a probe to Google's 204 endpoint fails | Offline |

When requests fail, a tiny request to Google's 204 endpoint tells whether the internet works. That is what separates "your internet is down" from "the CRM server is down".

Connection type and speed come from the browser's Network Information API. Only Chrome, Edge and Android support it, so on Safari those details are not shown.

## Tests

`supabase/tests/shell/run.sh` uses a stub Supabase server and headless Chromium. It needs `PLAYWRIGHT_DIR`.

- `shell_checks.mjs` (34 checks) covers:
  - sidebar groups and badges, and the section error guard;
  - Home numbers and folds;
  - every signal state and its recovery;
  - offline → 503 rather than logout;
  - time limits and screen-initiated cancel;
  - session renewal (renewed, rejected, unreachable, shared).
- `app_checks.mjs` (14 checks) runs the real `main.jsx` and `App.jsx` and covers:
  - Home as the start page, the sidebar, the signal pill;
  - a failed refresh keeping the leads on screen, then retry;
  - offline without logout;
  - the old `#/academy` link;
  - the phone bottom bar and the grouped More sheet.

## Phase 2: Connections & keys (migration 111, 2026-11-18)

Setup > Connections & keys (Admin only, `#/connections`) lists every key, token and account ID the CRM holds, grouped as:
- Google (Google Ads, Search Console, GA4)
- Meta
- Amazon
- AI models
- FlightBridge AI
- Email sending
- Sending data into the CRM

How each kind of item behaves:
- **Secrets** are write-only. They show as •••• and the last 4 characters, and offer Replace (typed into a hidden field), Test and Remove. Their value is never sent back to the browser.
- **Account IDs that are not secret** show in full and offer Copy and Edit. These are the OAuth client IDs, the MCC customer ID, the Meta App ID, the Amazon seller ID and profile ID, the Search Console site and the GA4 property.
- **Shared inbound tokens** (BookMyCharter, Hikvision, partner apps) offer Copy token and Replace. Both go through `api_connection_token` and `api_connection_rotate`, which audit-log every use. Replace warns that the old token stops working at once.

How the page is built:
- **Nothing moved.** Each key stays where its readers look: the Vault names `ads_*`, `amz_*`, `crm_*` and `crm_ai_*`, and `flightbridge.integration_secret`.
- **Saving and removing use the modules' existing functions:** `api_ads_settings_save` and `api_ads_secret_delete`, `api_amz_settings_save`, `api_ads_site_settings_save`, `ai_integration_set`, `ai_integration_toggle` and `ai_integration_delete`, FlightBridge's `/integrations` routes, and `api_amz_smtp`. Their checks and logs are unchanged.
- **Migration 111 adds only two functions:**
  - `api_vault_overview()`: read-only, Admin only. It returns statuses, last tests and the merged activity log.
  - `api_vault_amz_remove(name)`: Amazon keys had no Remove before.
- **Rollback:** `111_crm_vault_down.sql` drops those functions and touches no key.
- **Tests per group:**
  - Google: Test Google Ads and Check website data.
  - Meta: Test Meta.
  - Amazon: Test Amazon.
  - FlightBridge AI: Test per key.
- **Attention flags:** a group gets an "attention" flag on a failed test, GA4 with no data, a missing Meta Pixel, or the Amazon client secret coming due for its 180-day rotation.
- **Developer token:** the Google Ads developer token is not listed. Google retired developer tokens on 2026-09-09, and the ADS code no longer sends one.
- **Settings:** the old Settings > AI Integrations and Settings > Connections cards are replaced by a link to this page. Business email (mail server and sender) stays in Settings.

Tests:
- `supabase/tests/vault/run.sh` runs 18 SQL checks. They confirm that only Admin can open the page, that IDs come back in full while secrets come back as the last 4 only (no secret value anywhere in the answer), and that every store is covered, the activity log is merged and ordered, Amazon keys can be removed, private helpers stay private, and the rollback works.
- `supabase/tests/shell/app_checks.mjs` adds 17 checks (V01–V11) for the page, run in the real app.

## Still to come

- Phase 3: the Website module.
- Phases 4–6: the same page layout applied to Ads, People, Amazon and FlightBridge AI.

Server-side load worth reviewing later:
- the Amazon bridge polls about 8,500 times a day;
- `crm-mongo-import` runs every minute, averaging 2.8 s;
- 84 foreign keys have no covering index (Supabase performance advisor).
