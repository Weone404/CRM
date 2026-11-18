-- Local test harness only: what 116 reads from the rest of the CRM (lead columns, Supabase Storage).
ALTER TABLE public.lead ADD COLUMN IF NOT EXISTS course_interest text;
ALTER TABLE public.lead ADD COLUMN IF NOT EXISTS closed boolean NOT NULL DEFAULT false;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.buckets (id text PRIMARY KEY, name text, public boolean);
CREATE TABLE IF NOT EXISTS storage.objects (id bigserial PRIMARY KEY, bucket_id text, name text);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
