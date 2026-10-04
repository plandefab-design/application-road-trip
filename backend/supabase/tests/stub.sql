-- Test double of the parts of Supabase that schema.sql relies on (roles, auth.users, auth.uid(), storage), so the
-- schema and its access rules can be tested on a plain PostgreSQL. Test use only: never run this on Supabase.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create schema storage;

create table auth.users (id uuid primary key default gen_random_uuid(), raw_user_meta_data jsonb default '{}');
-- Supabase reads the signed-in user from the request; here the test sets « app.uid ».
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('app.uid', true), '')::uuid $$;

create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name, '/') $$;
alter table storage.objects enable row level security;

create extension if not exists pgcrypto;
grant usage on schema public, auth, storage to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
grant all on storage.objects, storage.buckets to authenticated;

-- Assertions for the tests: raise on a mismatch, so a failing check stops the script with a non-zero exit code.
create function public.expect(label text, actual double precision, expected double precision) returns void
language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL %: got %, expected %', label, actual, expected; end if;
  raise notice 'ok   %', label;
end $$;

create function public.expect_true(label text, condition boolean) returns void
language plpgsql as $$
begin
  if condition is not true then raise exception 'FAIL %', label; end if;
  raise notice 'ok   %', label;
end $$;

create function public.expect_text(label text, actual text, expected text) returns void
language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL %: got %, expected %', label, actual, expected; end if;
  raise notice 'ok   %', label;
end $$;
