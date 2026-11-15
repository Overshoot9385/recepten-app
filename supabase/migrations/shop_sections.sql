-- Afdeling per product op de boodschappenlijst, door de beheerder gecorrigeerd voor iedereen.
-- Sleutel: genormaliseerde productnaam, waarde: afdeling (groente, brood, vlees, zuivel, dkw, diepvries, overig).
-- Lezen en wijzigen vallen onder de bestaande RLS van households (leden lezen, beheerder wijzigt).
alter table public.households
  add column if not exists shop_sections jsonb not null default '{}'::jsonb;
