-- 142 ADS > Today: notice when Google Ads stops showing, and say the most likely reason in plain words.
-- Why: from 16 Nov 2026 the only live campaign spent nothing for nine days while Google still called it "eligible". Google's
-- campaign status has no value for "the prepaid balance is used up", and the Google Ads API has no field for the balance of a
-- prepaid account, so nothing in the CRM said why. This reads only what the CRM already has:
--   stopped   a campaign is switched on with a budget, the account syncs, and for 2+ complete days there was no spend and
--             under a tenth of the usual impressions
--   funds     the money ledger (ads_funds) says the balance is used up, OR the spend of the current run plus tax lands within
--             INR 1 of a round payment (847.37 + 18% GST = 999.90), which is what a used-up prepayment looks like
--   unknown   stopped, with no sign of the reason: the screen says so and lists what was checked
-- It never changes anything. Tax: ads_config.google_tax_pct (default 18 for INR accounts, 0 otherwise). Re-runnable. Needs 093.

CREATE OR REPLACE FUNCTION crm_private.ads_google_delivery() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_accounts; d date; last_spend date; quiet int; busy numeric; recent numeric; budget numeric; run_start date; run_spend numeric;
        tax numeric; gross numeric; pay numeric; near boolean := false; added numeric; f0 date; est numeric; changes int; changes_next int; cause text := NULL;
        ev text[] := '{}'; stopped boolean; cur text; off jsonb := jsonb_build_object('stopped', false);
BEGIN
  a := crm_private.ads_google_account();
  IF a.id IS NULL OR a.status IS DISTINCT FROM 'connected' THEN RETURN off; END IF;
  IF a.last_ok_at IS NULL OR a.last_ok_at < now() - interval '36 hours' THEN RETURN off || jsonb_build_object('stale', true); END IF;   -- old data proves nothing
  d := crm_private.ads_google_today();
  cur := coalesce(a.currency, 'INR');
  SELECT coalesce(sum(c.daily_budget), 0) INTO budget FROM public.ads_campaigns c WHERE c.account_id = a.id AND c.status = 'ENABLED';
  SELECT max(m.day) INTO last_spend FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
   WHERE c.account_id = a.id AND m.spend > 0 AND m.day < d;
  IF budget <= 0 OR last_spend IS NULL THEN RETURN off; END IF;            -- nothing switched on, or it never ran: not a stop
  quiet := (d - 1) - last_spend;                                           -- complete days without any spend
  IF quiet < 2 OR crm_private.ads_google_spend(d, d) > 0 THEN RETURN off; END IF;      -- a single quiet day is normal; spending again today means it is over
  -- the current run: spending days with no gap longer than a week before the stop
  SELECT coalesce(max(g.day) FILTER (WHERE g.gap > 7), min(g.day)) INTO run_start FROM (
    SELECT s.day, s.day - lag(s.day) OVER (ORDER BY s.day) AS gap FROM (
      SELECT m.day FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
       WHERE c.account_id = a.id AND m.day <= last_spend GROUP BY m.day HAVING sum(m.spend) > 0) s) g;
  -- what "usual" means: the last spending days of this run (up to 7), not an older campaign months ago
  SELECT avg(z.impr) INTO busy FROM (
    SELECT sum(m.impressions) AS impr FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
     WHERE c.account_id = a.id AND m.day BETWEEN run_start AND last_spend GROUP BY m.day HAVING sum(m.spend) > 0 ORDER BY m.day DESC LIMIT 7) z;
  SELECT coalesce(sum(m.impressions), 0)::numeric / quiet INTO recent FROM public.ads_metrics_daily m JOIN public.ads_campaigns c ON c.id = m.campaign_id
   WHERE c.account_id = a.id AND m.day > last_spend AND m.day < d;
  stopped := coalesce(busy, 0) >= 50 AND recent < busy * 0.1;
  IF NOT stopped THEN RETURN off; END IF;

  run_spend := crm_private.ads_google_spend(run_start, last_spend);
  tax := coalesce(nullif(crm_private.ads_cfg('google_tax_pct'), '')::numeric, CASE WHEN cur = 'INR' THEN 18 ELSE 0 END);
  gross := round(run_spend * (1 + tax / 100), 2);
  pay := ceil(gross / 100) * 100;
  near := gross >= 100 AND pay - gross <= 1;
  SELECT min(added_on), sum(amount) INTO f0, added FROM public.ads_funds WHERE account_id = a.id;
  IF f0 IS NOT NULL THEN est := added - crm_private.ads_google_spend(f0, d); END IF;
  -- what the CRM itself changed around the stop: on the last day with spend, and on the day after
  SELECT count(*) FILTER (WHERE x.day = last_spend), count(*) FILTER (WHERE x.day = last_spend + 1) INTO changes, changes_next FROM (
    SELECT (o.executed_at AT TIME ZONE coalesce(a.timezone, 'Asia/Kolkata'))::date AS day FROM public.ads_google_ops o
     WHERE o.account_id = a.id AND o.status IN ('verified', 'outcome_unknown') AND o.executed_at IS NOT NULL) x;

  ev := ev || format('It was shown about %s times a day before; since then about %s.', round(busy), round(recent))::text;
  ev := ev || format('A campaign is switched on with %s %s a day, and Google gives no reason for the stop.', cur, trim(to_char(budget, 'FM999G999G990')))::text;
  IF est IS NOT NULL AND est <= budget * 0.25 THEN
    cause := 'funds';
    ev := ev || format('Money recorded in the CRM: %s %s added since %s, all of it spent.', cur, trim(to_char(added, 'FM999G999G990')), to_char(f0, 'FMDD Mon'))::text;
  ELSIF near THEN
    cause := 'funds';
    ev := ev || format('Spend from %s to %s is %s %s. With %s%% tax that is %s, almost exactly one payment of %s %s.', to_char(run_start, 'FMDD Mon'), to_char(last_spend, 'FMDD Mon'),
      cur, trim(to_char(run_spend, 'FM999G999G990D00')), CASE WHEN tax = trunc(tax) THEN trunc(tax)::text ELSE tax::text END, trim(to_char(gross, 'FM999G999G990D00')), cur, trim(to_char(pay, 'FM999G999G990')))::text;
  ELSE
    cause := 'unknown';
    IF est IS NOT NULL THEN ev := ev || format('The money recorded in the CRM still shows about %s %s, so the balance may not be the reason.', cur, trim(to_char(greatest(est, 0), 'FM999G999G990')))::text; END IF;
  END IF;
  ev := ev || CASE WHEN changes > 0 THEN format('The CRM made %s change(s) in the account on %s, the last day with spend (ADS > Activity).', changes, to_char(last_spend, 'FMDD Mon'))
                   WHEN changes_next > 0 THEN format('The CRM changed nothing on %s, the last day with spend; it made %s change(s) the next day.', to_char(last_spend, 'FMDD Mon'), changes_next)
                   ELSE format('The CRM changed nothing in the account on %s or the day after.', to_char(last_spend, 'FMDD Mon')) END;
  RETURN jsonb_build_object('stopped', true, 'cause', cause, 'since', last_spend + 1, 'last_spend_day', last_spend, 'quiet_days', quiet,
    'usual_impressions', round(busy), 'recent_impressions', round(recent), 'daily_budget', budget, 'currency', cur, 'tax_pct', tax,
    'run', jsonb_build_object('from', run_start, 'spend', run_spend, 'with_tax', gross, 'payment', pay, 'matches_payment', near),
    'has_ledger', f0 IS NOT NULL, 'estimate', est, 'crm_changes', changes, 'crm_changes_next_day', changes_next, 'evidence', to_jsonb(ev),
    'topup_30d', ceil(budget * 30 * (1 + tax / 100) / 100) * 100);
END $$;

-- For ADS > Today. Anyone who can see ADS.
CREATE OR REPLACE FUNCTION public.api_ads_delivery() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN crm_private.ads_google_delivery();
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_google_delivery() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_delivery() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_delivery() TO authenticated;
