-- 073: Amazon module seed. The 20 SKUs from Seller Central (Manage All Inventory export, 6 Nov 2026),
-- so the CRM has data before the first live sync. The first sync from Amazon overwrites these values.
-- Re-runnable: existing SKUs are left as they are.
INSERT INTO public.amazon_listings (sku, asin, is_parent, status, title, last_approved_title, price, buybox_price, has_buybox,
  quantity, fulfillment, fees, last_changed_on) VALUES
('69-E0DG-L8W8', 'B0HJ4XXK37', false, 'Active', 'B5 Premium Textured Foambound PU Leather Diary | Light Tan Color | Secure Button Closure | Built-in Pen Holder & Ribbon Bookmark | 160 Lined Pages | Ideal for Work, Study & Journaling', 'B5 Premium Textured Foambound PU Leather Diary | Light Tan Color | Secure Button Closure | Built-in Pen Holder & Ribbon Bookmark | 160 Lined Pages | Ideal for Work, Study & Journaling', 449.00, 449.00, true, 100, 'FBM', 27.14, '8 Sep 2026'),
('ZL-HFFY-RKIN', 'B0HH9PYBP2', false, 'Active', '2027 Diary Leather Cover with Magnetic Closure', '2027 Diary Leather Cover with Magnetic Closure', 449.00, 449.00, true, 58, 'FBM', 27.14, '31 Aug 2026'),
('R2-LK5A-P7RP', 'B0HDT5YVLV', false, 'Active', '2027 Diary Set of 2, Men & Women – Premium Hardcover Daily Planner | Yearly Organizer, Journal & Notebook', '2027 Diary Set of 2, Men & Women – Premium Hardcover Daily Planner | Yearly Organizer, Journal & Notebook', 549.00, 549.00, true, 98, 'FBM', 56.64, '11 Aug 2026'),
('LP-W67L-0Y3I', 'B0HDP9X12M', false, 'Active', '2027 B5 Diary for Men & Women', '2027 B5 Diary for Men & Women', 399.00, 399.00, true, 96, 'FBM', 27.14, '10 Aug 2026'),
('L4-T8EF-CKAP', 'B0HCZR818F', false, 'Active', '2027 A5 Diary for Men & Women, Personalized Name Diary with Strap Closure, Premium Daily Planner & Notebook for Office, School and Gifting', '2027 A5 Diary for Men & Women, Personalized Name Diary with Strap Closure, Premium Daily Planner & Notebook for Office, School and Gifting', 369.00, 369.00, true, 99, 'FBM', 27.14, '5 Aug 2026'),
('5P-T9VX-Z3AQ', 'B0HCZL66NT', false, 'Active', '2027 Customised Diary Leather Cover with Name', '2027 Customised Diary Leather Cover with Name', 369.00, NULL, NULL, 97, 'FBM', 27.14, '5 Aug 2026'),
('DU-RLF5-IVU9', 'B0HCZHMFVN', false, 'Active', '2027 Diary for Men & Women, Premium Personalized Leather Look Diary with Strap Closure, A5 Size Daily Planner & Notebook, Custom Name Diary for Office, School, College & Gifting', '2027 Diary for Men & Women, Premium Personalized Leather Look Diary with Strap Closure, A5 Size Daily Planner & Notebook, Custom Name Diary for Office, School, College & Gifting', 349.00, 349.00, true, 83, 'FBM', 27.14, '5 Aug 2026'),
('43-VYYX-BSZ0', 'B0HBBYYBS1', false, 'Active', '2027 New Year Diary B5 Size Premium PU Leather Executive Planner', '2027 New Year Diary B5 Size Premium PU Leather Executive Planner', 449.00, 449.00, true, 89, 'FBM', 27.14, '24 Jul 2026'),
('TW-U7H6-VB1W', 'B0H9XT2HF5', false, 'Active', '2027 Diary A5 Size – Premium Hardcover Diary & Daily Planner | 365 Days Organizer Notebook for Men & Women | Personal Journal, To-Do List, Notes, Office, School & College', '2027 Diary A5 Size – Premium Hardcover Diary & Daily Planner | 365 Days Organizer Notebook for Men & Women | Personal Journal, To-Do List, Notes, Office, School & College', 349.00, 349.00, true, 72, 'FBM', 27.14, '22 Jul 2026'),
('X7-64RH-7NG8', 'B0H9XT2HF5', false, 'Active', '2027 Diary A5 Size – Premium Hardcover Diary & Daily Planner | 365 Days Organizer Notebook for Men & Women | Personal Journal, To-Do List, Notes, Office, School & College', '2027 Diary A5 Size – Premium Hardcover Diary & Daily Planner | 365 Days Organizer Notebook for Men & Women | Personal Journal, To-Do List, Notes, Office, School & College', 349.00, 349.00, true, 73, 'FBM', 27.14, '22 Jul 2026'),
('69-E9XW-K58N', 'B0GP6KNHLY', false, 'Active', 'Paper Cover Hard Bound New Year Diary 2027 | A5 Size 365 Days Daily Planner Diary with Dates and Month Cut Index For Office, Student & Corporate (AD611)', 'Paper Cover Hard Bound New Year Diary 2027 | A5 Size 365 Days Daily Planner Diary with Dates and Month Cut Index For Office, Student & Corporate (AD611)', 349.00, 349.00, true, 92, 'FBM', 27.14, '19 Feb 2026'),
('25-OIWG-ABYN', 'B0GGRDVK14', false, 'Active', 'Customized 2027 Diary With Name or Text | New Year Diary 2027 with with Dates, 80 GSM Pages PU Leather Finish Hard Bound B5 Size Notebook Diary (Brown - Brown)', 'Customized 2027 Diary With Name or Text | New Year Diary 2027 with with Dates, 80 GSM Pages PU Leather Finish Hard Bound B5 Size Notebook Diary (Brown - Brown)', 449.00, 449.00, true, 996, 'FBM', 27.14, '2 Feb 2026'),
('3R-VDAC-WEY6', 'B0GGR77RJN', false, 'Active', 'Nitaniya Brown Leather Diary Set – Pack of 2 | Premium Ruled Notebook for Office, Study & Daily Journaling B5 Size Notebook Diary (Brown Loopy)', 'Nitaniya Brown Leather Diary Set – Pack of 2 | Premium Ruled Notebook for Office, Study & Daily Journaling B5 Size Notebook Diary (Brown Loopy)', 599.00, 599.00, true, 991, 'FBM', 56.64, '2 Feb 2026'),
('42-PAH6-ZOOW', 'B0GGHL8QGL', true, 'Variations(6)', 'NITANIYA Customized Leather Diary 2026 | A5 Personal Journal with Strap Closure | Ideal Gift for Professionals & Students', 'NITANIYA Customized Leather Diary 2026 | A5 Personal Journal with Strap Closure | Ideal Gift for Professionals & Students', NULL, NULL, NULL, NULL, NULL, 0, '13 Jan 2026'),
('S8-Z9GK-DB16', 'B0GGHKLZ9J', false, 'Active', 'Customised Diary with Name and Photo | Customised Undated Journal Notebooks With Monthly Planner and Calendars 2027 (Size 22 x 15 Cm) (CD510)', 'Customised Diary with Name and Photo | Customised Undated Journal Notebooks With Monthly Planner and Calendars 2027 (Size 22 x 15 Cm) (CD510)', 399.00, 399.00, true, 87, 'FBM', 27.14, '2 Feb 2026'),
('ER-N83P-Q9SB', 'B0GGHB7TJN', false, 'Active', 'Nitaniya Diaries - Customised Diary with Name and Photo | Customised Undated Journal Notebooks With Monthly Planner and Calendars 2027 (Size 22 x 15 Cm) (CD510)', 'Nitaniya Diaries - Customised Diary with Name and Photo | Customised Undated Journal Notebooks With Monthly Planner and Calendars 2027 (Size 22 x 15 Cm) (CD510)', 389.00, 389.00, true, 9977, 'FBM', 27.14, '2 Feb 2026'),
('86-KR14-E5T6', 'B0GGHDXNY1', false, 'Active', '2027 Diary with Dates, Daily Planner, B5 25x17cm, Wood Grey', '2027 Diary with Dates, Daily Planner, B5 25x17cm, Wood Grey', 449.00, 329.00, false, 671, 'FBM', 27.14, '2 Feb 2026'),
('SF-9XEU-GPHT', 'B0GGHJ9WR9', false, 'Active', 'Nitaniya Paper Cover Hard Bound New Year Diary 2027 | A5 Size 365 Days Daily Planner Diary with Dates and Month Cut Index For Office, Student & Corporate (AD611)', 'Nitaniya Paper Cover Hard Bound New Year Diary 2027 | A5 Size 365 Days Daily Planner Diary with Dates and Month Cut Index For Office, Student & Corporate (AD611)', 399.00, NULL, NULL, 959, 'FBM', 27.14, '2 Feb 2026'),
('QY-YN58-84W3', 'B0GGH138YT', false, 'Active', 'NITANIYA 2027 Diary With Name or Text | New Year Diary 2027 with with Dates, 80 GSM Pages PU Leather Finish Premium A5 Size Notebook Diary (Brown Loopy)', 'NITANIYA 2027 Diary With Name or Text | New Year Diary 2027 with with Dates, 80 GSM Pages PU Leather Finish Premium A5 Size Notebook Diary (Brown Loopy)', 399.00, 399.00, true, 982, 'FBM', 27.14, '2 Feb 2026'),
('OR-FZMG-W1H9', 'B0GGH95CVH', false, 'Active', 'Customized 2027 Diary With Name or Text | New Year Diary 2027', 'Customized 2027 Diary With Name or Text | New Year Diary 2027', 399.00, 319.00, false, 748, 'FBM', 27.14, '2 Feb 2026')
ON CONFLICT (sku) DO NOTHING;

INSERT INTO public.amazon_listing_versions (sku, version, source, snapshot)
SELECT l.sku, 1, 'import', crm_private.amz_snapshot(l.sku) FROM public.amazon_listings l
WHERE NOT EXISTS (SELECT 1 FROM public.amazon_listing_versions v WHERE v.sku = l.sku);

-- Priority work, as tasks on the Strategy board (seeded once).
INSERT INTO public.amazon_tasks (title, detail, source)
SELECT t.title, t.detail, 'seed' FROM (VALUES
  ('Win back the Buy Box on B0GGHDXNY1 and B0GGH95CVH',
   'Another seller is on your ASINs at ₹329 and ₹319 (your price ₹449 / ₹399). Price floor is ₹299. Without Brand Registry you cannot block them; compete on price only above the floor, or differentiate the listing.'),
  ('Find out why B0HCZL66NT and B0GGHJ9WR9 show no Buy Box', 'Check Amazon''s listing issues after the first sync.'),
  ('Retitle parent B0GGHL8QGL from 2026 to 2027', 'Parent edit: affects all 6 variations, needs a second confirm.'),
  ('Bring every title to 75 characters or fewer', 'Amazon''s limit since 27 Jul 2026; Amazon rewrites non-compliant titles itself.'),
  ('Fill the Product Brief for each ASIN', 'Claude can only write claims that are listed as facts in the brief.')
) t(title, detail)
WHERE NOT EXISTS (SELECT 1 FROM public.amazon_tasks x WHERE x.source = 'seed');

-- First audit: opens the findings (title length, repeats, 2026 title, Buy Box lost / none).
SELECT crm_private.amz_audit_all();
