-- 115: Competitor watch (CW01-CW07). Runs after B0_.
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'items') = 2 AND NOT (v->>'can_edit')::boolean FROM (SELECT public.api_ads_competitors() v) z),
  'CW01 viewers see the competitor list (two seeded) but cannot edit it');
SELECT pg_temp.fails($q$SELECT public.api_ads_competitor_save('{"name": "Sky Academy"}')$q$, '%approvers%', 'CW02 only approvers edit competitors');
RESET ROLE; SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_ads_competitor_save('{"name": "Sky Academy", "domain": "not a site"}')$q$, '%example.com%', 'CW02b the website is checked');
CREATE TEMP TABLE c1 AS SELECT (public.api_ads_competitor_save('{"name": "Sky Academy", "domain": "https://www.skyacademy.in/courses"}')->>'id')::bigint id;
SELECT public.api_ads_competitor_ad_save(jsonb_build_object('competitor_id', (SELECT id FROM c1), 'format', 'video', 'started_on', (current_date - 60)::text,
  'primary_text', 'CPL in 18 months. Fees explained on a free call.', 'url', 'https://www.facebook.com/ads/library/?id=1', 'angle', 'speed'));
SELECT public.api_ads_competitor_ad_save(jsonb_build_object('competitor_id', (SELECT id FROM c1), 'started_on', (current_date - 5)::text, 'headline', 'New batch'));
SELECT pg_temp.fails($q$SELECT public.api_ads_competitor_ad_save(jsonb_build_object('competitor_id', (SELECT id FROM c1), 'headline', 'Hello', 'started_on', (current_date + 3)::text))$q$, '%future%', 'CW03 a start date in the future is refused');
SELECT pg_temp.fails($q$SELECT public.api_ads_competitor_ad_save(jsonb_build_object('competitor_id', (SELECT id FROM c1), 'headline', 'Hello', 'url', 'http://x.com'))$q$, '%https%', 'CW03b links must be https');
SELECT pg_temp.ok((SELECT x->>'domain' = 'skyacademy.in' AND (x->'ads'->0->>'days_running')::int = 60 AND (x->'ads'->1->>'days_running')::int = 5
    FROM (SELECT public.api_ads_competitors() v) z, jsonb_array_elements(v->'items') x WHERE x->>'name' = 'Sky Academy'),
  'CW04 the website is cleaned to a domain and ads are ranked by how long they have run');
RESET ROLE;
-- the Researcher's findings are kept per competitor
INSERT INTO public.ads_agent_runs (role, job, status, output) VALUES ('meta_researcher', 'meta', 'running',
  '{"competitors": [{"name": "Sky Academy", "strongest": "Duration promise", "gap": "No fee transparency"}, {"name": "Unknown Wings", "gap": "No parents angle"}, {"name": ""}]}');
UPDATE public.ads_agent_runs SET status = 'done' WHERE role = 'meta_researcher' AND output ? 'competitors' AND status = 'running';
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.ads_competitor_finding f JOIN public.ads_competitor c ON c.id = f.competitor_id WHERE c.name = 'Sky Academy' AND f.gap = 'No fee transparency')
    AND (SELECT count(*) = 1 FROM public.ads_competitor_finding WHERE competitor_id IS NULL AND name = 'Unknown Wings'),
  'CW05 after research, each competitor''s strongest idea and gap are kept (unknown names too)');
CREATE TEMP TABLE ex2 AS SELECT public.svc_ads_meta_strategy_extra() v;
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'competitors') = 3 AND v ? 'premium' AND v ? 'personas'
    AND (SELECT x->'findings'->0->>'gap' = 'No fee transparency' AND NOT (x ? 'id') FROM jsonb_array_elements(v->'competitors') x WHERE x->>'name' = 'Sky Academy') FROM ex2),
  'CW06 the Strategy agents get the competitors with their ads and findings, on top of the premium context');
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT public.api_ads_competitor_delete('competitor', (SELECT id FROM c1));
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) = 0 FROM public.ads_competitor_ad a JOIN public.ads_competitor c ON c.id = a.competitor_id WHERE c.name = 'Sky Academy')
    AND NOT has_table_privilege('authenticated', 'public.ads_competitor', 'SELECT') AND NOT has_function_privilege('anon', 'public.api_ads_competitors()', 'EXECUTE'),
  'CW07 removing a competitor removes its ads; tables are private, reading needs sign-in');
\echo ALL ADS META 115 TESTS PASSED
