-- Scotland 2028: Decisions tab (votes, caddies, drivers, flights, handicap, passport)
-- Already applied to the live database (by hand, Oct 5 2026, before migrations were tracked).
-- Run AFTER 0001_expenses_baseline.sql when rebuilding from scratch.
-- Safe to run again; it replaces the earlier version of this script and keeps existing votes.
--
-- Locking in no longer asks for a code. Anyone who can open the site can submit answers
-- under any name, so every submission is also written to a log only you can read.

-- ---------------------------------------------------------------- votes
-- One row per golfer holding all of their answers. Locking in replaces the row,
-- so the most recent submission always wins.
create table if not exists public.decision_ballots (
  golfer_id  text primary key,
  choices    jsonb not null default '{}'::jsonb,
  locked_at  timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Every submission and every retraction, for the record. Not readable from the website;
-- look at it in Supabase > Table Editor.
create table if not exists public.decision_ballot_log (
  id           bigint generated always as identity primary key,
  golfer_id    text not null,
  choices      jsonb not null,
  submitted_at timestamptz not null default now()
);

alter table public.decision_ballots    enable row level security;
alter table public.decision_ballot_log enable row level security;

drop policy if exists "ballots are readable" on public.decision_ballots;
create policy "ballots are readable" on public.decision_ballots
  for select to anon, authenticated using (true);
grant select on public.decision_ballots to anon, authenticated;
revoke insert, update, delete on public.decision_ballots from anon, authenticated;
revoke all on public.decision_ballot_log from anon, authenticated;

-- the earlier version of this function asked for the group code
drop function if exists public.submit_ballot(text, text, jsonb);

create or replace function public.submit_ballot(p_golfer text, p_choices jsonb)
returns public.decision_ballots
language plpgsql security definer set search_path = public
as $$
declare
  r public.decision_ballots;
begin
  if p_golfer not in ('rich','chris','brandon','jack','mike','cam','jackson','russ') then
    raise exception 'Unknown golfer';
  end if;
  if p_choices is null or jsonb_typeof(p_choices) <> 'object' or length(p_choices::text) > 2000 then
    raise exception 'Selections were not in the expected form';
  end if;

  insert into public.decision_ballots as b (golfer_id, choices, locked_at, updated_at)
  values (p_golfer, p_choices, now(), now())
  on conflict (golfer_id) do update
    set choices = excluded.choices, locked_at = now(), updated_at = now()
  returning * into r;

  insert into public.decision_ballot_log (golfer_id, choices) values (p_golfer, p_choices);
  return r;
end;
$$;

-- "Start over": removes one golfer's votes from the results.
create or replace function public.retract_ballot(p_golfer text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_golfer not in ('rich','chris','brandon','jack','mike','cam','jackson','russ') then
    raise exception 'Unknown golfer';
  end if;
  delete from public.decision_ballots where golfer_id = p_golfer;
  insert into public.decision_ballot_log (golfer_id, choices) values (p_golfer, '{"retracted": true}'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- personal details
-- Handicap, passport date, ticket name, date of birth, Known Traveler Number and airline numbers. The website can write
-- to this table but can NOT read it back. The group only sees traveler_status() below;
-- the full rows need the admin code, or Supabase > Table Editor.
create table if not exists public.traveler_details (
  golfer_id        text primary key,
  handicap_index   numeric(4,1),
  home_club        text,
  certificate_path text,
  passport_expires date,
  known_traveler   text,
  airlines         text,
  updated_at       timestamptz not null default now()
);
alter table public.traveler_details add column if not exists first_name  text;
alter table public.traveler_details add column if not exists middle_name text;
alter table public.traveler_details add column if not exists last_name   text;
alter table public.traveler_details add column if not exists birth_date  date;
alter table public.traveler_details enable row level security;
revoke all on public.traveler_details from anon, authenticated;

-- Save one golfer's details. A null leaves that field as it is; an empty string clears it.
drop function if exists public.save_details(text, text, text, text, text, text, text);
create or replace function public.save_details(
  p_golfer text, p_handicap text default null, p_club text default null, p_certificate text default null,
  p_passport text default null, p_first text default null, p_middle text default null, p_last text default null,
  p_dob text default null, p_ktn text default null, p_airlines text default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_golfer not in ('rich','chris','brandon','jack','mike','cam','jackson','russ') then
    raise exception 'Unknown golfer';
  end if;
  if length(coalesce(p_club,'')) > 80 or length(coalesce(p_ktn,'')) > 20 or length(coalesce(p_airlines,'')) > 400
     or length(coalesce(p_certificate,'')) > 120 or length(coalesce(p_handicap,'')) > 6 or length(coalesce(p_passport,'')) > 10
     or length(coalesce(p_first,'')) > 40 or length(coalesce(p_middle,'')) > 40 or length(coalesce(p_last,'')) > 40 or length(coalesce(p_dob,'')) > 10 then
    raise exception 'One of the details is too long';
  end if;
  if btrim(coalesce(p_handicap,'')) <> '' and (p_handicap !~ '^-?[0-9]{1,2}(\.[0-9])?$' or p_handicap::numeric not between -10 and 54) then
    raise exception 'Handicap index should be a number like 12.4';
  end if;
  if btrim(coalesce(p_passport,'')) <> '' and p_passport !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Passport date was not in the expected form';
  end if;
  if btrim(coalesce(p_dob,'')) <> '' and (p_dob !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or p_dob::date > current_date or p_dob::date < date '1930-01-01') then
    raise exception 'Date of birth does not look right';
  end if;
  if btrim(coalesce(p_certificate,'')) <> '' and p_certificate not like p_golfer || '/%' then
    raise exception 'Certificate file does not belong to this golfer';
  end if;

  insert into public.traveler_details (golfer_id) values (p_golfer) on conflict (golfer_id) do nothing;
  update public.traveler_details set
    handicap_index   = case when p_handicap    is null then handicap_index   when btrim(p_handicap) = ''    then null else p_handicap::numeric end,
    home_club        = case when p_club        is null then home_club        when btrim(p_club) = ''        then null else btrim(p_club) end,
    certificate_path = case when p_certificate is null then certificate_path when btrim(p_certificate) = '' then null else p_certificate end,
    passport_expires = case when p_passport    is null then passport_expires when btrim(p_passport) = ''    then null else p_passport::date end,
    first_name       = case when p_first       is null then first_name       when btrim(p_first) = ''       then null else btrim(p_first) end,
    middle_name      = case when p_middle      is null then middle_name      when btrim(p_middle) = ''      then null else btrim(p_middle) end,
    last_name        = case when p_last        is null then last_name        when btrim(p_last) = ''        then null else btrim(p_last) end,
    birth_date       = case when p_dob         is null then birth_date       when btrim(p_dob) = ''         then null else p_dob::date end,
    known_traveler   = case when p_ktn         is null then known_traveler   when btrim(p_ktn) = ''         then null else btrim(p_ktn) end,
    airlines         = case when p_airlines    is null then airlines         when btrim(p_airlines) = ''    then null else btrim(p_airlines) end,
    updated_at       = now()
  where golfer_id = p_golfer;
end;
$$;

-- What the whole group may see: the index, and yes/no for everything else.
-- The date below must match TRIP.passportMin in index.html (six months after the flight home).
drop function if exists public.traveler_status();
create or replace function public.traveler_status()
returns table (golfer_id text, handicap_index numeric, has_certificate boolean, has_passport boolean,
               passport_ok boolean, has_name boolean, has_dob boolean, has_ktn boolean, has_airlines boolean,
               updated_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select d.golfer_id, d.handicap_index, d.certificate_path is not null, d.passport_expires is not null,
         coalesce(d.passport_expires >= date '2029-03-15', false),
         d.first_name is not null and d.last_name is not null, d.birth_date is not null, d.known_traveler is not null,
         d.airlines is not null, d.updated_at
  from public.traveler_details d;
$$;

-- Admin code only: everyone's full details, for the organiser's view on the Decisions tab.
create or replace function public.admin_details(p_code text)
returns setof public.traveler_details
language plpgsql stable security definer set search_path = public
as $$
begin
  if coalesce(public.code_role(p_code)::text, '') <> 'admin' then
    raise exception 'That code is not valid for this';
  end if;
  return query select * from public.traveler_details order by golfer_id;
end;
$$;

-- Admin code only: wipe one golfer's votes (kept from the earlier version).
create or replace function public.clear_ballot(p_code text, p_golfer text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(public.code_role(p_code)::text, '') <> 'admin' then
    raise exception 'That code is not valid for this';
  end if;
  delete from public.decision_ballots where golfer_id = p_golfer;
end;
$$;

revoke all on function public.submit_ballot(text, jsonb) from public;
revoke all on function public.retract_ballot(text) from public;
revoke all on function public.save_details(text, text, text, text, text, text, text, text, text, text, text) from public;
revoke all on function public.traveler_status() from public;
revoke all on function public.admin_details(text) from public;
revoke all on function public.clear_ballot(text, text) from public;
grant execute on function public.submit_ballot(text, jsonb) to anon, authenticated;
grant execute on function public.retract_ballot(text) to anon, authenticated;
grant execute on function public.save_details(text, text, text, text, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.traveler_status() to anon, authenticated;
grant execute on function public.admin_details(text) to anon, authenticated;
grant execute on function public.clear_ballot(text, text) to anon, authenticated;

-- ---------------------------------------------------------------- handicap certificates
-- A private file bucket. The website can add a file (photo, screenshot or PDF, 5 MB at most)
-- but cannot list, read, replace or delete one. View them in Supabase > Storage > certificates.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('certificates', 'certificates', false, 5242880,
        array['application/pdf','image/png','image/jpeg','image/webp','image/heic','image/heif'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "site can add certificates" on storage.objects;
create policy "site can add certificates" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'certificates');

notify pgrst, 'reload schema';
