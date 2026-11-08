-- Gebruiksstatistieken voor de beheerder: alleen aantallen per persoon per dag,
-- en per recept hoe vaak het geopend is (zonder wie). 3 maanden bewaard.

create table if not exists private.usage_daily (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null default current_date,
  opens int not null default 0,
  meals int not null default 0,
  items_added int not null default 0,
  items_checked int not null default 0,
  primary key (household_id, user_id, day)
);

create table if not exists private.recipe_opens_daily (
  household_id uuid not null references public.households(id) on delete cascade,
  recipe_id uuid not null references public.recipes(id) on delete cascade,
  day date not null default current_date,
  n int not null default 0,
  primary key (household_id, recipe_id, day)
);
create index if not exists recipe_opens_daily_day on private.recipe_opens_daily (household_id, day);

create or replace function private.bump_usage(p_household uuid, p_user uuid, p_col text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_household is null or p_user is null then return; end if;
  insert into private.usage_daily (household_id, user_id, day,
    opens, meals, items_added, items_checked)
  values (p_household, p_user, current_date,
    (p_col = 'opens')::int, (p_col = 'meals')::int, (p_col = 'items_added')::int, (p_col = 'items_checked')::int)
  on conflict (household_id, user_id, day) do update set
    opens = private.usage_daily.opens + excluded.opens,
    meals = private.usage_daily.meals + excluded.meals,
    items_added = private.usage_daily.items_added + excluded.items_added,
    items_checked = private.usage_daily.items_checked + excluded.items_checked;
end; $$;

-- Recept geopend (aangeroepen door de app)
create or replace function public.log_recipe_open(p_recipe uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare hid uuid;
begin
  select household_id into hid from public.recipes where id = p_recipe;
  if hid is null or auth.uid() is null or not private.is_household_member(hid) then return; end if;
  perform private.bump_usage(hid, auth.uid(), 'opens');
  insert into private.recipe_opens_daily (household_id, recipe_id, day, n) values (hid, p_recipe, current_date, 1)
  on conflict (household_id, recipe_id, day) do update set n = private.recipe_opens_daily.n + 1;
end; $$;
revoke all on function public.log_recipe_open(uuid) from public, anon;
grant execute on function public.log_recipe_open(uuid) to authenticated;

-- Weekmenu en boodschappen tellen via triggers
create or replace function private.count_usage_meal() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.bump_usage(new.household_id, coalesce(auth.uid(), new.user_id), 'meals');
  return null;
end; $$;

create or replace function private.count_usage_shop() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.bump_usage(new.household_id, coalesce(auth.uid(), new.user_id), 'items_added');
  elsif new.is_checked and not coalesce(old.is_checked, false) then
    perform private.bump_usage(new.household_id, coalesce(auth.uid(), new.user_id), 'items_checked');
  end if;
  return null;
end; $$;

drop trigger if exists count_usage_meal on public.meal_plan;
create trigger count_usage_meal after insert on public.meal_plan
  for each row execute function private.count_usage_meal();
drop trigger if exists count_usage_shop on public.shopping_items;
create trigger count_usage_shop after insert or update of is_checked on public.shopping_items
  for each row execute function private.count_usage_shop();

-- Overzicht voor de beheerder
create or replace function public.admin_stats(p_household uuid, p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare since date := current_date - (least(greatest(coalesce(p_days, 30), 1), 92) - 1);
begin
  if not private.is_admin(p_household) then raise exception 'Alleen de beheerder kan dit bekijken.'; end if;
  return jsonb_build_object(
    'series', (select coalesce(jsonb_agg(jsonb_build_object('day', g.day, 'opens', coalesce(x.opens, 0), 'meals', coalesce(x.meals, 0), 'items', coalesce(x.items, 0)) order by g.day), '[]')
      from (select generate_series(since, current_date, interval '1 day')::date as day) g
      left join (select day, sum(opens) opens, sum(meals) meals, sum(items_added + items_checked) items
                 from private.usage_daily where household_id = p_household and day >= since group by day) x on x.day = g.day),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id,
        'opens', coalesce(x.opens, 0), 'meals', coalesce(x.meals, 0), 'items_added', coalesce(x.items_added, 0),
        'items_checked', coalesce(x.items_checked, 0), 'active_days', coalesce(x.days, 0))), '[]')
      from public.household_members m
      left join (select user_id, sum(opens) opens, sum(meals) meals, sum(items_added) items_added, sum(items_checked) items_checked, count(*) days
                 from private.usage_daily where household_id = p_household and day >= since group by user_id) x on x.user_id = m.user_id
      where m.household_id = p_household),
    'top_opened', (select coalesce(jsonb_agg(jsonb_build_object('title', t.title, 'n', t.n)), '[]') from (
        select r.title, sum(o.n) n from private.recipe_opens_daily o join public.recipes r on r.id = o.recipe_id
        where o.household_id = p_household and o.day >= since group by r.title order by sum(o.n) desc, r.title limit 6) t)
  );
end; $$;
revoke all on function public.admin_stats(uuid, int) from public, anon;
grant execute on function public.admin_stats(uuid, int) to authenticated;

-- Opruimen na 3 maanden (zelfde nachtelijke taak als het logboek)
create or replace function private.cleanup_activity_log() returns void language sql security definer set search_path = '' as $$
  delete from public.activity_log where at < now() - interval '3 months';
  delete from private.usage_daily where day < current_date - interval '3 months';
  delete from private.recipe_opens_daily where day < current_date - interval '3 months';
$$;
