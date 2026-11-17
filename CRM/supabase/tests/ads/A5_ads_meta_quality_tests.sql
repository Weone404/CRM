-- 106: Meta Ads > Lead quality (QL01-04) and lead score (SC01-06). Runs after A4_.
RESET ROLE;
CREATE OR REPLACE FUNCTION pg_temp.mk(p_n int, p_answer text, p_stage text, p_source text, p_age interval DEFAULT interval '10 days') RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE lid uuid := gen_random_uuid(); aid bigint;
BEGIN
  INSERT INTO public.ads_lead (id, pipeline, name, phone_e164, stage, created_at, first_touch, first_response_at)
  VALUES (lid, 'pilot_training', 'Q Lead ' || p_n, '+91990000' || lpad(p_n::text, 4, '0'), p_stage, now() - p_age,
          '{"utm_source": "facebook", "utm_medium": "paid_social", "meta_source": "instant_form", "form_id": "777001", "meta_platform": "ig"}',
          CASE WHEN p_n % 3 = 0 THEN now() - p_age + interval '3 minutes' END);
  INSERT INTO public.ads_meta_lead_archive (external_id, source, created_time, form_id, form_name, campaign_name, name, answers, ads_lead_id)
  VALUES ('77700' || lpad(p_n::text, 8, '0'), p_source, now() - p_age, '777001', 'CPL enquiry', 'CPL test', 'Q Lead ' || p_n,
          jsonb_build_object('class12', p_answer, 'city', CASE WHEN p_n % 2 = 0 THEN 'Delhi' ELSE 'Jaipur' END), lid) RETURNING id INTO aid;
  RETURN aid;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- not enough history yet: the owner's rules only
SELECT pg_temp.mk(1, 'Yes', 'lead_created', 'crm', interval '1 hour');
SELECT pg_temp.ok((SELECT s.score = 50 AND s.band = 'warm' AND s.reasons->0->>'why' LIKE 'Only % followed leads so far%'
    FROM public.ads_lead_score s JOIN public.ads_meta_lead_archive a ON a.id = s.archive_id WHERE a.external_id = '7770000000001'),
  'SC01 a new lead is scored as it arrives; with little history the score is neutral and says why');
-- history: 15 "Yes" leads that qualified, 15 "No" leads that did not
SELECT pg_temp.mk(g, 'Yes', CASE WHEN g % 5 = 0 THEN 'admission_completed' ELSE 'qualified' END, 'csv') FROM generate_series(100, 114) g;
SELECT pg_temp.mk(g, 'No', 'lead_created', 'csv') FROM generate_series(200, 214) g;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
CREATE TEMP TABLE q AS SELECT public.api_ads_meta_lead_quality(current_date - 30, current_date, 'answer:class12') v;
SELECT pg_temp.ok((SELECT (x->>'q_rate')::numeric = 93.8 AND (x->>'leads')::int = 16 AND (x->>'customers')::int = 3 FROM q, jsonb_array_elements(v->'rows') x WHERE x->>'value' = 'Yes')
  AND (SELECT (x->>'q_rate')::numeric = 0 FROM q, jsonb_array_elements(v->'rows') x WHERE x->>'value' = 'No')
  AND (SELECT v->'answer_keys' @> '[{"key": "class12"}]' FROM q), 'QL01 quality by a lead-form answer: qualified and admission rates per answer');
SELECT pg_temp.ok((SELECT bool_or(x->>'value' = '1. within 5 min') AND bool_or(x->>'value' = 'not called yet') FROM jsonb_array_elements(public.api_ads_meta_lead_quality(current_date - 30, current_date, 'speed')->'rows') x)
  AND (SELECT bool_or(x->>'value' = 'Instagram') FROM jsonb_array_elements(public.api_ads_meta_lead_quality(current_date - 30, current_date, 'platform')->'rows') x)
  AND (SELECT bool_or(x->>'value' = 'CPL enquiry') FROM jsonb_array_elements(public.api_ads_meta_lead_quality(current_date - 30, current_date, 'form')->'rows') x),
  'QL02 by time to first call, platform and form');
SELECT pg_temp.ok((SELECT bool_and((x->>'small')::boolean = ((x->>'known')::int < 10)) FROM jsonb_array_elements(public.api_ads_meta_lead_quality(current_date - 30, current_date, 'answer:city')->'rows') x),
  'QL03 small groups are flagged');
SELECT pg_temp.fails($q$SELECT public.api_ads_meta_lead_quality(current_date - 30, current_date, 'drop table')$q$, '%Unknown grouping%', 'QL04 only known groupings');
RESET ROLE;
SELECT pg_temp.mk(2, 'Yes', 'lead_created', 'crm', interval '5 minutes');
SELECT pg_temp.mk(3, 'No', 'lead_created', 'crm', interval '5 minutes');
SELECT pg_temp.ok((SELECT s.score FROM public.ads_lead_score s JOIN public.ads_meta_lead_archive a ON a.id = s.archive_id WHERE a.external_id = '7770000000002')
    > (SELECT s.score FROM public.ads_lead_score s JOIN public.ads_meta_lead_archive a ON a.id = s.archive_id WHERE a.external_id = '7770000000003') + 20
  AND (SELECT bool_or(r->>'why' LIKE 'Answer "class12" Yes: % past leads qualified%') FROM public.ads_lead_score s JOIN public.ads_meta_lead_archive a ON a.id = s.archive_id,
         jsonb_array_elements(s.reasons) r WHERE a.external_id = '7770000000002'),
  'SC02 the score learns from past leads (smoothed) and says why');
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_lead_score_save('[]', 60, 35)$q$, '%Admin%', 'SC03 only Admin sets score rules');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails($q$SELECT public.api_ads_lead_score_save('[{"field": "answer:class12", "op": "is", "value": "No", "points": 10}]', 60, 35)$q$, '%Each rule needs%', 'SC04 rules are checked');
SELECT pg_temp.fails($q$SELECT public.api_ads_lead_score_save('[]', 30, 35)$q$, '%Hot must be above warm%', 'SC04b band limits are checked');
SELECT pg_temp.ok((public.api_ads_lead_score_save('[{"field": "answer:city", "op": "contains", "value": "jaip", "points": -10}, {"field": "answer:class12", "op": "equals", "value": "no", "points": 30}]', 70, 40)->>'rescored')::int >= 33,
  'SC05 saving rules rescores the last 30 days');
SELECT pg_temp.ok((SELECT bool_or(r->>'why' LIKE 'Your rule: answer class12 equals "no" (+30)') FROM jsonb_array_elements(public.api_ads_meta_scored_leads(7)) x,
    jsonb_array_elements(x->'reasons') r WHERE x->>'name' = 'Q' AND x->>'campaign' = 'CPL test' AND (x->>'score')::int > 40)
  AND (SELECT r->'rules'->0->>'points' = '-10' AND (r->>'hot')::int = 70 FROM public.api_ads_lead_score_settings() r),
  'SC05b rules add their points and show as reasons');
RESET ROLE;
CREATE TEMP TABLE sc_ids AS SELECT array_agg(ads_lead_id) a, (array_agg(ads_lead_id::text) FILTER (WHERE external_id = '7770000000002'))[1] one FROM public.ads_meta_lead_archive WHERE external_id LIKE '777%';
GRANT SELECT ON sc_ids TO authenticated;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT jsonb_typeof(r) = 'object' AND r ? sc_ids.one FROM sc_ids, public.api_ads_lead_scores(sc_ids.a) r)
  AND (SELECT jsonb_array_length(r) >= 3 AND r->0->>'called' = 'false' FROM public.api_ads_meta_scored_leads(7) r),
  'SC06 scores for the lead lists; newest scored leads, uncalled first');
RESET ROLE;
\echo ALL ADS META 106 TESTS PASSED
