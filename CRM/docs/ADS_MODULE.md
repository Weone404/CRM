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
4. **Google Ads** (no developer token: Google retired them on 2026-09-09; access is set per Google Cloud project):
   in Google Cloud, enable the Google Ads API on a project and check its access level on the Google Ads API page
   (a new project has Test access, which cannot open live accounts; Explorer or Basic can; Basic needs brand
   verification). Create an OAuth client in that project, then a refresh token (scope
   `https://www.googleapis.com/auth/adwords` and, for sending conversions through the Data Manager API since 15 June 2026, `https://www.googleapis.com/auth/datamanager`) signed in as a Google user who can open the ad accounts.
   Add the manager ID if accounts sit under an MCC.
5. **Meta**: a System User access token (Business Settings) with `ads_read`; add `ads_management` to change budgets/status.
   The app secret is optional (enables `appsecret_proof`).
6. Settings > Test connection. Then Home > Sync now.
7. On each campaign, set its UTM campaign value (Campaigns > "UTM: not set") so CRM leads are counted per campaign.

API versions are settings (`google_api_version` = v26, `meta_api_version` = v26.0 as of 2026-11-10), not code.

## Tests (run 2026-11-10)

- `supabase/tests/ads/run.sh`: 97 SQL checks (076 + 078) (access, secrets, metric math, guards, approvals, execution states, recommendations), migration applied twice.
- `node --experimental-strip-types --test supabase/tests/ads/ads_core.test.ts`: 23 connector tests with a fake network (paging, headers, auth errors, verify-after-write, network drops, Meta minor units).
- `supabase/tests/ads/ui/run_ui.sh`: 37 headless-browser checks of the real UI against the real SQL (phone width included).
- `deno check supabase/functions/ads-sync/index.ts` and `vite build` pass.

Not tested against live Google/Meta accounts: no credentials exist yet. First live run = step 6 above.

## Meta lead sources (migration 100, 2026-11-16)

Meta Ads > Settings > Meta lead sources. Three sources, each switched on and configured there (all start off):

| Source | Leads in | Reported to Meta as |
|---|---|---|
| Meta lead forms (Instant Forms) | `ads-meta-webhook` (Page `leadgen`) → `ads-sync meta_leads` → ADS intake; daily `meta_leads_reconcile` reads each form's last 48 h | Conversions API for CRM: `action_source=system_generated`, `custom_data.event_source=crm`, `custom_data.lead_event_source`=CRM name, `user_data.lead_id` |
| Meta ad → website | already via `ads-intake` (fbclid); intake now also keeps the browser's User-Agent | website events: `fbc` (fb.1.<ms>.<fbclid>, unhashed), `event_source_url`, `client_user_agent` |
| WhatsApp ads (Click-to-WhatsApp) | `ads-meta-webhook` (WhatsApp `messages` with `referral.ctwa_clid`; needs a Cloud API number) | business messaging: `whatsapp_business_account_id` + `ctwa_clid`, only `LeadSubmitted` / `QualifiedLead` |

Per source: intake on/off, report on/off, consent rule (only yes / everyone except no / everyone), consent purpose, dataset ID,
default pipeline, and the Meta event name for every stage. Each (lead, source, stage) is sent once; a stage older than 7 days is
skipped (Meta discards it); phone and email leave the database only as SHA-256; the emergency stop blocks all sending.
Lead forms: "Check Page" lists the forms and the leadgen subscription, "Connect Page" subscribes it; each form can go to Pilot
Training or Charter. Organic form fills (no ad) are not made Ads leads.

Go-live steps (in order):
1. Apply `100_ads_meta_signals.sql` (SQL editor). Rollback: `100_ads_meta_signals_down.sql`.
2. Deploy: `supabase functions deploy ads-sync`, `supabase functions deploy ads-intake --no-verify-jwt`,
   `supabase functions deploy ads-meta-webhook --no-verify-jwt`.
3. Settings > Meta Marketing API: access token (System User with `ads_management`, `leads_retrieval`, `pages_show_list`,
   `pages_read_engagement`, `pages_manage_metadata`, and the Page as an asset), App secret, Webhook verify token.
4. Meta App Dashboard > Webhooks: object Page, field `leadgen`, callback URL shown in the panel, the same verify token.
   Switch the app to **Live** (in Development mode Meta only sends test pings). Own-business use needs no App Review.
5. Panel: Facebook Page ID > Check Page > Connect Page. Ad accounts: add the Meta ad account.
6. Turn on "Bring leads into Ads Leads", submit a test lead (Meta Lead Ads Testing Tool), check it appears.
7. Add the dataset ID, choose the consent rule, then turn on "Report lead stages to Meta".
WhatsApp reporting needs Advanced Access to `whatsapp_business_manage_events` (App Review) before it is switched on.

Tests: `run.sh` A0_ (MS01–MS35 + R03 rollback), `ads_meta.test.ts` (25), `ui_checks.mjs` UI09/09c, UI120–UI141.

## Meta Ads > Automate: quick actions, rules with approval, A/B tests (migration 110, 2026-11-18)

- Quick actions (`api_ads_meta_action_request`, approvers): pause, switch on, daily budget (new ₹ or %), duplicate (paused,
  ad sets / campaigns with their ads). Every request waits in `ads_meta_action` until an approver approves
  (`api_ads_meta_action_decide`; optional two-person rule `meta_actions_two_person`). ads-sync job `meta_actions` (on approve
  and every 15 min while something is approved) reads the object, applies the change, reads it back, and records before /
  after; already-in-state is "done" with a note. Guards: Meta emergency stop, floor / ceiling `meta_action_min_daily` /
  `meta_action_max_daily`, +100% only by Admin, 20%+ warning (big edits can restart learning), 3-day expiry.
- Rules (`ads_meta_rule`, 4 templates off by default): metric over 1-30 days (spend, leads, cost per lead, cost per qualified,
  qualified, CTR, frequency, CPM), minimum spend / leads, action (pause, budget up / down %, warn only), cool-down. A cost
  with nothing bought counts as above the limit once the spend alone passes it. Rules only create requests or warnings;
  checked daily 09:10 IST (`crm-ads-meta-rules`) and on "Run now".
- A/B tests (`ads_meta_test`): 2-5 cells of ad sets, ads or campaigns, one variable, metric (cost per lead / qualified,
  qualified rate, CTR), dates, minimum results per cell. Cost metrics: binomial test of each cell's results against its
  spend share vs the control; rates: two-proportion z-test; 95% to call a winner; "too early" until every cell has enough.
  "Meta split test" also creates an ad study (`/{business}/ad_studies`, SPLIT_TEST, equal shares) when the ad account has a
  Business.
- New tab Meta Ads > Automate. Build 2026-11-18.meta10. Rollback: `110_ads_meta_actions_down.sql`.

## Meta Ads > Funnel plan: lookalikes, personas, budget split, creative-diversity checks (migration 109, 2026-11-18)

- Lookalikes (audience kind `lookalike`, stage `cold`, use `prospect`): 1% of admissions, 1% and 1-3% of qualified leads, 1%
  of hot-scored leads, India. The nightly audience job makes them after their seeds (`lookalike_spec` similarity, ratio,
  starting_ratio, country) once the seed has the 100 people Meta requires; until then they wait as "planned" with the reason.
  In builds, audiences included in a new-people ad set are used only with Advantage+ audience (hints); without it they are
  left out so they never become the whole audience.
- Personas (`ads_meta_persona`, Admin edits in Funnel > Personas): who, Search Console topics they ask, objections, proof
  needed, angles, best stages, form questions. Seeded with six from public facts only (no fees, salaries or tie-ups).
- Funnel plan (`api_ads_meta_funnel_blueprint(monthly, split)`): budget per stage (new people / retarget / re-engage),
  retarget and re-engage capped by ready pool sizes at the account CPM (about 3 ads a week per person) with the rest moved to
  new people; audiences to include / exclude, form, message, personas, KPI, expected leads a week and a learning-phase note
  (about 50 optimisation events per ad set in 7 days). "Send to Strategy" creates a strategy whose goal carries
  `funnel.split` and `personas` (goal cleaning wraps the 104 version: `ads_meta_goal_clean_base`).
- Plan checks wrap the 104 checks (`ads_meta_plan_check_base`) and send back: creatives sharing 70%+ of their words, 4+
  creatives with fewer than 3 angles, unknown persona keys, goal personas not covered, unknown audience keys, retarget /
  reengage ad sets with no audience, seeds included on new-people ad sets without Advantage+ audience, and a funnel split
  more than 10 points from the goal (a stage with no ready audience may be 0). The new problems come first (up to 40 in all).
- Agents get `personas` in their context; prompts ask for a persona and concept on every creative. Build 2026-11-18.meta9.
  Rollback: `109_ads_meta_funnel_plan_down.sql` (renames the 104 functions back).

## Meta Ads > Funnel > Website signals and agent funnel context (migration 108, 2026-11-18)

- Search Console (`searchAnalytics.query`, by query and page) and GA4 (Data API `runReport`: landing pages, channels,
  source / medium, cities, events) read by ads-sync job `site_signals` (nightly 03:20 IST, cron `crm-ads-site-signals`, or
  "Check now"). Totals only: 28 days and the 28 before (Search Console ends 3 days back for its lag). Stored in
  `ads_site_row`. Sign-in: Vault secret `GOOGLE_SITE_REFRESH_TOKEN` (scopes webmasters.readonly + analytics.readonly) with
  the Google Ads OAuth client; Admin sets `site_gsc_url` (sc-domain:... or https://.../) and `site_ga4_property` (digits).
- Search intent topics (`ads_site_topic`, editable regex per topic), rising searches (1.5x impressions, 20+), landing pages
  joined across both tools, channels, cities, website funnel (sessions, form_start, form_submit / generate_lead, key events).
- The job also finds the Meta Pixel on the ad account (`meta_pixel`: id, last fired, firing in 7 days). Website audiences
  (kind `website`): fees / cost page viewers 30 days, course pages 60 days, any visit 30 days, Lead event 180 days
  (excluded from new-people ads by default). Rules use the Pixel, url / event `i_contains`, 180 days at most.
- Strategy agents: ads-agents adds `svc_ads_meta_strategy_extra()` to the Meta context (funnel 90 days, audience library
  with ready / size, location verdicts, website signals); the prompts now ask for a full-funnel plan (prospecting, retarget,
  reengage) using audience keys, exclusions and search-intent angles. Funnel and location bodies moved to
  `crm_private.ads_meta_funnel_data` / `ads_meta_geo_data` (the APIs wrap them).
- Build 2026-11-18.meta8. Rollback: `108_ads_site_signals_down.sql`.

## Meta Ads > Funnel: map, audience library, location focus (migration 107, 2026-11-18)

Why: in 2026 Meta treats only location, minimum age, languages and custom audience exclusions as hard limits; age, gender,
interests and included custom / lookalike audiences are hints for Advantage+ audience, and interest exclusions are gone.
So targeting is done with our own audiences, hard exclusions and a message per funnel stage. New tab Meta Ads > Funnel:

- Funnel map (`api_ads_meta_funnel(from, to)`): ad views, clicks (Meta), leads, called, qualified, admissions (CRM, Meta
  leads only), cost per stage, share moving on, median first call and days to qualify, warm / hot pools waiting in Meta,
  and plain notes (never-called leads, low qualify rate, leads lost between Meta and the CRM).
- Audience library (`ads_meta_audience`, 12 to start): engagement audiences made in Meta from rules (lead form opened /
  dropped off, messaged the Page or Instagram, Instagram profile visit / engagement, Page engagement; no personal data
  leaves) and CRM lists (leads of 30 days, open 30-180 days, lost, qualified, hot-scored, admissions) sent SHA-256 hashed
  via the Replace API (does not restart learning) and only for people whose consent rule allows it (the Conversions API
  rule of their Meta source; anyone else needs ad-data-sharing consent). Admin turns it on (`meta_audiences_on`); ads-sync
  job `meta_audiences` runs nightly (cron `crm-ads-meta-audiences`, 02:50 IST) or on "Update now", saves the Meta id,
  size and problems (Custom Audience terms link, missing permission, missing Instagram account).
- Exclusions in builds: Strategy > Create in Meta now adds `excluded_custom_audiences` to new-people ad sets (funnel
  "prospecting", the default) from the audiences marked "exclude from new-people ads" (admissions and leads of 30 days by
  default); an ad set may also name `audience.funnel`, `include_audiences` and `exclude_audiences` by key.
- Location focus (`api_ads_meta_geo(from, to)`): Meta spend and leads by state next to CRM qualified / admissions by
  state (form state answer, or city mapped through `ads_geo_in`), with a verdict (focus / keep / reduce / cut / too few).
- Build 2026-11-18.meta7 (ads-sync changed). Rollback: `107_ads_meta_funnel_down.sql` (audiences already in Meta stay).

## Meta Ads > Lead quality and lead score (migration 106, 2026-11-17)

Meta counts form fills; the CRM knows which became qualified leads and admissions. Reports now has two views: Meta results
(Ads Manager style, 105) and Lead quality (CRM).

- Lead quality (`api_ads_meta_lead_quality(from, to, dim)`, any ADS viewer): leads, leads the CRM can follow, qualified,
  admissions, both rates and median first call, grouped by lead form, campaign, ad set, ad, Facebook / Instagram, any
  lead-form answer (`answer:<key>`), time to first call, weekday or hour. Built from the lead archive (104) joined to CRM
  stages; groups under 10 followed leads are flagged.
- Lead score (`ads_lead_score`, 0-100, hot / warm / cold): each new Meta lead is scored as it is archived. With 20+ followed
  leads in the last year the score starts at the average qualified rate and moves by how past leads with the same form,
  campaign, ad, platform and answers did (each rate smoothed toward the average and weighted by sample size, so a few
  leads never swing it); otherwise it is 50. Admin rules (`lead_score_rules`: field form / campaign / platform /
  answer:<key>, equals or contains, -50..50 points) add on top; bands from `lead_score_hot` (60) and `lead_score_warm` (35).
  Every score keeps its reasons. Saving rules rescores the last 30 days.
- Where it shows: score chips on Overview > Speed to lead (highest first) and the Lead quality view's last-7-days list
  (not-called first). APIs: `api_ads_lead_scores(ids)`, `api_ads_meta_scored_leads(days)`, `api_ads_lead_score_settings()`,
  `api_ads_lead_score_save(rules, hot, warm)` (Admin).
- No Edge Function change (build stays meta6). Rollback: `106_ads_meta_quality_down.sql`.

## Meta Ads > Reports and account health (migration 105, 2026-11-17)

- **Reports tab** (`AdsMetaReports.jsx`): Ads Manager-style table. Levels (campaigns / ad sets / ads / account), date presets
  (today ... maximum 37 months, custom), compare to the previous period, filters (campaigns, ad sets, ads, delivery status,
  name contains) sent to Meta, breakdowns by time (day / week / month), demographics (age, gender, age x gender), geography
  (country, region) and delivery (platform, placement, device, platform x device, hour, frequency) with value filters
  (for example only 18-24, only Instagram) applied in the browser, column presets (Performance, Leads and CRM results,
  Delivery, Engagement, Video engagement, Ad relevance) and custom columns with order, sorting, totals (reach summed only
  across disjoint splits), drill-down (select campaigns -> ad sets -> ads), chart, CSV export, print, saved views (own;
  Admin can share). Metrics: spend, Meta leads, cost per lead, reach, impressions, frequency, CPM, cost per 1,000 reached,
  clicks, CTR, CPC, link clicks, link CTR, cost per link click, lead rate, 3-s plays, hook rate, 25/50/75/100% plays,
  ThruPlays, hold rate, quality / engagement / conversion rankings, and CRM leads, qualified, admissions, cost per
  qualified lead, cost per admission (per campaign / ad set / ad, not per split).
- **Data**: ads-sync job `meta_report` (any ADS viewer) reads Meta's Insights API live (`_shared/meta_report.ts`), cached in
  `ads_meta_report_cache` (3 h for recent days, 7 days for old). Meta's limits: splits 13 months, frequency 6 months,
  reach / frequency 13 months and not by hour, no off-Meta actions for region / hour.
- **Account health** (Overview, `AdsMetaHealth.jsx`): ads-sync job `meta_health` (cron `crm-ads-meta-health`, every 3 h at
  :40) reads Opportunity Score and recommendations, account status and spending limit, live campaigns / ad sets / ads with
  issues, learning stage and daily budgets, and 17+ days of daily numbers (`_shared/meta_health.ts`). Warnings
  (`ads_meta_warning`, open until no longer found): account not active, spending limit 90%, ad rejected (with Meta's
  reason), ad / campaign issues, learning limited, no leads yesterday after 2x the usual cost per lead, cost per lead up
  30% (3 vs 14 days), spend jump, Meta counted more leads than the CRM received (webhook), leads that failed to file.
  New high warnings: phone notification and email to Admin and approvers. Admin can dismiss.
- **Agents helper**: updates itself every 30 minutes, when ads-agents says newer work waits (`svc_ads_agents_meta_waiting`),
  or when handed a role it does not know (gives the step back first). Strategy shows the restart command when no agent
  picks a step up for 5 minutes.
- Undo: `105_ads_meta_reports_down.sql`. Tests: A4_ (RP01-06, HL01-07), R08, `meta_reports.test.ts` (6), UI170-180.

## Meta Ads > Strategy, lead archive, speed to lead (migration 104, 2026-11-17)

- **Strategy tab** (`AdsMetaStrategy.jsx`). Admin sets a goal (admissions / qualified / leads, target, monthly budget limit or
  "suggest", courses, places, languages, start, length, lead-to-admission %, value of an admission, website, privacy policy, notes;
  checked by `crm_private.ads_meta_goal_clean`). The ADS agents work on it on the same helper as the Google agents:
  `meta_researcher` (web only: Meta guidance, benchmarks, timing, website facts, competitors) -> `meta_strategist` (full plan)
  -> `meta_reviewer`. Code checks (`crm_private.ads_meta_plan_check`: structure, keys, budgets x 30.4 = monthly within 10%,
  owner's limit, PHONE + FULL_NAME, ages 18-65, forecast arithmetic, banned claims, QUALITY_LEAD only at 200+ Meta leads a month)
  run before the Reviewer; 3 tries in all, then the plan is kept as "needs review" with the problems. Every plan / change is a
  version (`ads_meta_strategy_version`); the owner approves one. Change requests (text, optional fresh research, or a new goal)
  revise the latest version. 8 owner-started runs per 24 h (`meta_strategy_per_day`). Context: 37-month Insights cut by
  `trimMetaContext` + the CRM's own patterns (`meta_patterns.ts`), CRM funnel, lead archive, past strategies and checks.
- **Agents helper**: `next` with `meta: true` (`svc_ads_agent_next2`); older helpers only get Google steps. `finish` goes to
  `svc_ads_meta_agent_finish` first ({handled:false} for Google). Prompts: `tools/ads-agents/prompts.mjs` (META_*).
- **Create in Meta** (ads-sync `meta_build`, Admin): builds the approved version, everything PAUSED: lead forms (Page token;
  intro / thank-you retried without if refused), campaigns (`is_adset_budget_sharing_enabled=false` for ad-set budgets),
  ad sets (locations and interests looked up with Meta search; `advantage_audience` 1 or 0; Advantage+ keeps 18-65 and takes the
  plan's ages as `age_range`), image creatives with an uploaded picture (`meta_image`, PNG / JPEG up to 8 MB), ads. Each step is
  saved at once (`svc_ads_meta_build_step`), so pressing again continues and never duplicates. Video / carousel ads are left
  for Ads Manager. Names end with `· CRM S<id>`. Builder: `_shared/meta_build.ts`.
- **Plan vs actual**: weekly (`crm-ads-meta-track`, Monday 06:05 IST) for approved strategies with linked or built campaigns;
  "behind" drafts a revision (at most once in 14 days) that waits for approval; the approved version stays.
- **Lead archive** (`ads_meta_lead_archive`): every Meta form lead the CRM files (ad or organic) is copied by trigger with its
  answers and kept for good; each form is read back once for the 89 days Meta still holds (`full_swept_at`); old CSV downloads
  import (Overview, Admin; matched to Leads by phone); Admin can download everything as CSV.
- **Speed to lead**: ad leads (Google and Meta) with no first call after 5 min (owner) / 15 min (Admin), 09:00-20:00 IST,
  only leads after the feature was switched on (`lead_alert_since`). Cron `crm-ads-lead-alerts` (every 2 min, wakes ads-sync
  `lead_alerts` only when due): phone notifications (CRM push keys, people who turned them on) and email (CRM SMTP, when set
  up). Overview shows waiting leads and the settings.
- Build `2026-11-17.meta5`; ads-agents answers `GET /version` and is in Meta Setup step 2. Undo: `104_ads_meta_strategy_down.sql`.
  Tests: A3_ (SG01-36), R07, `meta_strategy.test.ts` (8), `agents.test.mjs` (+2), UI160-169.

## Meta Ads > Insights (migration 103, 2026-11-17)

Read-only history dashboard. ads-sync job `meta_history` (cron `crm-ads-meta-history`, minute 50, only when work is due):
back-fills up to 37 months of ad-level daily numbers month by month (resumable; Meta keeps totals 37 months), saves campaigns /
ad sets (targeting summary) / ads (creative: format, text, call to action, thumbnail, lead form), refreshes the last 30 days daily,
whole-account breakdowns weekly (age x gender, region, placement, device, hour: 13 months; frequency: 6 months), and on the 1st
saves last month's summary (emailed via the CRM's SMTP when set up; recipients in Insights > Monthly summaries).
CRM outcomes per campaign / ad set / ad / form come from Ads leads' ad ids (`crm_private.ads_meta_crm`).
Dashboard (`AdsMetaInsights.jsx`): filters, number tiles vs previous period, proven patterns, funnel, budget what-if, weekly
chart with notes, leaderboard, creative gallery, audience / timing charts, ad fatigue, notes, monthly summaries, print to PDF.
Patterns / what-if / summary text: `_shared/meta_patterns.ts` (same code in browser and ads-sync). Goal = admissions (8+),
else qualified (15+), else Meta leads; win <= 0.8x average cost, loss >= 1.4x (or 2x average spent with no result);
"Proven" needs enough results (win) or enough spend (loss), else "Early". Splits are judged against their own average and the
whole-account splits are hidden when filtered to a campaign or form. Build `2026-11-17.meta4`.
Undo: `103_ads_meta_insights_down.sql`. Tests: A2_ (MI01-20), R06, `meta_insights.test.ts` (16), UI150-158.

## Meta's CRM check (migration 102, 2026-11-17)

Events Manager > dataset > Test events > channel **CRM** gives no TEST code: Meta creates a Verification Lead (a Testing Tool
lead, delivered by the webhook, kept as `test`) and waits for one ordinary Conversions API event for that lead id. Setup step 10
"Send for Meta's Verification Lead" = ads-sync `meta_test_event` with no code: `svc_ads_meta_verification_lead()` gives the
newest test lead of the last 7 days, the dataset and the Lead Created event name; only test leads are ever used; the Meta stop
blocks it. A TEST code (Website / server channel) still sends a Test events event as before. Build `2026-11-17.meta3`.
Undo: `102_ads_meta_verification_down.sql`. Tests: MS48 (A1_), R05, UI136c.

## Meta lead forms, part 2 (migration 101, 2026-11-17)

- A lead form filled **without an ad** (opened from the Page) becomes a normal lead in **Leads**: utm_source `Meta lead form`,
  utm_medium `organic`, utm_campaign = the form's name, same phone de-duplication as the website (`crm_private.ingest_website_lead`);
  a form set to Charter makes a charter lead. Not an Ads lead, never reported to Meta. Extra answers stay on
  `ads_meta_lead_raw.payload.answers`; a fill without a valid phone is not filed and the reason shows in Setup.
- Leads made with Meta's **Lead Ads Testing Tool** (every answer "test lead: dummy data for …") are status `test`: they prove the
  path and are never filed. "Send a test event" falls back to the newest delivered lead's id.
- The safety re-read of every active form runs **every hour** (was daily).
- Setup: step 8 turns green only when Meta delivered a lead **through the webhook** and the CRM handled it; the database reports its
  version (`ads_config.ads_schema`), so Setup shows "A database update is waiting" and hands out only the missing SQL file(s);
  an ads-sync with an older build shows "older version, deploy again".
- Deploy (Supabase CLI 3: `--project-ref` is now `--remote=`):
  `npx -y supabase@latest functions deploy <name> --no-verify-jwt --use-api --remote=syytqcadmtgowckdnbqh --yes`
  for ads-sync, ads-intake and ads-meta-webhook (ads-sync checks the caller itself, as it is deployed today).
- Undo: `101_ads_meta_organic_down.sql`. Tests: `A1_` (MS40–47), R04 rollback, Deno (test lead, organic payload, build), UI134–136b.

## Two sections and Setup checklists (2026-11-16)

The main menu has **Google Ads** (`#/ads`, the existing screens) and **Meta Ads** (`#/metaads`: Overview, Campaigns, Leads,
Setup, Settings). Same tables and rules underneath; each section shows only its platform:
- Campaigns: filtered by account platform. Leads: `api_ads_lead_board(..., p_platform)`; someone who came through both
  platforms is in both lists, marked "also via …". The AI agents, rules and limits stay in Google Ads.
- Stops: "Stop everything" (`execution_paused`) stops both; each section's Settings also has "Stop Google Ads only" /
  "Stop Meta Ads only" (`google_paused` / `meta_paused`, `api_ads_platform_pause`, logged).
- Setup (Admin): a banner "N steps left → Continue" until done. Steps unlock in order, each with exact instructions and a
  **Check now** (the page also re-checks every 30 s). Meta: database (the full 100 SQL to copy + SQL editor link), Edge
  Functions (exact deploy commands; checked by `ads-sync` job `setup`, which calls `ads-intake/version`), keys, connection test,
  ad account, webhook (turns green when Meta verifies the callback URL), Page, first lead (Live mode + Lead Ads Testing Tool),
  reporting, and a test event (`meta_test_event` with a Test Events code from Events Manager). Google: database, functions,
  keys, connection test, limits, conversion action, agents. Status comes from `api_ads_setup_status` (key *presence* only).
- Deploy check: `ADS_BUILD` in `_shared/ads_meta.ts` must equal the build in `ads-intake` `/version` (a Deno test checks this);
  bump both when the Edge Functions change, so Setup can tell an old deploy apart.

Go-live order: push the frontend → open Meta Ads > Setup → follow the steps top to bottom.

## Google Ads > Premium targeting (migration 144, 2026-11-25)

Owner decision: counselling enquiries from people searching for pilot training, CPL and ground classes, in premium areas only.

- **Two campaigns.** Delhi NCR (Dwarka classroom, online as well) and Other cities (online batches and free counselling only). Google sets locations per campaign, so the offer follows the place.
- **Where.** 125 premium PIN codes in 9 big cities (Google accepts Indian PIN codes as locations) and 13 places as whole cities (Gurugram's PIN codes are not in Google's list). The approved list is in the operations' payloads.
- **Who.** Google's top 10% and 11-20% household income groups only (`income_filter`, set on the campaign). Google has no net-worth filter. "Unknown" income is shut out too, which can cut reach sharply; the gate warns about it.
- **New operations, owner only.** `campaign_create` builds a whole Search campaign in one approval and one all-or-nothing request (budget inside the spend limits, optionally moved from a running campaign, click limit, Google Search only, people physically there, locations, income filter, negative lists, ad groups, keywords, ads). `income_filter` shuts income groups out or lets them back in. An agent can propose either; they always wait for the owner.
- **Lock.** While `ads_config.google_targeting_locked` is `on`, location changes made by an agent also wait for the owner. Turn it `off` to let the Locations desk act on its own again.
- **Dry run.** `ads-google-ops` with `{"check": "<operation id>"}` asks Google to validate a waiting operation (nothing changes) and logs the answer as `google_op_dry_run`.
- **Where it runs.** `supabase/functions/ads-google-ops` (schedule `crm-ads-google-build`, every 5 minutes when something is approved). The large `ads-sync` function is unchanged and never sees the new kinds.
- **Gate.** The 099 gate lives on as `crm_private.ads_google_gate_v143`; `crm_private.ads_google_gate` is now a wrapper. Do not replace the wrapper with a full body in a later migration.
- **Budget.** The owner sets it in Google Ads > Autopilot > Spend limits (the ceiling) and Campaigns (each campaign's daily budget). The first split is 140 (Delhi NCR) + 60 (Other cities) = the 200 limit.

## Google Ads > Time-of-day bids and the verified research (migration 145, 2026-11-25)

- **`ad_schedule` (owner only).** A campaign's day in 1-6 time slots, each with its own bid change (-90% to +900%), the same every day. The slots must cover all 24 hours, because a schedule in Google Ads shows ads only inside its slots. Old rows are removed in the same request (`remove`). Runs and dry-runs in `ads-google-ops`.
- **Live now.** Both campaigns bid 30% lower from midnight to 6 am and unchanged otherwise. Review each slot by cost per CRM enquiry after 300 clicks; 56 clicks were too few to switch any hour off.
- **Tier 1 only.** Delhi NCR = 20 premium PIN codes plus Gurugram, Faridabad, Ghaziabad, Greater Noida (140 a day). Other cities = Chandigarh, Mohali, Panchkula, Punjab (60 a day). Tier 2 (Jaipur, Lucknow, Udaipur, Sonipat, Panipat) and Tier 3 (7 far metros) are paused; their PIN lists are in the 25 Nov `campaign_create` operation.
- **Phrases.** The general "aviation" and "flight" phrases are paused in both campaigns (they pulled in non-pilot searches).
- **AI team.** The research is in `ads_config.google_brand_facts` under "Verified research (25 Nov 2026 ...)": tiers, phrases, why old conversion numbers are not enquiries, price, time of day, competitors, and the loss after the click (48 hours to the first call, 30% bot forms).
- **Gate layers.** `ads_google_gate` (145: ad_schedule) -> `ads_google_gate_v144` (144: campaign_create, income_filter) -> `ads_google_gate_v143` (099: everything else). Add a layer the same way.

## Google Ads Overview: balance from Google, one daily amount (migration 146)

The Google Ads section opens on **Overview** (tabs: Overview · Ads Leads · Advanced). Everything that was under the old tabs is one tap
away under Advanced at the same address (`#/ads/today` is the detailed Today page, `#/ads/campaigns` the campaign list).

- **Balance** is read from Google, not typed. For a prepaid account Google's account budget is the running total of every payment
  (after GST) and of everything served: balance = adjusted spending limit − amount served (APPROVED, not ended rows). ads-google-ops
  `{"read":"billing"}` → `svc_ads_google_billing_save` → `ads_google_balance`; a rise of the limit is logged in `ads_google_topups`.
  Schedule `crm-ads-google-billing`: every 30 minutes, every 5 minutes for two hours after "I added money"
  (`api_ads_google_balance_refresh`, which also asks at once). A failed read keeps the last figure and records the error.
- **Daily budget**: `api_ads_google_budget_set(p_daily)` (approvers only, whole rupees 100–5000, rule `g_daily_total`) sets
  `google_cap_daily` and `google_cap_monthly` (= 30.4 days) and creates one approved owner operation `budget_set` that changes every
  switched-on campaign's budget in one Google request, shared as now (largest campaign takes the rounding). Gate layer
  `ads_google_gate` → `ads_google_gate_v145`. Verified → `ads_campaigns.daily_budget` updated; refused before anything was sent →
  limits go back; sent but not confirmed → the lower limit stays. Agents cannot create an approved `budget_set`.
- **Home read** `api_ads_google_home(p_days 7|30|90)`: status (running, starting, low_money, no_money, not_showing, paused, off,
  not_connected), money, budget and the last change, campaigns with who (income groups shut out), where (snapshot locations),
  when (verified schedule), searches; results from `ads_metrics_daily` and CRM enquiries (`ads_ad_leads`) with calls within 15
  minutes; waiting operations labelled ai / you / team. Labels and the areas not opened yet: `ads_config.google_campaign_labels`,
  `google_areas_waiting`.
- Tests: `supabase/tests/ads/home/run.sh` (HM01–HM63, HR1–HR2), `UI_SCRIPT=home_ui.mjs ui/run_ui.sh` (GH01–GH46). Rollback:
  `146_ads_google_home_down.sql`, then re-run 145.

## Not built yet

Ad groups / keywords / audiences / creatives management, offline-conversion upload (needs GCLID/FBCLID captured on website
lead forms first), Groq/Gemini summaries in ADS, the Claude remote MCP server, PDF reports, TikTok/LinkedIn/Microsoft connectors.
