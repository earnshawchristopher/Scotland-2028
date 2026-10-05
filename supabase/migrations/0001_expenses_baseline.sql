-- Scotland 2028: Expenses tab baseline (expenses, trip_settings, code functions)
-- Reconstructed from the live Scotland-2028 database on Oct 5, 2026, because the original
-- setup script was never saved to the project. It is already applied; this file is the record.
-- Safe to run on an empty database to rebuild from scratch. Run before 0002_decisions.sql.
--
-- The two codes are NOT in this file. After running it on a new database, add them by hand:
--   insert into public.trip_settings (key, value) values ('entry_code', '...'), ('admin_code', '...');

-- ---------------------------------------------------------------- tables
create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  spent_on    date not null,
  description text not null check (char_length(description) >= 1 and char_length(description) <= 80),
  amount      numeric not null check (amount > 0),
  currency    text not null check (currency = any (array['GBP','USD'])),
  paid_by     text not null,
  split_among text[] not null check (array_length(split_among, 1) >= 1),
  category    text,
  added_by    text
);

create table if not exists public.trip_settings (
  key   text primary key,
  value text not null
);

alter table public.expenses      enable row level security;
alter table public.trip_settings enable row level security;

-- Anyone with the site can read expenses. Nothing can be written directly;
-- all writes go through the functions below. trip_settings has no policy, so it is unreadable.
drop policy if exists "Anyone can read expenses" on public.expenses;
create policy "Anyone can read expenses" on public.expenses
  for select to anon using (true);

-- ---------------------------------------------------------------- functions
-- Returns 'admin', 'entry' or null for a code.
create or replace function public.code_role(p_code text)
returns text
language sql security definer set search_path = public
as $$
  select case key when 'admin_code' then 'admin' else 'entry' end
  from trip_settings
  where key in ('admin_code', 'entry_code') and value = p_code
  order by (key = 'admin_code') desc
  limit 1;
$$;

create or replace function public.add_expense(
  p_code text, p_spent_on date, p_description text, p_amount numeric, p_currency text,
  p_paid_by text, p_split_among text[], p_category text, p_added_by text)
returns public.expenses
language plpgsql security definer set search_path = public
as $$
declare r public.expenses;
begin
  if public.code_role(p_code) is null then raise exception 'Wrong code'; end if;
  insert into expenses (spent_on, description, amount, currency, paid_by, split_among, category, added_by)
  values (p_spent_on, p_description, p_amount, p_currency, p_paid_by, p_split_among, p_category, p_added_by)
  returning * into r;
  return r;
end $$;

create or replace function public.update_expense(
  p_code text, p_id uuid, p_spent_on date, p_description text, p_amount numeric, p_currency text,
  p_paid_by text, p_split_among text[], p_category text)
returns public.expenses
language plpgsql security definer set search_path = public
as $$
declare r public.expenses;
begin
  if public.code_role(p_code) is distinct from 'admin' then raise exception 'Admin code required'; end if;
  update expenses set spent_on = p_spent_on, description = p_description, amount = p_amount, currency = p_currency,
         paid_by = p_paid_by, split_among = p_split_among, category = p_category, updated_at = now()
  where id = p_id returning * into r;
  if r.id is null then raise exception 'That expense no longer exists'; end if;
  return r;
end $$;

create or replace function public.delete_expense(p_code text, p_id uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if public.code_role(p_code) is distinct from 'admin' then raise exception 'Admin code required'; end if;
  delete from expenses where id = p_id;
  return true;
end $$;

revoke all on function public.code_role(text) from public;
revoke all on function public.add_expense(text, date, text, numeric, text, text, text[], text, text) from public;
revoke all on function public.update_expense(text, uuid, date, text, numeric, text, text, text[], text) from public;
revoke all on function public.delete_expense(text, uuid) from public;
grant execute on function public.code_role(text) to anon, authenticated;
grant execute on function public.add_expense(text, date, text, numeric, text, text, text[], text, text) to anon, authenticated;
grant execute on function public.update_expense(text, uuid, date, text, numeric, text, text, text[], text) to anon, authenticated;
grant execute on function public.delete_expense(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
