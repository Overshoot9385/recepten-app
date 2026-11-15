-- Gedeelde productenlijst: welke afdeling hoort bij welk product (voor alle gebruikers van het receptenboek).
-- Iedereen mag een nieuw product toevoegen; alleen de beheerder mag bestaande producten wijzigen of verwijderen.
create table if not exists public.shop_products (
  household_id uuid not null references public.households(id) on delete cascade,
  key text not null,
  name text not null,
  aisle text not null check (aisle in ('groente','brood','vlees','zuivel','dkw','diepvries','overig')),
  source text not null default 'user' check (source in ('user','admin')),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (household_id, key)
);
alter table public.shop_products enable row level security;
create policy "Leden zien producten" on public.shop_products for select to authenticated
  using (private.is_household_member(household_id));
create policy "Leden voegen nieuwe producten toe" on public.shop_products for insert to authenticated
  with check (private.is_household_member(household_id) and created_by = (select auth.uid())
              and (source = 'user' or private.is_admin(household_id)));
create policy "Beheerder wijzigt producten" on public.shop_products for update to authenticated
  using (private.is_admin(household_id)) with check (private.is_admin(household_id));
create policy "Beheerder verwijdert producten" on public.shop_products for delete to authenticated
  using (private.is_admin(household_id));
insert into public.shop_products (household_id, key, name, aisle, source, created_by)
select h.id, e.key, e.key, e.value #>> '{}', 'admin', null
from public.households h, jsonb_each(h.shop_sections) e
where (e.value #>> '{}') in ('groente','brood','vlees','zuivel','dkw','diepvries','overig')
on conflict do nothing;
-- Afdeling per regel op de lijst (eigen keuze die alleen voor die lijst geldt)
alter table public.shopping_items add column if not exists aisle text
  check (aisle is null or aisle in ('groente','brood','vlees','zuivel','dkw','diepvries','overig'));
