-- 105: Meta Ads > Reports (RP01-06) and account health / warnings (HL01-07). Runs after A3_.
RESET ROLE;
-- ---------------------------------------------------------------- reports
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT r->'account'->>'id' = '564511644492586' AND jsonb_array_length(r->'campaigns') >= 2 AND jsonb_array_length(r->'ads') >= 2
    AND r->'views' = '[]'::jsonb AND NOT (r->>'can_admin')::boolean FROM public.api_ads_meta_report_options() r),
  'RP01 viewers get the account, campaigns, ad sets, ads and forms to filter by');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_report_view_save(NULL, '  ', '{}', false)$q$, '%name%', 'RP02 a view needs a name');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_report_view_save(NULL, 'Mine', '{}', true)$q$, '%Only Admin shares%', 'RP02b only Admin shares a view');
SELECT public.api_ads_meta_report_view_save(NULL, 'My CPL view', '{"report": {"level": "ad"}, "ui": {"preset": "leads"}}', false);
SELECT pg_temp.ok((SELECT jsonb_array_length(r->'views') = 1 AND (r->'views'->0->>'mine')::boolean FROM public.api_ads_meta_report_options() r), 'RP03 a saved view is listed for its owner');
SELECT pg_temp.as_('a');
SELECT public.api_ads_meta_report_view_save(NULL, 'Team weekly', '{"report": {"level": "campaign"}}', true);
SELECT pg_temp.ok((SELECT jsonb_array_length(r->'views') = 1 AND r->'views'->0->>'name' = 'Team weekly' FROM public.api_ads_meta_report_options() r),
  'RP03b another person''s private view is not shown; shared views are');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((SELECT jsonb_array_length(r->'views') = 2 FROM public.api_ads_meta_report_options() r), 'RP03c everyone sees shared views');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_report_view_delete((SELECT (v->>'id')::bigint FROM jsonb_array_elements(public.api_ads_meta_report_options()->'views') v WHERE v->>'name' = 'Team weekly'))$q$,
  '%not found%', 'RP04 a viewer cannot delete someone else''s view');
SELECT pg_temp.ok((SELECT (r->'7001'->>'crm')::int >= 0 FROM public.api_ads_meta_report_crm(current_date - 400, current_date, 'campaign') r)
  AND (SELECT jsonb_typeof(r) = 'object' FROM public.api_ads_meta_report_crm(current_date - 30, current_date, 'ad') r), 'RP05 CRM results per campaign / ad for a period');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_report_crm(current_date, current_date, 'region')$q$, '%Unknown level%', 'RP05b only known levels');
RESET ROLE; SET ROLE service_role;
SELECT public.svc_ads_meta_report_cache_put('k1', '{"level": "ad"}', '{"rows": [1]}', 3);
SELECT public.svc_ads_meta_report_cache_put('k2', '{"level": "ad"}', '{"rows": [2]}', 3);
RESET ROLE; UPDATE public.ads_meta_report_cache SET expires_at = now() - interval '1 minute' WHERE key = 'k2'; SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_meta_report_cache_get('k1')->>'cached')::boolean AND public.svc_ads_meta_report_cache_get('k1')->'rows' = '[1]'
  AND public.svc_ads_meta_report_cache_get('k2') IS NULL, 'RP06 cached answers are served until they expire');
RESET ROLE; SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.svc_ads_meta_report_cache_get('k1')$q$, '%permission denied%', 'RP06b the cache is closed to browsers');
RESET ROLE;

-- ---------------------------------------------------------------- health and warnings
UPDATE public.ads_meta_lead_raw SET last_try_at = now() - interval '2 days', received_at = now() - interval '2 days' WHERE status = 'failed';   -- earlier tests' failures
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_agents_meta_waiting() = EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE status = 'queued' AND role LIKE 'meta\_%'),
  'HL01 ads-agents can tell whether a Meta step is waiting (to update an older helper)');
DELETE FROM j; INSERT INTO j SELECT public.svc_ads_meta_health_save('{"opportunity": {"score": 62}, "yesterday": {"leads": 5}}',
  '[{"kind": "ad_rejected", "entity": "9001", "severity": "high", "title": "Ad rejected: Reel", "detail": "Policy"},
    {"kind": "cpl_up", "entity": "account", "severity": "medium", "title": "Cost per lead up 40%"}]');
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'notify') = 2 AND v->'notify' @> '[{"kind": "webhook_silent"}]' AND v->'notify' @> '[{"kind": "ad_rejected"}]'
    AND v->'emails' ? 'admin@example.com' FROM j), 'HL02 new high warnings (and a silent webhook: Meta counted 5, the CRM got none) are sent to Admin');
SELECT public.svc_ads_meta_warnings_notified((SELECT array_agg((x->>'id')::bigint) FROM j, jsonb_array_elements(v->'notify') x));
DELETE FROM j; INSERT INTO j SELECT public.svc_ads_meta_health_save('{"opportunity": {"score": 70}, "yesterday": {"leads": 0}}',
  '[{"kind": "ad_rejected", "entity": "9001", "severity": "high", "title": "Ad rejected: Reel", "detail": "Policy"}]');
RESET ROLE;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'notify') = 0 FROM j)
  AND (SELECT count(*) = 1 FROM public.ads_meta_warning WHERE kind = 'ad_rejected' AND resolved_at IS NULL)
  AND (SELECT resolved_at IS NOT NULL FROM public.ads_meta_warning WHERE kind = 'cpl_up')
  AND (SELECT resolved_at IS NOT NULL FROM public.ads_meta_warning WHERE kind = 'webhook_silent'),
  'HL03 a warning seen again is not sent twice; ones no longer found close by themselves');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT r->'latest'->'data'->'opportunity'->>'score' = '70' AND jsonb_array_length(r->'warnings') = 1
    AND jsonb_array_length(r->'score_trend') >= 1 AND (r->>'resolved_7d')::int = 2 FROM public.api_ads_meta_health() r),
  'HL04 viewers see the latest health, the score trend and open warnings');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_warning_dismiss((SELECT id FROM public.ads_meta_warning LIMIT 1))$q$, '%', 'HL05 viewers cannot dismiss warnings');
RESET ROLE;
SELECT pg_temp.as_('a'); SET ROLE authenticated;
SELECT public.api_ads_meta_warning_dismiss((SELECT (w->>'id')::bigint FROM jsonb_array_elements(public.api_ads_meta_health()->'warnings') w LIMIT 1));
SELECT pg_temp.ok((SELECT (r->'warnings'->0->>'dismissed')::boolean FROM public.api_ads_meta_health() r), 'HL06 Admin can dismiss a warning (it stays listed as dismissed)');
RESET ROLE;
UPDATE public.ads_meta_lead_raw SET status = 'failed', last_try_at = now() WHERE id = (SELECT min(id) FROM public.ads_meta_lead_raw WHERE status <> 'failed');
SET ROLE service_role;
SELECT public.svc_ads_meta_health_save('{}', '[]');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.ads_meta_warning WHERE kind = 'lead_errors' AND resolved_at IS NULL)
  AND (SELECT count(*) = 1 FROM public.ads_meta_warning WHERE kind = 'ad_rejected' AND resolved_at IS NOT NULL),
  'HL07 leads that fail to file raise a warning; an empty check closes the rest');
\echo ALL ADS META 105 TESTS PASSED
