-- What the live database holds before 146: the account, its two running campaigns, the limits, and the first balance read.
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES ('00000000-0000-0000-0000-00000000000c', false);
INSERT INTO public.ads_clients (id, name) VALUES ('c1460000-0000-4000-8000-000000000001', 'We One Aviation');
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, status, last_ok_at) VALUES
  ('a1460000-0000-4000-8000-000000000001', 'c1460000-0000-4000-8000-000000000001', 'google', '6318538100', 'We One', 'INR', 'Asia/Kolkata', 'connected', now());
INSERT INTO public.ads_campaigns (account_id, external_id, name, status, daily_budget, budget_ref) VALUES
  ('a1460000-0000-4000-8000-000000000001', '24283129095', 'We-Aviation-Search-sep-2026', 'ENABLED', 140, 'customers/6318538100/campaignBudgets/15901873674'),
  ('a1460000-0000-4000-8000-000000000001', '24542430627', 'WOA | Search | Other cities | Online | Nov26', 'ENABLED', 60, 'customers/6318538100/campaignBudgets/16106833427'),
  ('a1460000-0000-4000-8000-000000000001', '111', 'Old campaign', 'PAUSED', 700, 'customers/6318538100/campaignBudgets/111');
INSERT INTO public.ads_config (key, value) VALUES ('google_cap_daily', '200'), ('google_cap_monthly', '6080'), ('autopilot_google', 'auto'),
  ('google_brand_facts', 'We One Aviation, pilot training institute in Dwarka, New Delhi.')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
-- the read of 25 Nov 2026, exactly as Google answered it (10:55 UTC)
INSERT INTO public.ads_google_snapshot (account_id, kind, data, synced_at) VALUES ('a1460000-0000-4000-8000-000000000001', 'billing',
  '{"billing_setup": [{"billingSetup.id": "7540443912", "billingSetup.status": "APPROVED"}],
    "account_budget": [{"accountBudget.id": "7540703255", "accountBudget.status": "APPROVED", "accountBudget.amountServedMicros": "170552220000",
      "accountBudget.approvedStartDateTime": "2025-01-18 15:26:24", "accountBudget.totalAdjustmentsMicros": "43840000",
      "accountBudget.adjustedSpendingLimitMicros": "170552310000", "accountBudget.approvedSpendingLimitMicros": "170508470000"}]}', '2026-11-25 10:55:15+00');
