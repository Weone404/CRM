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

## Still to come

- Phase 2: Connections & keys, a single page for all keys, grouped by provider. Secrets are write-only.
- Phase 3: the Website module.
- Phases 4–6: the same page layout applied to Ads, People, Amazon and FlightBridge AI.

Server-side load worth reviewing later:
- the Amazon bridge polls about 8,500 times a day;
- `crm-mongo-import` runs every minute, averaging 2.8 s;
- 84 foreign keys have no covering index (Supabase performance advisor).
