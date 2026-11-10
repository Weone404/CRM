# CRM > ADS

Paid advertising for one or more clients inside the CRM: Google Ads and Meta accounts, campaigns,
daily platform metrics, CRM outcomes (leads, qualified leads, customers, confirmed revenue),
rule-based recommendations, an approval queue for budget/status changes, research notes and experiments.

Built the same way as CRM > Amazon (migration 072): Supabase Postgres + SECURITY DEFINER `api_*`
functions for the browser, `svc_*` functions for one Edge Function, secrets in Supabase Vault.

## Files

| Part | File |
|---|---|
| Schema, guards, metrics, browser + service API | `backend/migrations/076_ads_module.sql` |
| Schedules (pg_cron) | `backend/migrations/077_ads_cron.sql` |
| Google Ads + Meta connectors (pure TS) | `supabase/functions/_shared/ads_core.ts` |
| Edge Function (test / sync / execute) | `supabase/functions/ads-sync/index.ts` |
| UI | `frontend/src/components/Ads.jsx`, `frontend/src/utils/ads.js`, nav entry in `frontend/src/App.jsx` |
| Tests | `supabase/tests/ads/` (SQL, connector unit tests, headless UI) |

## Adding clients (migration 078)

- **New client** is a 3-step wizard: 1) Google Ads, Meta or both; 2) business basics (name, website, industry,
  country, currency, time zone, CRM leads link); 3) each picked platform's own setup. Industry presets fill sensible
  starting choices; every one can be changed. **Save draft** keeps a half-finished client ("Setup not finished").
- Option lists live in `ads_options` with the official source URL on each row, and the database refuses any other value:
  Google objectives and the campaign types Google offers for each (Google Ads Help 7450050), Google bidding focus,
  Meta's six `OUTCOME_*` objectives, special ad categories (None / Financial products and services / Employment /
  Housing / Social issues, elections or politics; a country is required for the last) and bid strategies.
- **Import existing accounts**: ADS > More > Clients > Import. `ads-sync` job `discover` lists every Google Ads account
  the saved keys can open (`customers:listAccessibleCustomers`, then each account's `customer_client` tree, managers
  excluded) and every Meta ad account (`me/adaccounts`). Pick accounts, choose a new or existing client, Import. Name,
  currency and time zone come from the platform; accounts under a Google manager keep that manager as
  `login_customer_id` for every later call. Accounts already in the CRM cannot be imported twice. After import the
  accounts are synced and the wizard opens to finish the client's setup.

## Who can do what

- **View ADS**: Admin, plus people Admin ticks in ADS > More > Settings > Team access.
- **Approve changes / record revenue**: Admin, plus people with "Can approve".
- **Clients, accounts, UTM mapping, keys, rules, emergency stop**: Admin only.
- Tables have RLS on and no grants to `anon`/`authenticated`; the browser only reaches data through `api_ads_*`.
- Keys are stored in Vault as `ads_<name>`. The browser only ever sees the last 4 characters.
  The activity log records the key name, never the value. Edge Function errors are scrubbed of tokens.

## How numbers are defined

All computed in SQL (`crm_private.ads_*`), never by an AI model. A zero or missing denominator gives
NULL, which the UI shows as "—", never 0.

| Metric | Source | Definition |
|---|---|---|
| Spend, impressions, clicks, platform conversions/value | Platform | Sum of `ads_metrics_daily` (each account's own reporting day) |
| CTR / CPC / CPM | Calculated | clicks ÷ impressions × 100 / spend ÷ clicks / spend ÷ impressions × 1000 |
| Platform ROAS | Platform | platform conversion value ÷ spend |
| Leads | CRM | Leads in the client's linked segment whose `utm_campaign` matches a campaign's UTM (case-insensitive), or else whose `utm_source` matches an account's UTM source |
| Valid leads | CRM | Leads with no call marked "Wrong number" |
| Qualified leads | CRM | Valid, and a call marked "Interested" or `is_eligible = true` |
| Customers | CRM | `closure_outcome` = admission_completed / booking_confirmed |
| Confirmed revenue | CRM | Sales − refunds entered in ADS > Leads & Revenue |
| CPL / qualified CPL / CAC | Calculated | spend ÷ valid leads / ÷ qualified / ÷ customers |
| CRM ROAS | Calculated | confirmed revenue ÷ spend |
| Contribution | Calculated | confirmed revenue × gross margin % − spend |

Platform-attributed value and CRM revenue are never added together. A client that is not linked to a CRM
segment shows CRM numbers as unavailable. Clients with different currencies are never totalled together.

## Changes to campaigns

1. Someone drafts a budget or pause/enable change (from Campaigns or a recommendation).
2. Guards run on insert and again on approval (`ads_rules`, editable by Admin): client max daily budget must be set and
   not exceeded, >20% change needs a second confirm, >100% is blocked, turning a campaign on needs a second confirm,
   max 3 changes per campaign per day, account must be connected, shared / ad-set / lifetime budgets are refused.
3. An approver approves. The executor claims it, re-checks guards, and marks it **stale** if the campaign changed since approval.
4. `ads-sync` sends it, then **reads the campaign back**: `verified`, `failed`, or `outcome_unknown`.
   Unknown outcomes are only re-read later, never re-sent.
5. Emergency stop (Settings) halts all sending immediately.

## Recommendations (no AI)

`crm_private.ads_recommend_all()` runs after each sync and on demand. Rules: spend with no CRM leads (default ≥ ₹2,000 in 14 days),
CPL > target by 50%, CPL < target by 30% with ≥ 5 leads (suggests +15% budget within the client max). Each one stores observation,
data used, reasoning, alternative explanations, proposed action, expected effect, confidence and money at risk.

## Activation (what is still needed)

Nothing talks to Google or Meta until these are done. Until then the UI shows "Not configured" / "Not checked yet".

1. Apply `076_ads_module.sql` in Supabase (SQL editor or MCP), deploy `ads-sync`, then apply `077_ads_cron.sql`.
2. ADS > More > Clients: add the client, link "CRM leads" (aviation or charter) and set **Max daily budget per campaign**
   (budget changes are blocked without it) plus any targets you know.
3. ADS > More > Ad accounts: add the Google Ads customer ID and/or Meta ad account ID, and the utm_source your ads use.
4. **Google Ads**: needs a developer token from a manager account's API Center (Basic or Standard access to touch real
   accounts; a test-access token only works with test accounts), an OAuth client (Google Cloud), and a refresh token from a
   user who can access the accounts. Add the manager ID if accounts sit under an MCC.
5. **Meta**: a System User access token (Business Settings) with `ads_read`; add `ads_management` to change budgets/status.
   The app secret is optional (enables `appsecret_proof`).
6. Settings > Test connection. Then Home > Sync now.
7. On each campaign, set its UTM campaign value (Campaigns > "UTM: not set") so CRM leads are counted per campaign.

API versions are settings (`google_api_version` = v26, `meta_api_version` = v26.0 as of 2026-11-10), not code.

## Tests (run 2026-11-10)

- `supabase/tests/ads/run.sh`: 97 SQL checks (076 + 078) (access, secrets, metric math, guards, approvals, execution states, recommendations), migration applied twice.
- `node --experimental-strip-types --test supabase/tests/ads/ads_core.test.ts`: 22 connector tests with a fake network (paging, headers, auth errors, verify-after-write, network drops, Meta minor units).
- `supabase/tests/ads/ui/run_ui.sh`: 37 headless-browser checks of the real UI against the real SQL (phone width included).
- `deno check supabase/functions/ads-sync/index.ts` and `vite build` pass.

Not tested against live Google/Meta accounts: no credentials exist yet. First live run = step 6 above.

## Not built yet

Ad groups / keywords / audiences / creatives management, offline-conversion upload (needs GCLID/FBCLID captured on website
lead forms first), Groq/Gemini summaries in ADS, the Claude remote MCP server, PDF reports, TikTok/LinkedIn/Microsoft connectors.
