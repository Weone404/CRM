# WhatsApp module (sidebar > Growth > WhatsApp)

Automatic WhatsApp for every new lead, on Meta's WhatsApp Cloud API only (no third-party provider). Migration 150.

## What happens

1. **A lead lands** in `lead` (websites, Book My Charter, JustDial, imports) or `ads_lead` (Meta/Google ads).
   An `AFTER INSERT` trigger makes one WhatsApp contact per phone number (all sources), one chat per brand, and queues
   **one** welcome (never twice, and not again within 30 days). The trigger body is wrapped in `BEGIN ... EXCEPTION`,
   so a WhatsApp problem can never block or roll back a lead (tested: W28, W30).
2. **The welcome template** goes out within seconds (the trigger wakes `wa-worker`; pg_cron also runs it every minute):
   Aviation, Charter or JustDial template, with quick-reply buttons.
3. **Replies** reach `wa-webhook` through the Cloudflare gateway. The flow (Flow & replies) answers from the database:
   STOP first, then the step's buttons, then rules (button > exact > contains > similar word; current step first,
   then any step), then a typed answer if the step asks a question (e.g. city). Not understood twice, a question after
   the flow ended, fees, "call me", or "book counselling": **a person takes over** (phone alert, note on the lead).
4. **Follow-ups** (marketing templates) only to people who never replied, at 24 h and 72 h by default, never in quiet
   hours (20:00–09:00 IST), at most 2.
5. **Inbox**: every chat, take over / hand back / close, type (inside 24 h), templates (any time), brochure, notes.
   The lead window shows a read-only WhatsApp panel with "Open chat".

Every sending rule lives in one place, `svc_wa_claim`: Pause all, Test mode / not live, opt-outs, the person having
taken over, quiet hours, the daily cap on new people, and the 24-hour window.

## Facts it is built on (checked 27 Nov 2026)

- Outside 24 h of the person's last message only approved templates can be sent.
- India, from 1 Oct 2026: marketing ₹0.8631, utility/authentication ₹0.115 per delivered message; replies in the
  window are charged too (1,000 free per number per month); GST extra. Click-to-WhatsApp ad chats are free for 72 h.
- New business portfolios can start 250 new people per 24 h (2,000 after business verification); cap set to 200.
- Meta limits marketing templates per person (error 131049: do not retry for 24 h).
- Meta re-sends a webhook that did not get a 200 for up to 7 days, and can send it twice.
- General-purpose AI chatbots are banned on the API since 15 Jan 2026; this bot is a business flow from the database.

## Pieces

| Where | What |
|---|---|
| `backend/migrations/150_whatsapp.sql` | tables `wa_*`, triggers, `svc_wa_*` (Edge Functions), `api_wa_*` (CRM), starter flow/templates, cron |
| `backend/migrations/150_whatsapp_down.sql` | removes everything above (Leads untouched; Vault keys kept) |
| `supabase/functions/_shared/wa.ts` | flow engine, Meta payloads, webhook parsing, error rules (pure, unit-tested) |
| `supabase/functions/_shared/wa_run.ts` | runs it against the database and Meta (send, process, media, phone alerts) |
| `supabase/functions/wa-webhook` | Meta's callback (signature check, store once, 200, process) |
| `supabase/functions/wa-worker` | every minute: retry stored webhooks, follow-ups, send due, alerts |
| `supabase/functions/wa-admin` | Setup checks, subscribe, register, templates, Inbox send, test send, simulator |
| `tools/wa-gateway` | Cloudflare Worker + D1: answers Meta, keeps a copy, re-sends to the CRM for 7 days |
| `frontend/src/components/WhatsApp.jsx`, `whatsapp/*` | the section; `LeadWhatsApp.jsx` is the lead-window panel |

Secrets: Supabase Vault `wa_access_token`, `wa_app_secret`, `wa_verify_token` (saved from WhatsApp > Setup, never
returned). IDs (Phone number ID, WABA ID, App ID) in `wa_number`. Graph API version: `ads_config.meta_api_version`.
Access: Admin, plus people granted in WhatsApp > Settings (Chats, or Chats + Manage).

## Going live (by hand, once)

1. **Database**: Supabase > SQL Editor: paste and run `backend/migrations/150_whatsapp.sql`.
2. **Functions** (from the `CRM/CRM` folder):
   ```
   npx -y supabase@latest functions deploy wa-webhook --no-verify-jwt --use-api --remote=syytqcadmtgowckdnbqh --yes
   npx -y supabase@latest functions deploy wa-worker --no-verify-jwt --use-api --remote=syytqcadmtgowckdnbqh --yes
   npx -y supabase@latest functions deploy wa-admin --use-api --remote=syytqcadmtgowckdnbqh --yes
   ```
   (`wa-worker` checks the cron token itself; `wa-webhook` checks Meta's signature.)
3. **Cloudflare gateway** (folder `tools/wa-gateway`):
   ```
   npx wrangler login
   npx wrangler d1 create weone-wa-gateway          # put the database_id into wrangler.toml
   npx wrangler d1 execute weone-wa-gateway --remote --file=schema.sql
   npx wrangler secret put APP_SECRET               # the Meta App Secret
   npx wrangler deploy
   ```
   Paste the printed `https://weone-wa-gateway.<you>.workers.dev` into WhatsApp > Setup > step g.
   Free plan: 100,000 requests and 100,000 D1 row writes a day (about 30,000 WhatsApp events a day).
4. **WhatsApp > Setup** in the CRM: steps a–k, each with "Check now". Then Settings > Live (Test mode first).

## Tests

```
cd CRM/supabase/tests/wa
PGHOST=... PGPORT=... PGUSER=postgres ./run.sh                    # 96 SQL checks incl. the down migration
node --experimental-strip-types --test wa.test.ts                 # 28 engine / Meta / webhook checks
node ../../../tools/wa-gateway/test.mjs                           # 8 gateway checks
# UI: phone 390 / tablet 820 / laptop 1440 in headless Chromium (79 checks, screenshots in /tmp/wa_ui_*.png)
PGHOST=... PGPORT=... PGUSER=postgres PG_MODULE_DIR=<node_modules with pg> PLAYWRIGHT_DIR=<node_modules with playwright> ./ui/run_ui.sh
```

## Rollback

Run `150_whatsapp_down.sql` (deletes WhatsApp chats and settings; Leads keep working exactly as before), delete the
three functions in Supabase, and `npx wrangler delete` in `tools/wa-gateway`. To only stop messages: Settings > Pause
everything (instant) or turn Live off.
