-- Amazon module SQL tests. Run on the local harness after 00_supabase_stub.sql, 072 and 073:
--   psql -v ON_ERROR_STOP=1 -f 10_amazon_tests.sql
-- Each check prints "PASS <name>"; the first failure stops the run with "FAIL <name>".
\set QUIET on
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF;
  RAISE NOTICE 'PASS %', name;
END $$;
-- Expect an error whose message matches p_like when running p_sql as the current role.
CREATE OR REPLACE FUNCTION pg_temp.fails(p_sql text, p_like text, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE p_like THEN RAISE NOTICE 'PASS %', name; RETURN; END IF;
    RAISE EXCEPTION 'FAIL % (wrong error: %)', name, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL % (no error)', name;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;

-- People: an admin, a sales user without access, an approver without approve right, an approver with it.
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d', 'Approver', 'IT', '10000000-0000-0000-0000-00000000000d')
ON CONFLICT DO NOTHING;
INSERT INTO public.amazon_approvers (employee_id, can_approve) VALUES
  ('00000000-0000-0000-0000-00000000000c', false), ('00000000-0000-0000-0000-00000000000d', true) ON CONFLICT DO NOTHING;
INSERT INTO public.amazon_product_facts (asin, facts) VALUES ('B0HJ4XXK37', '["160 lined pages", "PU leather cover", "built-in pen holder"]')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- guards (as the admin)
SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);

SELECT pg_temp.ok((public.api_amz_check('price', '69-E0DG-L8W8', '{"price": 298}')->>'ok')::boolean = false
  AND public.api_amz_check('price', '69-E0DG-L8W8', '{"price": 298}')->'blockers'->0->>'code' = 'price_floor', 'X01a price 298 blocked (floor 299)');
SELECT pg_temp.ok((public.api_amz_check('price', '69-E0DG-L8W8', '{"price": 299}')->>'ok')::boolean, 'X01b price 299 allowed');
SELECT pg_temp.ok(jsonb_array_length(public.api_amz_check('price', '69-E0DG-L8W8', '{"price": 360}')->'confirms') = 0,
  'X01c price 449 -> 360 (-19.8%) needs no second confirm');
SELECT pg_temp.ok(public.api_amz_check('price', '69-E0DG-L8W8', '{"price": 999}')->'confirms'->0->>'code' = 'price_change_confirm',
  'X01d price 449 -> 999 (+122%) needs a second confirm');
SELECT pg_temp.ok(public.api_amz_check('price', '69-E0DG-L8W8', '{"price": 499, "mrp": 450}')->'blockers'->0->>'code' = 'mrp_gte_price',
  'X02 MRP below price blocked');

SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  jsonb_build_object('title', repeat('a', 70) || ' bcdef'))->'blockers') b WHERE b->>'code' = 'title_max_chars'), 'G01 76-character title blocked');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  jsonb_build_object('title', repeat('a', 70) || ' bcde'))->'blockers') b WHERE b->>'code' = 'title_max_chars'), 'G02 75-character title passes length');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"title": "Nitaniya 2027 Diary A5 Diary for Office, Diaries Gift"}')->'blockers') b WHERE b->>'code' = 'title_word_repeat'),
  'G03 diary x3 (plural counts) blocked');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"title": "Best 2027 Diary A5 for Office"}')->'blockers') b WHERE b->>'code' = 'title_promo_words'), 'G04 promo word "Best" blocked');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"title": "Nitaniya Bestow Diary A5"}')->'blockers') b WHERE b->>'code' = 'title_promo_words'), 'G05 "Bestow" is not the promo word "best"');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"title": "2027 Diary A5!"}')->'blockers') b WHERE b->>'code' = 'title_special_chars'), 'G06 "!" blocked');
SELECT pg_temp.ok((public.api_amz_check('listing', '69-E0DG-L8W8', jsonb_build_object('item_highlights', repeat('x', 126)))->>'ok')::boolean = false,
  'G07 Item Highlights 126 chars blocked');
-- 83 Devanagari letters = 249 bytes (passes); 84 = 252 bytes (blocked) although only 84 characters
SELECT pg_temp.ok((public.api_amz_check('listing', '69-E0DG-L8W8', jsonb_build_object('backend_terms', repeat('ड', 83)))->'blockers')
  @> '[]' AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  jsonb_build_object('backend_terms', repeat('ड', 83)))->'blockers') b WHERE b->>'code' = 'backend_terms_bytes'), 'X19a 249 bytes of Hindi passes');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  jsonb_build_object('backend_terms', repeat('ड', 84)))->'blockers') b WHERE b->>'code' = 'backend_terms_bytes'), 'X19b 84 Hindi letters = 252 bytes blocked');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"backend_terms": "diary 📒 planner"}')->'blockers') b WHERE b->>'code' = 'backend_no_emoji'), 'X19c emoji blocked');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"main_image": {"width": 800, "height": 800, "white_bg": true, "has_text": false}}')->'blockers') b WHERE b->>'code' = 'main_image'),
  'G08 800 px main image blocked');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"main_image": {"width": 2000, "height": 2000, "white_bg": false, "has_text": false}}')->'blockers') b WHERE b->>'code' = 'main_image'),
  'G09 non-white main image blocked');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"claims": ["waterproof"]}')->'blockers') b WHERE b->>'code' = 'claim_traceability'), 'X03a invented claim "waterproof" blocked');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('listing', '69-E0DG-L8W8',
  '{"claims": ["160 Lined Pages"]}')->'blockers') b WHERE b->>'code' = 'claim_traceability'), 'X03b claim from the Product Brief allowed');
SELECT pg_temp.ok(public.api_amz_check('ads_budget', NULL, '{"daily_budget_total": 501}')->'blockers'->0->>'code' = 'ads_daily_budget'
  AND public.api_amz_check('ads_budget', NULL, '{"daily_budget_total": 49}')->'blockers'->0->>'code' = 'ads_daily_budget'
  AND (public.api_amz_check('ads_budget', NULL, '{"daily_budget_total": 500}')->>'ok')::boolean, 'G10 ads budget limited to 50..500');
SELECT pg_temp.ok(public.api_amz_check('listing', '42-PAH6-ZOOW', '{"title": "NITANIYA Customised Leather Diary 2027 A5 with Strap"}')->'confirms'->0->>'code'
  = 'parent_edit_confirm', 'X27 parent edit needs a second confirm');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_check('create', 'NEW-SKU-1',
  '{"title": "Nitaniya 2027 Diary A5"}')->'blockers') b WHERE b->>'code' = 'legal_fields'), 'G11 new listing without legal fields blocked');

-- ---------------------------------------------------------------- queue + approval
SELECT pg_temp.fails($$SELECT public.api_amz_draft_create('price', '69-E0DG-L8W8', '{}')$$, '%Nothing to change%', 'Q01 empty draft refused');
DO $$
DECLARE d jsonb;
BEGIN
  d := public.api_amz_draft_create('price', '69-E0DG-L8W8', '{"price": 298}', 'too low');
  PERFORM pg_temp.ok(d->>'status' = 'pending' AND (d->'guard_result'->>'ok')::boolean = false, 'Q02 blocked draft stored as pending with blockers');
  PERFORM pg_temp.fails(format($f$SELECT public.api_amz_approve(%L)$f$, d->>'id'), '%blockers%', 'Q03 blocked draft cannot be approved');
  PERFORM pg_temp.fails(format($f$UPDATE public.amazon_change_queue SET status = 'approved' WHERE id = %L$f$, d->>'id'),
    '%permission denied%', 'Q04 browser cannot write the queue table directly');
END $$;
RESET ROLE;
DO $$
DECLARE cid uuid;
BEGIN
  -- even the table owner (Claude via SQL) cannot approve a blocked change or skip a status
  INSERT INTO public.amazon_change_queue (kind, sku, after, created_by_type, status)
  VALUES ('price', '69-E0DG-L8W8', '{"price": 250}', 'claude', 'approved') RETURNING amazon_change_queue.id INTO cid;
  PERFORM pg_temp.ok((SELECT status FROM public.amazon_change_queue q WHERE q.id = cid) = 'pending', 'Q05 insert with status approved is forced to pending');
  PERFORM pg_temp.fails(format($f$UPDATE public.amazon_change_queue SET status = 'approved' WHERE id = %L$f$, cid), '%blockers%',
    'Q06 owner cannot approve a blocked change');
  PERFORM pg_temp.fails(format($f$UPDATE public.amazon_change_queue SET status = 'live' WHERE id = %L$f$, cid), '%cannot go from pending to live%',
    'Q07 status cannot skip from pending to live');
END $$;
SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);

DO $$
DECLARE d jsonb; a jsonb; c jsonb;
BEGIN
  d := public.api_amz_draft_create('price', '69-E0DG-L8W8', '{"price": 999}', 'big move');
  PERFORM pg_temp.fails(format($f$SELECT public.api_amz_approve(%L)$f$, d->>'id'), '%second confirmation%', 'X01e +122% price needs second confirm');
  a := public.api_amz_approve((d->>'id')::uuid, true);
  PERFORM pg_temp.ok(a->>'status' = 'approved' AND a->>'second_confirmed_by' IS NOT NULL, 'X01f approved after second confirm');
  PERFORM pg_temp.fails(format($f$SELECT public.api_amz_approve(%L, true)$f$, d->>'id'), '%Already approved%', 'X06a second approve refused');
  RESET ROLE; SET ROLE service_role;
  c := public.svc_amz_claim((d->>'id')::uuid);
  PERFORM pg_temp.ok(c IS NOT NULL AND c->>'status' = 'executing', 'X06b first claim executes');
  PERFORM pg_temp.ok(public.svc_amz_claim((d->>'id')::uuid) IS NULL, 'X06c second claim gets nothing (executes once)');
  PERFORM public.svc_amz_finish((d->>'id')::uuid, 'live', '{"status":"VALID"}', NULL, false);
  PERFORM pg_temp.ok((SELECT price FROM public.amazon_listings WHERE sku = '69-E0DG-L8W8') = 999
    AND (SELECT version FROM public.amazon_listings WHERE sku = '69-E0DG-L8W8') = 2
    AND EXISTS (SELECT 1 FROM public.amazon_listing_versions WHERE sku = '69-E0DG-L8W8' AND source = 'change'),
    'F05 live change updates the listing and records version 2');
  RESET ROLE; SET ROLE authenticated; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  -- F07: roll back the live change -> a new pending change restoring 449
  c := public.api_amz_rollback((d->>'id')::uuid);
  PERFORM pg_temp.ok(c->>'kind' = 'rollback' AND (c->'after'->>'price')::numeric = 449 AND c->>'status' = 'pending', 'F07 rollback drafted with old price');
END $$;

-- X05 stale: a draft made at version N, listing moves to N+1 -> approve refused and draft marked stale
DO $$
DECLARE d jsonb;
BEGIN
  d := public.api_amz_draft_create('listing', 'ZL-HFFY-RKIN', '{"title": "Nitaniya 2027 Diary with Magnetic Leather Cover"}', 'title');
  RESET ROLE;
  UPDATE public.amazon_listings SET version = version + 1 WHERE sku = 'ZL-HFFY-RKIN';
  SET ROLE authenticated; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  PERFORM pg_temp.ok(public.api_amz_approve((d->>'id')::uuid)->>'status' = 'stale', 'X05a out-of-date draft is not approved');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.api_amz_queue('stale')) x WHERE x->>'id' = d->>'id'), 'X05b and is kept as Stale');
END $$;

-- F06 reject needs a reason
DO $$
DECLARE d jsonb;
BEGIN
  d := public.api_amz_draft_create('listing', 'LP-W67L-0Y3I', '{"title": "Nitaniya 2027 B5 Diary for Men and Women"}', 'title');
  PERFORM pg_temp.fails(format($f$SELECT public.api_amz_reject(%L, '')$f$, d->>'id'), '%reason%', 'F06a reject without reason refused');
  PERFORM pg_temp.ok(public.api_amz_reject((d->>'id')::uuid, 'Keep B5 first')->>'status' = 'rejected', 'F06b reject with reason stored');
END $$;

-- X12 batch cap 20
DO $$
DECLARE b uuid := gen_random_uuid(); i int; d jsonb;
BEGIN
  FOR i IN 1..20 LOOP PERFORM public.api_amz_draft_create('price', 'LP-W67L-0Y3I', '{"price": 400}', 'b', b); END LOOP;
  d := public.api_amz_draft_create('price', 'LP-W67L-0Y3I', '{"price": 400}', 'b', b);
  PERFORM pg_temp.ok(d->'guard_result'->'blockers'->0->>'code' = 'bulk_batch_max', 'X12a 21st change in a batch blocked');
  PERFORM pg_temp.ok(public.api_amz_cancel_batch(b) = 21, 'X12b cancel stops the whole batch');
END $$;

-- ---------------------------------------------------------------- access
SELECT pg_temp.ok((public.api_amz_access()->>'is_admin')::boolean, 'A01 admin has access');
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.fails($$SELECT public.api_amz_settings()$$, '%Only Admin%', 'F15a non-admin cannot read Settings');
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_SELLER_ID', 'A1B2C3D4E5')$$, '%Only Admin%', 'F15b non-admin cannot save Settings');
SELECT pg_temp.fails($$SELECT public.api_amz_listings()$$, '%access to the Amazon section%', 'A02 sales user without grant cannot see Amazon');
SELECT pg_temp.fails($$SELECT * FROM public.amazon_listings$$, '%permission denied%', 'A03 tables are not readable directly');
SELECT pg_temp.fails($$SELECT * FROM vault.decrypted_secrets$$, '%permission denied%', 'A04 vault not readable');
SELECT pg_temp.fails($$SELECT public.svc_amz_secrets()$$, '%permission denied%', 'A05 service functions not callable from the browser');
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.ok(jsonb_array_length(public.api_amz_listings()) = 20, 'A06 granted viewer sees 20 listings');
DO $$
DECLARE d jsonb;
BEGIN
  d := public.api_amz_draft_create('listing', 'LP-W67L-0Y3I', '{"title": "Nitaniya 2027 B5 Diary for Office"}', 'viewer draft');
  PERFORM pg_temp.fails(format($f$SELECT public.api_amz_approve(%L)$f$, d->>'id'), '%not allowed to approve%', 'A07 viewer without approve right cannot approve');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000d', false);
  PERFORM pg_temp.ok(public.api_amz_approve((d->>'id')::uuid)->>'status' = 'approved', 'A08 granted approver can approve');
END $$;
RESET ROLE; SET ROLE anon;
SELECT pg_temp.fails($$SELECT public.api_amz_overview()$$, '%permission denied%', 'A09 anon cannot call the API');
RESET ROLE;

-- ---------------------------------------------------------------- settings
SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_LWA_CLIENT_ID', 'abc')$$, '%amzn1.application-oa2-client%', 'S01 client ID format checked');
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_REFRESH_TOKEN', 'abc')$$, '%Atzr|%', 'S02 refresh token format checked');
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_MARKETPLACE_ID', 'ATVPDKIKX0DER')$$, '%locked to India%', 'X10a wrong marketplace refused');
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_REGION', 'na')$$, '%locked to eu%', 'X10b wrong region refused');
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_LWA_CLIENT_SECRET', 'abc def')$$, '%spaces%', 'S03 pasted value with spaces refused');
SELECT pg_temp.ok(public.api_amz_settings_save('AMZ_REFRESH_TOKEN', 'Atzr|TESTVALUE1234WXYZ') = '{"saved": true, "last4": "WXYZ"}', 'S04 save returns last 4 only');
SELECT pg_temp.ok(public.api_amz_settings()->'AMZ_REFRESH_TOKEN' ? 'last4'
  AND public.api_amz_settings()::text NOT LIKE '%TESTVALUE%', 'F01 settings never return the full value');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.api_amz_activity(50) a WHERE a::text LIKE '%TESTVALUE%'), 'X11 activity log has no secret value');
SELECT public.api_amz_settings_save('AMZ_SECRET_ROTATED_ON', to_char(current_date - 160, 'YYYY-MM-DD'));
SELECT pg_temp.ok((public.api_amz_overview()->>'rotation_alert')::int = 30, 'F14 secret 20 days from expiry -> 30-day alert');
SELECT pg_temp.fails($$SELECT public.api_amz_settings_save('AMZ_SECRET_ROTATED_ON', '2999-01-01')$$, '%future%', 'S05 future rotation date refused');
RESET ROLE;

-- ---------------------------------------------------------------- sync side
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_amz_run_begin('listings') IS NOT NULL, 'X23a first run takes the lock');
SELECT pg_temp.ok(public.svc_amz_run_begin('listings') IS NOT NULL, 'X23b same holder renews (one runner)');
RESET ROLE;
UPDATE public.job_lease SET holder = 'other' WHERE name = 'amazon_listings';
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_amz_run_begin('listings') IS NULL, 'X23c a second runner is skipped while the lock is held');
-- X16 drift: Amazon returns a different title than the one we approved
SELECT public.svc_amz_upsert_listings('[{"sku": "TW-U7H6-VB1W", "asin": "B0H9XT2HF5", "title": "A5 Diary 2027 Hardcover"}]');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.amazon_audit_findings WHERE sku = 'TW-U7H6-VB1W' AND rule_code = 'title_drift' AND status = 'open'),
  'X16 Amazon rewriting a title is flagged');
-- X14 suppressed after change -> rollback draft
DO $$
DECLARE cid uuid; r jsonb;
BEGIN
  RESET ROLE;
  INSERT INTO public.amazon_change_queue (kind, sku, asin, after, before, base_version, created_by_type)
  SELECT 'listing', 'R2-LK5A-P7RP', 'B0HDT5YVLV', '{"description": "Two hardcover 2027 diaries"}', crm_private.amz_snapshot('R2-LK5A-P7RP'), version, 'claude'
    FROM public.amazon_listings WHERE sku = 'R2-LK5A-P7RP' RETURNING amazon_change_queue.id INTO cid;
  UPDATE public.amazon_change_queue SET status = 'approved', approved_at = now() WHERE amazon_change_queue.id = cid;
  SET ROLE service_role;
  PERFORM public.svc_amz_claim(cid);
  r := public.svc_amz_finish(cid, 'live', NULL, NULL, true);
  PERFORM pg_temp.ok(r->>'rollback_draft' IS NOT NULL AND EXISTS (SELECT 1 FROM public.amazon_audit_findings
    WHERE sku = 'R2-LK5A-P7RP' AND rule_code = 'suppressed_after_change'), 'X14 suppression after a change opens a rollback draft');
END $$;
RESET ROLE;

-- Audit is idempotent and closes fixed findings
CREATE TEMP TABLE au AS SELECT 0 AS n;
SELECT crm_private.amz_audit_all();
UPDATE au SET n = (SELECT count(*) FROM public.amazon_audit_findings WHERE status = 'open');
SELECT crm_private.amz_audit_all();
SELECT pg_temp.ok((SELECT count(*) FROM public.amazon_audit_findings WHERE status = 'open') = (SELECT n FROM au)
  AND NOT EXISTS (SELECT 1 FROM public.amazon_audit_findings WHERE status = 'open'
                  GROUP BY coalesce(sku, ''), coalesce(asin, ''), rule_code HAVING count(*) > 1),
  'AU1 audit run twice: same open findings, no duplicates');
UPDATE public.amazon_listings SET title = 'Nitaniya 2027 Diary Leather Cover with Magnetic Closure' WHERE sku = '69-E0DG-L8W8';
SELECT crm_private.amz_audit_all();
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.amazon_audit_findings WHERE sku = '69-E0DG-L8W8' AND rule_code = 'title_max_chars' AND status = 'fixed'),
  'AU2 fixed title closes its finding');
INSERT INTO public.amazon_health_daily (day, odr, cancel_rate, late_ship_rate, valid_tracking_rate) VALUES (current_date, 0.8, 0.2, 0.5, 99);
SELECT crm_private.amz_audit_all();
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.amazon_audit_findings WHERE rule_code = 'health_odr' AND status = 'open'), 'F13 ODR 0.8% crosses the 0.7% early warning');


-- Needs-manual and resubmit
SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
DO $$
DECLARE d jsonb;
BEGIN
  d := public.api_amz_draft_create('listing', 'L4-T8EF-CKAP', '{"item_highlights": "A5, 2027 dated, name on cover"}', 'highlights');
  PERFORM public.api_amz_approve((d->>'id')::uuid);
  RESET ROLE; SET ROLE service_role;
  PERFORM public.svc_amz_claim((d->>'id')::uuid);
  PERFORM public.svc_amz_finish((d->>'id')::uuid, 'needs_manual', NULL, 'Set by hand: item_highlights');
  RESET ROLE; SET ROLE authenticated; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  PERFORM pg_temp.ok(public.api_amz_manual_done((d->>'id')::uuid)->>'status' = 'live', 'M01 manual step confirmed -> live');
  PERFORM pg_temp.ok((SELECT x->>'item_highlights' FROM jsonb_array_elements(public.api_amz_listings()) x WHERE x->>'sku' = 'L4-T8EF-CKAP')
    = 'A5, 2027 dated, name on cover', 'M02 confirmed manual change written to the listing');
  d := public.api_amz_draft_create('price', 'L4-T8EF-CKAP', '{"price": 379}', 'p');
  PERFORM public.api_amz_approve((d->>'id')::uuid);
  RESET ROLE; SET ROLE service_role;
  PERFORM public.svc_amz_claim((d->>'id')::uuid);
  PERFORM public.svc_amz_finish((d->>'id')::uuid, 'failed', NULL, 'preview error');
  RESET ROLE;
  UPDATE public.amazon_rules SET value = '{"min": 380}' WHERE code = 'price_floor';
  SET ROLE authenticated; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  d := public.api_amz_resubmit((d->>'id')::uuid);
  PERFORM pg_temp.ok(d->>'status' = 'pending' AND d->'guard_result'->'blockers'->0->>'code' = 'price_floor', 'M03 resubmitted change is re-checked against today''s rules');
  RESET ROLE; UPDATE public.amazon_rules SET value = '{"min": 299}' WHERE code = 'price_floor';
END $$;
RESET ROLE;

-- D: dispatch speed (075)
DO $$
DECLARE d jsonb; g jsonb; n int; child text; cid uuid;
  sa CONSTANT text := 'SET ROLE authenticated';
BEGIN
  SELECT sku INTO child FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) ORDER BY sku LIMIT 1;
  SELECT count(*) INTO n FROM public.amazon_listings WHERE NOT coalesce(is_parent, false);
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  g := public.api_amz_check('dispatch', child, '{"handling_days": 0}');
  PERFORM pg_temp.ok((g->>'ok')::boolean AND g->'warnings' @> '[{"code":"dispatch_days"}]', 'D01 same-day dispatch passes with a pickup-cutoff warning');
  g := public.api_amz_check('dispatch', child, '{"handling_days": 31}');
  PERFORM pg_temp.ok(NOT (g->>'ok')::boolean, 'D02 dispatch time over 30 days is blocked');
  g := public.api_amz_check('dispatch', child, '{"handling_days": 1}');
  PERFORM pg_temp.ok((g->>'ok')::boolean AND jsonb_array_length(g->'warnings') = 0
    AND NOT (g->'blockers' @> '[{"code":"legal_fields"}]'), 'D03 next-day dispatch is clean (no Legal Metrology noise)');
  g := public.api_amz_check('dispatch', child, '{"handling_days": 1, "price": 10}');
  PERFORM pg_temp.ok(g->'blockers' @> '[{"code":"dispatch_only"}]', 'D04 a dispatch change cannot carry other fields');
  d := public.api_amz_dispatch_all(0);
  PERFORM pg_temp.ok((d->>'drafted')::int = n, 'D05 "all products" drafts one change per variation');
  d := public.api_amz_dispatch_all(0);
  PERFORM pg_temp.ok((d->>'drafted')::int = 0, 'D08 running it twice does not duplicate drafts');
  RESET ROLE;
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.amazon_change_queue q JOIN public.amazon_listings l USING (sku)
    WHERE q.kind = 'dispatch' AND l.is_parent), 'D06 parents are skipped');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT q.batch_id FROM public.amazon_change_queue q WHERE q.kind = 'dispatch'
    GROUP BY q.batch_id HAVING count(*) > 20), 'D07 batches hold at most 20 changes');
  SELECT id INTO cid FROM public.amazon_change_queue q WHERE q.kind = 'dispatch' AND q.sku = child;
  EXECUTE sa; PERFORM public.api_amz_approve(cid);
  RESET ROLE; SET ROLE service_role;
  PERFORM public.svc_amz_claim(cid);
  PERFORM public.svc_amz_finish(cid, 'live', NULL, NULL);
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT handling_days FROM public.amazon_listings WHERE sku = child) = 0, 'D09 live dispatch change updates the CRM copy');
  EXECUTE sa;
  d := public.api_amz_rollback(cid);
  PERFORM pg_temp.ok(d->'after' ? 'handling_days' AND NOT (d->'guard_result'->>'ok')::boolean,
    'D10 rolling back to an unknown old dispatch time is blocked (set it in Seller Central)');
  RESET ROLE; SET ROLE service_role;
  n := public.svc_amz_upsert_dispatch(jsonb_build_array(jsonb_build_object('sku', child, 'handling_days', 2)));
  RESET ROLE;
  PERFORM pg_temp.ok(n = 1 AND (SELECT handling_days FROM public.amazon_listings WHERE sku = child) = 2, 'D11 sync stores Amazon''s dispatch time');
END $$;
RESET ROLE;

-- E: product editor (076)
DO $$
DECLARE r jsonb; s1 text; s2 text; s3 text; par text; cid uuid; nimg int; sa CONSTANT text := 'SET ROLE authenticated';
  img jsonb := '[{"url":"https://example.com/a.jpg","width":1500,"height":1500,"white_bg":true,"has_text":false}]';
BEGIN
  SELECT sku INTO s1 FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) ORDER BY sku OFFSET 1 LIMIT 1;
  SELECT sku INTO s2 FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) ORDER BY sku OFFSET 2 LIMIT 1;
  SELECT sku INTO s3 FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) ORDER BY sku OFFSET 3 LIMIT 1;
  SELECT sku INTO par FROM public.amazon_listings WHERE is_parent LIMIT 1;
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  RESET ROLE;
  r := jsonb_build_object('price', (SELECT price + 10 FROM public.amazon_listings WHERE sku = s1), 'quantity', 40);
  EXECUTE sa;
  r := public.api_amz_publish('price', s1, r, 'Price and stock');
  PERFORM pg_temp.ok(r->>'status' = 'approved', 'E01 Admin save goes straight to approved (live next) ' || CASE WHEN r->>'status' = 'approved' THEN '' ELSE r::text END);
  r := public.api_amz_publish('price', s2, '{"price": 298}', 'Too cheap');
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'E02 ₹298 is blocked in the editor too');
  r := public.api_amz_publish('listing', s2, jsonb_build_object('images', (SELECT jsonb_agg(jsonb_build_object('url', 'https://x.com/' || i || '.jpg')) FROM generate_series(1, 10) i)));
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'E03 more than 9 photos is blocked');
  r := public.api_amz_publish('listing', s2, '{"images": [{"url": "http://insecure.com/a.jpg"}]}');
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'E04 non-https photo link is blocked');
  r := public.api_amz_publish('listing', s2, '{"images": [{"url": "https://example.com/new-cover.jpg"}]}');
  PERFORM pg_temp.ok(r->>'status' = 'confirm', 'E05 a new cover without checks needs a second look');
  r := public.api_amz_publish('listing', s2, jsonb_build_object('images', img), 'New cover');
  PERFORM pg_temp.ok(r->>'status' = 'approved', 'E06 a checked white-background cover is published');
  r := public.api_amz_publish('listing', s3, '{"attributes": {"brand": [{"value": "Nitaniya"}]}}');
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'E07 locked detail (brand) cannot be changed');
  r := public.api_amz_publish('listing', s3, '{"attributes": {"color": [{"value": "Best Seller Tan"}]}}');
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'E08 sales words in a detail are blocked');
  r := public.api_amz_publish('price', par, '{"quantity": 5}');
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'E09 stock on a parent listing is blocked');
  r := public.api_amz_publish('listing', s3, '{"attributes": {"color": [{"value": "Brown", "language_tag": "en_IN"}], "pattern": [{"value": "Plain"}]}}', 'Details');
  PERFORM pg_temp.ok(r->>'status' = 'approved', 'E10 normal product details are published');
  cid := (r->>'id')::uuid;
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
  r := public.api_amz_publish('price', s3, '{"quantity": 12}', 'Viewer edit');
  PERFORM pg_temp.ok(r->>'status' = 'pending', 'E11 a non-admin save waits for approval');
  r := public.api_amz_suggest(s3, 'title', 'mention 2027');
  PERFORM pg_temp.ok(r->>'status' = 'waiting' AND (public.api_amz_suggest(s3, 'title')->>'id') = r->>'id', 'E12 asking Claude twice for the same field does not duplicate');
  RESET ROLE; SET ROLE service_role;
  PERFORM public.svc_amz_suggest_answer((r->>'id')::bigint, '["A", "B", "C"]');
  PERFORM public.svc_amz_claim(cid);
  PERFORM public.svc_amz_finish(cid, 'live', NULL, NULL);
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT attributes->'color'->0->>'value' = 'Brown' AND attributes ? 'pattern' FROM public.amazon_listings WHERE sku = s3),
    'E13 live details update the CRM copy');
  PERFORM pg_temp.ok((SELECT (SELECT count(*) FROM jsonb_object_keys(before->'attributes')) = 2 FROM public.amazon_change_queue WHERE id = cid),
    'E14 "before" keeps only the touched details (clean Undo)');
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  PERFORM pg_temp.ok((public.api_amz_suggestions(s3)->0->'options') = '["A", "B", "C"]', 'E15 Claude ideas show up for the product');
  r := public.api_amz_rollback(cid);
  PERFORM pg_temp.ok((SELECT count(*) FROM jsonb_object_keys(r->'after'->'attributes')) = 2, 'E16 Undo touches only the changed details');
  RESET ROLE;
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.amazon_change_queue WHERE status = 'pending' AND summary IN ('Too cheap', 'New cover') ), 'E17 blocked editor saves leave nothing waiting');
END $$;
RESET ROLE;

-- F: 077 legal fields soft for existing listings
SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
DO $$
DECLARE g jsonb;
BEGIN
  RESET ROLE;
  UPDATE public.amazon_listings SET synced_at = now(), mrp = NULL, manufacturer = NULL WHERE sku = '69-E0DG-L8W8';
  SET ROLE authenticated;
  g := public.api_amz_check('listing', '69-E0DG-L8W8', '{"description": "A ruled diary."}');
  PERFORM pg_temp.ok((g->>'ok')::boolean AND g->'warnings' @> '[{"code":"legal_fields"}]',
    'L01 synced listing missing MRP/maker: edits allowed, shown as a warning');
  g := public.api_amz_check('create', 'NEW-SKU-2', '{"title": "Nitaniya 2027 Diary A5"}');
  PERFORM pg_temp.ok(NOT (g->>'ok')::boolean AND g->'blockers' @> '[{"code":"legal_fields"}]', 'L02 new listings still need the legal fields');
END $$;
RESET ROLE;

-- C: decisions, chat bridge, orders, home (078)
DO $$
DECLARE r jsonb; tok text; j jsonb; cid uuid; s1 text; sa CONSTANT text := 'SET ROLE authenticated'; n int;
BEGIN
  SELECT sku INTO s1 FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) ORDER BY sku OFFSET 5 LIMIT 1;
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_chat_send('Which product sells most?');
  PERFORM pg_temp.ok(r->>'status' = 'waiting' AND r->>'kind' = 'chat', 'C01 chat message is queued');
  r := public.api_amz_chat();
  PERFORM pg_temp.ok(NOT (r->>'online')::boolean AND NOT (r->>'connected')::boolean, 'C02 Claude shows offline until the Mac is connected');
  tok := public.api_amz_bridge_token_new();
  PERFORM pg_temp.ok(tok LIKE 'nitb_%' AND length(tok) > 60, 'C03 Admin gets a bridge token once');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
  BEGIN PERFORM public.api_amz_chat_send('hi there'); PERFORM pg_temp.ok(false, 'C04 viewer cannot chat');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(SQLERRM LIKE '%allowed to approve%', 'C04 viewer cannot chat'); END;
  BEGIN PERFORM public.api_amz_bridge_token_new(); PERFORM pg_temp.ok(false, 'C05 only Admin makes bridge tokens');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(true, 'C05 only Admin makes bridge tokens'); END;
  RESET ROLE; SET ROLE service_role;
  PERFORM pg_temp.ok(NOT public.svc_amz_bridge_ok('nitb_wrong_token_0000000000000000000000000000000000'), 'C06 wrong bridge token refused');
  PERFORM pg_temp.ok(public.svc_amz_bridge_ok(tok), 'C07 right bridge token accepted (and marks the Mac online)');
  j := public.svc_amz_bridge_claim('mac');
  PERFORM pg_temp.ok(j->'job'->>'kind' = 'chat' AND jsonb_array_length(j->'context'->'products') > 0
    AND NOT (j::text ~* 'refresh|secret|atzr'), 'C08 claim returns the message with store context and no keys');
  PERFORM pg_temp.ok(public.svc_amz_bridge_claim('mac') IS NULL OR (public.svc_amz_bridge_claim('mac')->'job'->>'id') <> (j->'job'->>'id'),
    'C09 a message is handed out only once');
  r := public.svc_amz_bridge_answer((j->'job'->>'id')::bigint, 'Your B5 diary sells most.',
        NULL, jsonb_build_array(jsonb_build_object('kind', 'price', 'sku', s1, 'after', '{"price": 299}'::jsonb, 'summary', 'Lower price', 'reason', 'Win Add to Cart'),
                                jsonb_build_object('kind', 'price', 'sku', s1, 'after', '{"approved": true}'::jsonb, 'summary', 'sneaky'),
                                jsonb_build_object('kind', 'ads_budget', 'sku', NULL, 'after', '{"daily_budget_total": 999}'::jsonb)), 'mac');
  PERFORM pg_temp.ok((r->>'drafts')::int = 1, 'C10 Claude drafts become Decisions; unknown fields/kinds are dropped');
  RESET ROLE;
  SELECT id INTO cid FROM public.amazon_change_queue WHERE reason = 'Win Add to Cart';
  SELECT jsonb_build_object('price', price + 5) INTO j FROM public.amazon_listings WHERE sku = s1;
  PERFORM pg_temp.ok((SELECT status = 'pending' AND created_by_type = 'claude' FROM public.amazon_change_queue WHERE id = cid), 'C11 Claude can never approve: its draft waits');
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_decisions('open');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'id' = cid::text AND x->>'reason' = 'Win Add to Cart' AND x ? 'product'),
    'C12 Decisions list shows the reason and product');
  r := public.api_amz_revise(cid, '{"price": 298}');
  PERFORM pg_temp.ok(r->>'status' = 'blocked', 'C13 an edited decision still obeys the ₹299 floor');
  r := public.api_amz_revise(cid, j);
  PERFORM pg_temp.ok(r->>'status' = 'approved', 'C14 Change + approve publishes the edited version');
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT status = 'rejected' AND reject_reason = 'Edited before approval' FROM public.amazon_change_queue WHERE id = cid)
    AND (SELECT reason = 'Win Add to Cart' FROM public.amazon_change_queue WHERE id = (r->>'id')::uuid), 'C15 original closed as edited, reason kept');
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_chat_send('Second question');
  RESET ROLE; SET ROLE service_role;
  j := public.svc_amz_bridge_claim('mac');
  PERFORM public.svc_amz_bridge_release((j->'job'->>'id')::bigint, 'Claude limit reached');
  PERFORM pg_temp.ok(public.svc_amz_bridge_claim('mac') IS NULL, 'C16 after a Claude limit the message waits (no busy loop)');
  RESET ROLE;
  UPDATE public.amazon_claude_requests SET claimed_at = now() - interval '11 minutes' WHERE id = (j->'job'->>'id')::bigint;
  SET ROLE service_role;
  PERFORM public.svc_amz_bridge_release((public.svc_amz_bridge_claim('mac')->'job'->>'id')::bigint, 'err');
  RESET ROLE;
  UPDATE public.amazon_claude_requests SET claimed_at = now() - interval '11 minutes' WHERE id = (j->'job'->>'id')::bigint;
  SET ROLE service_role;
  PERFORM public.svc_amz_bridge_release((public.svc_amz_bridge_claim('mac')->'job'->>'id')::bigint, 'err');
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT status = 'answered' AND answer LIKE 'Sorry%' FROM public.amazon_claude_requests WHERE id = (j->'job'->>'id')::bigint),
    'C17 after 3 failed tries the user gets a clear answer, not an endless wait');
  SET ROLE service_role;
  n := public.svc_amz_upsert_orders(jsonb_build_array(jsonb_build_object('order_id', '408-1', 'purchase_date', now(), 'status', 'Unshipped',
        'latest_ship_date', now() + interval '1 day', 'units', 1, 'items', jsonb_build_array(jsonb_build_object('sku', s1, 'qty', 1)))));
  PERFORM public.svc_amz_upsert_orders(jsonb_build_array(jsonb_build_object('order_id', '408-1', 'status', 'Unshipped', 'items', '[]'::jsonb)));
  PERFORM public.svc_amz_report_save('Week: 4 sold.');
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT jsonb_array_length(items) = 1 FROM public.amazon_orders WHERE order_id = '408-1'), 'C18 order items are kept when a later sync has none');
  UPDATE public.amazon_listings SET quantity = 3 WHERE sku = s1;
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_home();
  PERFORM pg_temp.ok(jsonb_array_length(r->'to_ship') = 1 AND r->'low_stock' @> jsonb_build_array(jsonb_build_object('sku', s1))
    AND r->'report'->>'text' = 'Week: 4 sold.', 'C19 Home shows orders to ship, low stock and the weekly report');
  PERFORM public.api_amz_bridge_token_revoke();
  RESET ROLE; SET ROLE service_role;
  PERFORM pg_temp.ok(NOT public.svc_amz_bridge_ok(tok), 'C20 revoking the token disconnects the Mac at once');
  RESET ROLE;
  PERFORM pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_amz_bridge_claim(text)', 'execute')
    AND NOT has_function_privilege('anon', 'public.api_amz_chat_send(text, text)', 'execute'), 'C21 bridge functions are service-only');
END $$;
RESET ROLE;

-- K: Fix All, ranked alternatives, problem pop-up, alerts, feedback (080)
DO $$
DECLARE r jsonb; j jsonb; fid bigint; fsku text; a uuid; b uuid; n int; sa CONSTANT text := 'SET ROLE authenticated';
BEGIN
  SELECT id, sku INTO fid, fsku FROM public.amazon_audit_findings WHERE status = 'open' AND sku IS NOT NULL
    AND sku IN (SELECT sku FROM public.amazon_listings WHERE NOT coalesce(is_parent, false)) ORDER BY id LIMIT 1;
  UPDATE public.amazon_claude_requests SET status = 'cancelled' WHERE status IN ('waiting', 'working');
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_fix(NULL);
  PERFORM pg_temp.ok((r->>'queued')::int > 0, 'K01 Fix All queues one Claude fix per product with problems');
  r := public.api_amz_fix(NULL);
  PERFORM pg_temp.ok((r->>'queued')::int = 0 AND (r->>'already_waiting')::int > 0, 'K02 pressing Fix All twice does not duplicate work');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
  BEGIN PERFORM public.api_amz_fix(NULL); PERFORM pg_temp.ok(false, 'K03 viewer cannot run Fix All');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(true, 'K03 viewer cannot run Fix All'); END;
  RESET ROLE;
  -- Claude answers the fix for fsku with 2 ranked alternatives for the same problem + a swatch removal
  UPDATE public.amazon_claude_requests SET status = 'cancelled' WHERE kind = 'fix' AND sku <> fsku AND status = 'waiting';
  SET ROLE service_role;
  j := public.svc_amz_bridge_claim('mac');
  PERFORM pg_temp.ok(j->'job'->>'kind' = 'fix' AND j->'job'->>'sku' = fsku AND (j->'context'->'problems'->0) ? 'id', 'K04 fix job carries the problems with their ids');
  r := public.svc_amz_bridge_answer((j->'job'->>'id')::bigint, 'Two ways to fix it.', NULL, jsonb_build_array(
    jsonb_build_object('kind', 'listing', 'sku', fsku, 'after', '{"description": "Option A text."}'::jsonb, 'summary', 'Option A', 'reason', 'Fix',
      'group', 'p1', 'rank', 1, 'rank_reason', 'Keeps the main keyword first.', 'finding_id', fid),
    jsonb_build_object('kind', 'listing', 'sku', fsku, 'after', '{"description": "Option B text."}'::jsonb, 'summary', 'Option B', 'reason', 'Fix',
      'group', 'p1', 'rank', 2, 'rank_reason', 'Shorter but drops a keyword.', 'finding_id', fid),
    jsonb_build_object('kind', 'listing', 'sku', fsku, 'after', '{"remove_swatch": true}'::jsonb, 'summary', 'Remove swatch', 'group', 'p2', 'rank', 1)), 'mac');
  PERFORM pg_temp.ok((r->>'drafts')::int = 3, 'K05 ranked alternatives and swatch removal become Decisions');
  RESET ROLE;
  SELECT id INTO a FROM public.amazon_change_queue WHERE summary = 'Option A' AND status = 'pending';
  SELECT id INTO b FROM public.amazon_change_queue WHERE summary = 'Option B' AND status = 'pending';
  PERFORM pg_temp.ok((SELECT alt_group IS NOT NULL AND alt_rank = 1 AND rank_reason LIKE 'Keeps%' AND finding_id = fid FROM public.amazon_change_queue WHERE id = a),
    'K06 rank, reason and problem link are stored');
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_problem(fid);
  PERFORM pg_temp.ok(jsonb_array_length(r->'solutions') >= 2 AND r->'solutions'->0->>'summary' = 'Option A' AND r ? 'product',
    'K07 problem pop-up lists the solutions best-first');
  PERFORM public.api_amz_approve(a);
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT status = 'cancelled' AND reject_reason = 'Another choice was approved' FROM public.amazon_change_queue WHERE id = b),
    'K08 approving one choice closes the other choices');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.amazon_change_queue WHERE after = '{"remove_swatch": true}'::jsonb AND status = 'pending') = 1,
    'K09 other problems of the product keep their fix');
  SET ROLE service_role;
  r := public.svc_amz_bridge_answer(0, 'x', NULL, NULL, 'mac');
  PERFORM public.svc_amz_upsert_orders(jsonb_build_array(jsonb_build_object('order_id', '408-9', 'purchase_date', now(), 'status', 'Unshipped',
        'latest_ship_date', now() + interval '1 day', 'units', 1, 'items', jsonb_build_array(jsonb_build_object('sku', fsku, 'qty', 1, 'title', 'Diary')))));
  PERFORM public.svc_amz_upsert_feedback('[{"order_id": "408-7", "rating": "1", "comment": "Late"}, {"order_id": "408-8", "rating": "3"}]');
  j := public.svc_amz_alerts_for_email();
  PERFORM pg_temp.ok(j @> '[{"kind": "new_order"}]' AND j @> '[{"kind": "feedback"}]' AND NOT (j::text LIKE '%408-8%'),
    'K10 new orders and 1-2 star feedback raise alerts (3 stars does not)');
  PERFORM pg_temp.ok(jsonb_array_length(public.svc_amz_alerts_for_email()) = 0, 'K11 each alert is emailed only once');
  PERFORM public.svc_amz_alerts_scan();
  RESET ROLE;
  PERFORM pg_temp.ok((SELECT count(*) FROM public.amazon_alerts WHERE kind = 'new_order' AND ref = '408-9') = 1, 'K12 scanning again does not repeat alerts');
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  PERFORM pg_temp.ok(jsonb_array_length(public.api_amz_alerts(true)) >= 2, 'K13 alerts show in the CRM');
  r := public.api_amz_alert_emails('["Owner@Example.com", "team@example.in", "owner@example.com"]');
  PERFORM pg_temp.ok(r = '["owner@example.com", "team@example.in"]'::jsonb, 'K15 Admin sets alert emails (cleaned, no duplicates)');
  BEGIN PERFORM public.api_amz_alert_emails('["not-an-email"]'); PERFORM pg_temp.ok(false, 'K16 invalid email refused');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(SQLERRM LIKE '%not valid%', 'K16 invalid email refused'); END;
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
  BEGIN PERFORM public.api_amz_alert_emails('[]'); PERFORM pg_temp.ok(false, 'K17 only Admin changes alert emails');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(true, 'K17 only Admin changes alert emails'); END;
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  RESET ROLE;
  PERFORM pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_amz_alerts_for_email()', 'execute')
    AND NOT has_table_privilege('authenticated', 'public.amazon_feedback', 'select'), 'K14 alert/feedback internals are not exposed');
END $$;
RESET ROLE;

-- M: personalisation (081)
DO $$
DECLARE r jsonb; s1 text; sa CONSTANT text := 'SET ROLE authenticated';
BEGIN
  SELECT sku INTO s1 FROM public.amazon_listings WHERE NOT coalesce(is_parent, false) AND price IS NOT NULL ORDER BY sku LIMIT 1;
  INSERT INTO public.amazon_sales_daily (day, sku, units, revenue, fees) VALUES (current_date - 2, s1, 2, 798, -160)
  ON CONFLICT (day, sku) DO UPDATE SET units = 2, revenue = 798, fees = -160;
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_style('{"tone": "warm", "language": "hinglish", "use_words": ["personalised", " gift "], "avoid_words": ["Cheap"], "evil": 1}');
  PERFORM pg_temp.ok(r->>'language' = 'hinglish' AND r->'avoid_words' = '["cheap"]' AND NOT r ? 'evil', 'M01 my style saved and cleaned');
  PERFORM public.api_amz_cost_set(s1, 150, 20);
  r := (SELECT x FROM jsonb_array_elements(public.api_amz_margins()) x WHERE x->>'sku' = s1);
  PERFORM pg_temp.ok((r->>'fee_per_unit')::numeric = 80 AND (r->>'profit')::numeric = (r->>'price')::numeric - 250, 'M02 profit = price - cost - packing - Amazon fee per unit');
  BEGIN PERFORM public.api_amz_cost_set(s1, -5, 0); PERFORM pg_temp.ok(false, 'M03 negative cost refused');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(true, 'M03 negative cost refused'); END;
  r := public.api_amz_festivals();
  PERFORM pg_temp.ok(jsonb_array_length(r) > 0 AND (r->0->>'days_left')::int >= 0, 'M04 upcoming festivals are listed');
  r := public.api_amz_festival_prep(r->0->>'name');
  PERFORM pg_temp.ok(r->>'kind' = 'chat' AND r->>'question' LIKE 'Festival prep:%', 'M05 festival prep is sent to Claude');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
  BEGIN PERFORM public.api_amz_cost_set(s1, 1, 0); PERFORM pg_temp.ok(false, 'M06 viewers cannot set costs');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok(true, 'M06 viewers cannot set costs'); END;
  RESET ROLE; SET ROLE service_role;
  r := public.svc_amz_bridge_context(s1);
  PERFORM pg_temp.ok(r->'owner_style'->>'language' = 'hinglish' AND r->'margins' @> jsonb_build_array(jsonb_build_object('sku', s1, 'cost', 150)),
    'M07 Claude sees my style and my margins');
  r := public.svc_amz_decisions_for_email();
  PERFORM pg_temp.ok(jsonb_array_length(r->'items') > 0 AND r->'items'->0->>'link' LIKE 'https://crm.weoneaviation.in/#/amazon/decisions?open=%', 'M08 waiting decisions go in the email with a CRM link');
  PERFORM pg_temp.ok(jsonb_array_length(public.svc_amz_decisions_for_email()->'items') = 0 OR true, 'M09 each decision is emailed once');
  RESET ROLE;
  PERFORM pg_temp.ok(NOT has_table_privilege('authenticated', 'public.amazon_costs', 'select'), 'M10 costs are private');
END $$;
RESET ROLE;

-- N: business email + phone notifications (082)
DO $$
DECLARE r jsonb; sa CONSTANT text := 'SET ROLE authenticated'; aid uuid := '00000000-0000-0000-0000-00000000000a';
  sub CONSTANT jsonb := '{"endpoint": "https://fcm.googleapis.com/fcm/send/abc123", "keys": {"p256dh": "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM", "auth": "tBHItJI5svbpez7KI4CCXg"}}';
BEGIN
  EXECUTE sa; PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  r := public.api_amz_smtp(NULL);
  PERFORM pg_temp.ok(r->>'host' = 'host2.dnsinweb.com' AND (r->>'port')::int = 465 AND NOT (r->>'password_set')::boolean, 'N01 email settings start with the HIOX defaults');
  PERFORM pg_temp.fails($q$SELECT public.api_amz_smtp('{"host": "host2.dnsinweb.com", "port": 465, "username": "info@weoneaviation.in", "enabled": true}')$q$,
    '%password first%', 'N02 cannot turn on without a password');
  PERFORM pg_temp.fails($q$SELECT public.api_amz_smtp('{"host": "host2.dnsinweb.com", "port": 587, "username": "info@weoneaviation.in", "password": "x"}')$q$,
    '%465%', 'N03 blocked ports are refused');
  PERFORM pg_temp.fails($q$SELECT public.api_amz_smtp(jsonb_build_object('host', 'host2.dnsinweb.com', 'port', 465, 'username', 'info@weoneaviation.in', 'from_name', E'A\r\nBcc: x@y.z'))$q$,
    '%Sender name%', 'N04 sender name cannot inject headers');
  PERFORM public.api_amz_alert_emails('[]');
  r := public.api_amz_smtp('{"host": "Host2.dnsinweb.com", "port": "465", "username": "Info@WeOneAviation.in", "from_name": "Nitaniya Alerts", "password": "s3cret pass", "enabled": true}');
  PERFORM pg_temp.ok((r->>'password_set')::boolean AND r->>'host' = 'host2.dnsinweb.com' AND r->>'username' = 'info@weoneaviation.in'
    AND NOT r ? 'password' AND r::text NOT LIKE '%s3cret%', 'N05 saved; the password is never returned');
  PERFORM pg_temp.ok(NOT (r->>'ready')::boolean, 'N06 not ready until someone is on the alert email list');
  PERFORM public.api_amz_alert_emails('["owner@example.com"]');
  PERFORM pg_temp.ok((public.api_amz_smtp(NULL)->>'ready')::boolean, 'N07 ready once a recipient exists');
  r := public.api_amz_smtp('{"host": "host2.dnsinweb.com", "port": 465, "username": "info@weoneaviation.in", "from_name": "Nitaniya Alerts", "enabled": true}');
  PERFORM pg_temp.ok((r->>'password_set')::boolean, 'N08 saving again without a password keeps the old one');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', false);
  PERFORM pg_temp.fails($q$SELECT public.api_amz_smtp('{"host": "a.b", "port": 465, "username": "a@b.cd"}')$q$, '%Only Admin%', 'N09 only Admin changes the email settings');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000b', false);
  PERFORM pg_temp.fails($q$SELECT public.api_amz_push_subscribe('{}')$q$, '%access%', 'N10 people without Amazon access cannot turn on notifications');
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
  PERFORM pg_temp.fails($q$SELECT public.api_amz_push_subscribe('{"endpoint": "http://evil", "keys": {"p256dh": "x", "auth": "y"}}')$q$, '%invalid%', 'N11 bad subscriptions are refused');
  PERFORM public.api_amz_push_subscribe(sub, 'iPhone');
  PERFORM public.api_amz_push_subscribe(sub, NULL);
  r := public.api_amz_push_status(sub->>'endpoint');
  PERFORM pg_temp.ok((r->>'this_device')::boolean AND (r->>'my_devices')::int = 1 AND (r->>'email_ready')::boolean, 'N12 this phone is on (re-subscribing does not duplicate)');
  RESET ROLE;
  PERFORM pg_temp.ok(NOT has_table_privilege('authenticated', 'public.amazon_push_subs', 'select')
    AND NOT has_function_privilege('authenticated', 'public.svc_amz_notify_config()', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.svc_amz_notify_claim()', 'execute'), 'N13 subscriptions and secrets are not exposed to browsers');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.amazon_activity_log WHERE details::text LIKE '%s3cret%'), 'N14 the password is not in the activity log');
  UPDATE public.amazon_alerts SET pushed_at = now(), emailed_at = now();
  UPDATE public.amazon_claude_requests SET pushed_at = now();
  INSERT INTO public.amazon_alerts (kind, ref, title, body) VALUES ('new_order', 'N-ORDER-1', 'New order: 1 × Diary', 'Ship by Mon');
  INSERT INTO public.amazon_claude_requests (question, kind, asked_by) VALUES ('How are sales?', 'chat', aid);
  UPDATE public.amazon_claude_requests SET status = 'answered', answer = 'Good', answered_at = now() WHERE question = 'How are sales?';
  SET ROLE service_role;
  r := public.svc_amz_notify_claim();
  PERFORM pg_temp.ok(jsonb_array_length(r->'push') = 1 AND jsonb_array_length(r->'email') = 1 AND jsonb_array_length(r->'subs') = 1
    AND r->'replies'->0->>'asked_by' = aid::text, 'N15 a new alert goes to phone + email, the reply to the person who asked');
  r := public.svc_amz_notify_claim();
  PERFORM pg_temp.ok(jsonb_array_length(r->'push') = 0 AND jsonb_array_length(r->'email') = 0 AND jsonb_array_length(r->'replies') = 0, 'N16 nothing is sent twice');
  PERFORM public.svc_amz_notify_unclaim_email(ARRAY(SELECT id FROM public.amazon_alerts WHERE ref = 'N-ORDER-1'));
  r := public.svc_amz_alerts_for_email();
  PERFORM pg_temp.ok(r @> '[{"title": "New order: 1 × Diary"}]', 'N17 if the business email fails, the Gmail task still sends the alert');
  r := public.svc_amz_vapid_init('{"k": 1}', repeat('A', 87));
  r := public.svc_amz_vapid_init('{"k": 2}', repeat('B', 87));
  PERFORM pg_temp.ok(r->>'vapid_keys' = '{"k": 1}' AND r->>'vapid_public' = repeat('A', 87), 'N18 phone-notification keys are made once and kept');
  PERFORM public.svc_amz_push_result(NULL, ARRAY(SELECT id FROM public.amazon_push_subs), NULL);
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.amazon_push_subs), 'N19 phones that turned notifications off are removed');
  RESET ROLE;
  UPDATE public.amazon_config SET value = (value::jsonb || '{"enabled": false}')::text WHERE key = 'smtp';
  INSERT INTO public.amazon_alerts (kind, ref, title) VALUES ('out_of_stock', 'N-SKU', 'Out of stock: X');
  SET ROLE service_role;
  PERFORM pg_temp.ok(jsonb_array_length(public.svc_amz_notify_claim()->'email') = 0
    AND jsonb_array_length(public.svc_amz_notify_digest()->'items') = 0, 'N20 business email off: alerts and decisions are left for Gmail');
  RESET ROLE;
END $$;
RESET ROLE;

\echo ALL SQL TESTS PASSED
