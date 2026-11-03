# CRM rebuild on Supabase: audit of the current system (2026-11-03)

Source: Weone404/CRM @ origin/main 5ec3295 plus the uncommitted FlightBridge work in this folder.
Goal: every item below must exist and pass a test on Supabase before Render is switched off.

## Size
- Backend: FastAPI, `main.py` 3,514 lines + `flightbridge_routes.py` 915 lines, **117 endpoints**.
- Database: 28 tables (migrations 001-038, applied by hand in the Supabase SQL Editor).
- Frontend: Vite + React, 22 components, tabs: leads, students, tasks, attendance, team, leave, policy, profile, partnerships (FlightBridge).

## Access model today
- Staff: `employee` table, own JWT (30-day), login by login ID + optional 4-digit PIN (`/api/auth/employee-login`) or login ID + password (`/api/auth/login`).
- Roles: `department` (Admin, IT, Sales, Instructors) + `permission_level` (full_access, sales, regular).
- Students: separate JWT (`type=student`), login by mobile + PIN, own portal.
- Machine callers: shared-secret tokens: CHARTER_INGEST_TOKEN (Book My Charter), ATTENDANCE_INGEST_TOKEN (Hikvision, `?token=`), PARTNER_API_TOKEN (partner attendance lookup). `/api/leads/ingest` is public by design (websites).

## Modules and endpoints (all must be kept)
| Module | Endpoints | Notes for Supabase |
|---|---|---|
| Auth | login, employee-login, student-login, change-password, register, me, seed-admin | Supabase Auth; login-ID/phone to email lookup in an Edge Function; students as a separate role |
| Config / sync | config, sync | `config` table read via RLS |
| Leads | ingest (public), charter (token), list, contact, close, query, followup, followups/pending, reports/funnel | Edge Functions for ingest/charter; table reads via supabase-js + RLS |
| Dispositions | stats, interested, not-interested, not-reachable, callback | SQL views + RLS |
| Courses / Quotes | courses, discount, installments, quotes/generate, quotes/{id}/pdf | PDF via Edge Function (WeasyPrint not available; JS PDF lib) |
| Outbox | list, approve, mark sent | table + RLS |
| Tasks | list, create, update, delete, comments (2) | table + RLS; Realtime |
| Team / HR | employees (5), leave mark/unmark, salary report (2), leaves (3), meetings (2), birthdays | pay_scale is encrypted: needs the current ENCRYPTION_KEY to migrate |
| Policy docs | list, create, upload, search | Storage (or keep R2) + full-text search |
| Students | list, prefill-leads, get, create, update, delete, documents (3), set-pin | Storage for documents |
| Student portal | me, update me, my documents (3) | student role + RLS limited to own row |
| Attendance | ingest (token), list, override, hikvision (token), device-people (3), monthly, summary, partner by-mobile (token) | Hikvision webhook as Edge Function; device posts to a new URL |
| Background jobs | SLA check (5 min), Mongo import (60 s), attendance retention (monthly), self-ping | pg_cron + Edge Functions; self-ping not needed |
| FlightBridge | 34 endpoints: summary, approvals, outbound, evidence, suppressions, kill-switch, templates, inbox, settings, metrics, Hostinger webhook, team roles, schools, regions, automation, integrations | Same Supabase DB; shared login with flying.weoneaviation.in |

## Data that needs care during migration
- `employee.pay_scale` is Fernet-encrypted with ENCRYPTION_KEY: the key must be recovered from Render, or pay scales re-entered.
- Existing staff/student passwords and PINs are bcrypt hashes in our own tables: Supabase Auth accounts must be created for every user (bulk import with a forced reset, or keep a custom PIN check in an Edge Function).
- File storage is Cloudflare R2 (student documents, policy docs, quote PDFs): keep R2 or copy to Supabase Storage.

## Integrations to repoint at cutover
- Websites: weoneaviation.in, weoneaviation.com, pilotschool.in (POST lead), bookmycharter.in (charter token).
- Hikvision DS-K1T320EFWX terminal on the office LAN.
- MongoDB Atlas lead import.
- Frontend: crm.weoneaviation.in (Vercel project `crm`, team weone404).

## Blocker
- No API access yet to Supabase project `syytqcadmtgowckdnbqh` (the connected Supabase account only has `weone-reelstudio`).
