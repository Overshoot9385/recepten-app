-- Soort gerecht (gang) per recept; meerdere mogelijk. Toegepast op 15 nov 2026.
-- De bestaande recepten zijn daarna eenmalig ingedeeld, en de tags ontbijt, soep, salade, snack, dessert, bakken en taart zijn uit de tags gehaald.
alter table public.recipes add column if not exists courses text[] not null default '{}'
  check (courses <@ array['ontbijt','lunch','voorgerecht','soep','salade','hoofdgerecht','bijgerecht','saus','snack','nagerecht','bakken']::text[]);
-- private.recipe_snapshot en public.restore_recipe_version nemen 'courses' mee (zie de live definities).
