-- Activiteitenlogboek voor de beheerder: de database legt zelf elke wijziging vast (niet te omzeilen via de app)
create table if not exists public.activity_log (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  at timestamptz not null default now(),
  actor_id uuid,
  kind text not null check (kind in ('recipe', 'member', 'invite', 'pantry')),
  action text not null,
  target_id uuid,
  target_label text,
  owner_id uuid,
  before jsonb,
  after jsonb
);
create index if not exists activity_log_household_at on public.activity_log (household_id, at desc);
create index if not exists activity_log_target_at on public.activity_log (target_id, at desc);
alter table public.activity_log enable row level security;
drop policy if exists "Beheerder leest het logboek" on public.activity_log;
create policy "Beheerder leest het logboek" on public.activity_log for select to authenticated using (private.is_admin(household_id));
revoke insert, update, delete on public.activity_log from anon, authenticated;

-- Momentopname van een recept, inclusief ingrediënten
create or replace function private.recipe_snapshot(r public.recipes)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'title', r.title, 'subtitle', r.subtitle, 'servings', r.servings, 'prep_time_minutes', r.prep_time_minutes,
    'tags', to_jsonb(r.tags), 'steps', r.steps, 'tips', r.tips, 'notes', r.notes, 'source_url', r.source_url,
    'photo_path', r.photo_path, 'owner_id', r.owner_id, 'prep_time_estimated', r.prep_time_estimated,
    'ingredients', coalesce((select jsonb_agg(jsonb_build_object('name', i.name, 'amount', i.amount, 'unit', i.unit, 'original_text', i.original_text, 'is_pantry', i.is_pantry) order by i.position)
                             from public.recipe_ingredients i where i.recipe_id = r.id), '[]'::jsonb));
$$;
create or replace function private.logging_paused() returns boolean language sql stable as $$
  select coalesce(current_setting('app.restoring', true), '') = '1';
$$;

-- Recepten: nieuw, gewijzigd, verwijderd
create or replace function private.log_recipe()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); v_open uuid;
begin
  if private.logging_paused() then return coalesce(new, old); end if;
  if tg_op = 'INSERT' then
    insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, owner_id, before, after)
    values (new.household_id, v_actor, 'recipe', 'insert', new.id, new.title, coalesce(new.owner_id, new.created_by), null, private.recipe_snapshot(new));
    return new;
  elsif tg_op = 'UPDATE' then
    -- Alleen een wijziging van import-meldingen of tijdstempels telt niet
    if (to_jsonb(old) - array['updated_at','updated_by','import_notes']) = (to_jsonb(new) - array['updated_at','updated_by','import_notes']) then return new; end if;
    select id into v_open from public.activity_log
      where kind = 'recipe' and target_id = new.id and action in ('insert', 'update') and actor_id is not distinct from v_actor and at > now() - interval '2 minutes'
      order by at desc limit 1;
    if v_open is not null then
      update public.activity_log set after = private.recipe_snapshot(new), target_label = new.title, owner_id = coalesce(new.owner_id, new.created_by) where id = v_open;
    else
      insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, owner_id, before, after)
      values (new.household_id, v_actor, 'recipe', 'update', new.id, new.title, coalesce(new.owner_id, new.created_by), private.recipe_snapshot(old), private.recipe_snapshot(new));
    end if;
    return new;
  else
    -- Vóór het verwijderen, zodat de ingrediënten nog in de momentopname zitten
    insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, owner_id, before, after)
    values (old.household_id, v_actor, 'recipe', 'delete', old.id, old.title, coalesce(old.owner_id, old.created_by), private.recipe_snapshot(old), null);
    return old;
  end if;
end; $$;
drop trigger if exists log_recipe_write on public.recipes;
create trigger log_recipe_write after insert or update on public.recipes for each row execute function private.log_recipe();
drop trigger if exists log_recipe_delete on public.recipes;
create trigger log_recipe_delete before delete on public.recipes for each row execute function private.log_recipe();

-- Ingrediënten (de app vervangt ze in losse stappen): samenvoegen met de wijziging van hetzelfde recept
create or replace function private.log_ingredients()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); rid uuid; ids uuid[]; rec public.recipes; v_open uuid; v_before jsonb; v_after jsonb;
begin
  if private.logging_paused() then return null; end if;
  -- Elke tak noemt alleen de tabellen die bij die bewerking bestaan
  if tg_op = 'INSERT' then select array_agg(distinct recipe_id) into ids from new_rows;
  elsif tg_op = 'DELETE' then select array_agg(distinct recipe_id) into ids from old_rows;
  else select array_agg(distinct recipe_id) into ids from (select recipe_id from old_rows union select recipe_id from new_rows) u;
  end if;
  foreach rid in array coalesce(ids, '{}') loop
    select * into rec from public.recipes where id = rid;
    if not found then continue; end if; -- recept zelf verwijderd: dat is al gelogd
    -- Alleen 'voorraadkast'-vlaggen omgezet (bijv. opnieuw indelen): niet loggen
    if tg_op = 'UPDATE' then
      if not exists (select 1 from old_rows o join new_rows n on n.id = o.id
        where n.recipe_id = rid and (o.name, o.amount, o.unit, o.position) is distinct from (n.name, n.amount, n.unit, n.position)) then continue; end if;
    end if;
    v_after := private.recipe_snapshot(rec);
    select id into v_open from public.activity_log
      where kind = 'recipe' and target_id = rid and action in ('insert', 'update') and actor_id is not distinct from v_actor and at > now() - interval '2 minutes'
      order by at desc limit 1;
    if v_open is not null then
      update public.activity_log set after = v_after where id = v_open returning before into v_before;
      -- Opgeslagen zonder echte wijziging: regel weer weghalen
      if tg_op = 'INSERT' and v_before is not null and (v_before - 'ingredients') = (v_after - 'ingredients')
         and (select coalesce(jsonb_agg(e - 'original_text' - 'is_pantry' order by o), '[]') from jsonb_array_elements(v_before->'ingredients') with ordinality t(e, o))
           = (select coalesce(jsonb_agg(e - 'original_text' - 'is_pantry' order by o), '[]') from jsonb_array_elements(v_after->'ingredients') with ordinality t(e, o)) then
        delete from public.activity_log where id = v_open;
      end if;
    else
      v_before := v_after;
      if tg_op in ('DELETE', 'UPDATE') then
        v_before := jsonb_set(v_after, '{ingredients}', coalesce((
          select jsonb_agg(e order by (e->>'position')::int) from (
            select jsonb_build_object('name', i.name, 'amount', i.amount, 'unit', i.unit, 'original_text', i.original_text, 'is_pantry', i.is_pantry, 'position', i.position) e
            from public.recipe_ingredients i where i.recipe_id = rid and i.id not in (select id from old_rows)
            union all
            select jsonb_build_object('name', o.name, 'amount', o.amount, 'unit', o.unit, 'original_text', o.original_text, 'is_pantry', o.is_pantry, 'position', o.position)
            from old_rows o where o.recipe_id = rid) s), '[]'::jsonb));
      end if;
      insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, owner_id, before, after)
      values (rec.household_id, v_actor, 'recipe', 'update', rid, rec.title, coalesce(rec.owner_id, rec.created_by), v_before, v_after);
    end if;
  end loop;
  return null;
end; $$;
drop trigger if exists log_ingredients_ins on public.recipe_ingredients;
drop trigger if exists log_ingredients_del on public.recipe_ingredients;
drop trigger if exists log_ingredients_upd on public.recipe_ingredients;
create trigger log_ingredients_ins after insert on public.recipe_ingredients referencing new table as new_rows for each statement execute function private.log_ingredients();
create trigger log_ingredients_del after delete on public.recipe_ingredients referencing old table as old_rows for each statement execute function private.log_ingredients();
create trigger log_ingredients_upd after update on public.recipe_ingredients referencing old table as old_rows new table as new_rows for each statement execute function private.log_ingredients();

-- Leden: lid geworden, rol gewijzigd, verwijderd
create or replace function private.log_member()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  select display_name into v_name from public.profiles where id = coalesce(new.user_id, old.user_id);
  if tg_op = 'INSERT' then
    insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, after)
    values (new.household_id, coalesce(auth.uid(), new.user_id), 'member', 'insert', new.user_id, v_name, jsonb_build_object('role', new.role));
  elsif tg_op = 'UPDATE' then
    if new.role is distinct from old.role then
      insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, before, after)
      values (new.household_id, auth.uid(), 'member', 'role', new.user_id, v_name, jsonb_build_object('role', old.role), jsonb_build_object('role', new.role));
    end if;
  else
    insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, before)
    values (old.household_id, auth.uid(), 'member', 'delete', old.user_id, v_name, jsonb_build_object('role', old.role));
  end if;
  return null;
end; $$;
drop trigger if exists log_member_change on public.household_members;
create trigger log_member_change after insert or update or delete on public.household_members for each row execute function private.log_member();

-- Uitnodigingen: aangemaakt en ingetrokken (gebruikt = 'lid geworden')
create or replace function private.log_invite()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, after)
    values (new.household_id, auth.uid(), 'invite', 'insert', new.id, coalesce(new.name, 'zonder naam'), jsonb_build_object('role', new.role));
  elsif old.used_by is null then
    insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, before)
    values (old.household_id, auth.uid(), 'invite', 'delete', old.id, coalesce(old.name, 'zonder naam'), jsonb_build_object('role', old.role));
  end if;
  return null;
end; $$;
drop trigger if exists log_invite_change on public.household_invites;
create trigger log_invite_change after insert or delete on public.household_invites for each row execute function private.log_invite();

-- Voorraadkast
create or replace function private.log_pantry()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.pantry is distinct from old.pantry then
    insert into public.activity_log (household_id, actor_id, kind, action, target_label, before, after)
    values (new.id, auth.uid(), 'pantry', 'update', 'Voorraadkast',
      case when old.pantry is null then null else jsonb_build_object('items', (select coalesce(jsonb_agg(i), '[]') from jsonb_array_elements(old.pantry) g, jsonb_array_elements(g->'items') i)) end,
      jsonb_build_object('items', (select coalesce(jsonb_agg(i), '[]') from jsonb_array_elements(new.pantry) g, jsonb_array_elements(g->'items') i)));
  end if;
  return null;
end; $$;
drop trigger if exists log_pantry_change on public.households;
create trigger log_pantry_change after update of pantry on public.households for each row execute function private.log_pantry();

-- Hoe vaak een recept op een weekmenu is gezet (alleen een teller, niet wie of wanneer)
create table if not exists private.recipe_plan_counts (recipe_id uuid primary key references public.recipes(id) on delete cascade, n int not null default 0);
create or replace function private.count_plan()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.recipe_id is not null then
    insert into private.recipe_plan_counts (recipe_id, n) values (new.recipe_id, 1)
    on conflict (recipe_id) do update set n = private.recipe_plan_counts.n + 1;
  end if;
  return null;
end; $$;
drop trigger if exists count_plan_insert on public.meal_plan;
create trigger count_plan_insert after insert on public.meal_plan for each row execute function private.count_plan();

-- Cijfers voor het beheerdashboard (alleen beheerder)
create or replace function public.admin_usage(p_household uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ws date := date_trunc('week', now())::date;
begin
  if not private.is_admin(p_household) then raise exception 'Alleen de beheerder kan dit bekijken.'; end if;
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'last_active',
        greatest(u.last_sign_in_at, (select max(s.updated_at) from auth.sessions s where s.user_id = m.user_id)))), '[]')
      from public.household_members m join auth.users u on u.id = m.user_id where m.household_id = p_household),
    'recipes_total', (select count(*) from public.recipes where household_id = p_household),
    'recipes_30d', (select count(*) from public.recipes where household_id = p_household and created_at > now() - interval '30 days'),
    'changes_30d', (select count(*) from public.activity_log where household_id = p_household and kind = 'recipe' and at > now() - interval '30 days'),
    'meals_week', (select count(*) from public.meal_plan where household_id = p_household and plan_date between ws and ws + 6),
    'top_planned', (select coalesce(jsonb_agg(jsonb_build_object('title', t.title, 'n', t.n)), '[]') from (
        select r.title, c.n from private.recipe_plan_counts c join public.recipes r on r.id = c.recipe_id
        where r.household_id = p_household order by c.n desc, r.title limit 5) t)
  );
end; $$;
revoke all on function public.admin_usage(uuid) from public, anon;
grant execute on function public.admin_usage(uuid) to authenticated;

-- Eerdere versie van een recept terugzetten (alleen beheerder)
create or replace function public.restore_recipe_version(p_log uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare e public.activity_log; b jsonb; cur public.recipes; v_now jsonb;
begin
  select * into e from public.activity_log where id = p_log;
  if e.id is null or e.kind <> 'recipe' or e.before is null then raise exception 'Deze wijziging kan niet worden teruggezet.'; end if;
  if not private.is_admin(e.household_id) then raise exception 'Alleen de beheerder kan dit terugzetten.'; end if;
  b := e.before;
  perform set_config('app.restoring', '1', true);
  select * into cur from public.recipes where id = e.target_id;
  v_now := case when cur.id is null then null else private.recipe_snapshot(cur) end;
  if cur.id is null then
    insert into public.recipes (id, household_id, title, subtitle, servings, prep_time_minutes, prep_time_estimated, steps, tips, tags, source_url, photo_path, notes, owner_id, created_by, updated_by)
    values (e.target_id, e.household_id, b->>'title', b->>'subtitle', coalesce((b->>'servings')::int, 2), (b->>'prep_time_minutes')::int, coalesce((b->>'prep_time_estimated')::boolean, false),
      coalesce(b->'steps', '[]'), coalesce(b->'tips', '[]'), coalesce(array(select jsonb_array_elements_text(b->'tags')), '{}'), b->>'source_url', b->>'photo_path', b->>'notes',
      (b->>'owner_id')::uuid, auth.uid(), auth.uid());
  else
    update public.recipes set title = b->>'title', subtitle = b->>'subtitle', servings = coalesce((b->>'servings')::int, 2), prep_time_minutes = (b->>'prep_time_minutes')::int,
      prep_time_estimated = coalesce((b->>'prep_time_estimated')::boolean, false), steps = coalesce(b->'steps', '[]'), tips = coalesce(b->'tips', '[]'),
      tags = coalesce(array(select jsonb_array_elements_text(b->'tags')), '{}'), source_url = b->>'source_url', photo_path = b->>'photo_path', notes = b->>'notes',
      owner_id = (b->>'owner_id')::uuid, updated_by = auth.uid(), updated_at = now()
    where id = e.target_id;
    delete from public.recipe_ingredients where recipe_id = e.target_id;
  end if;
  insert into public.recipe_ingredients (recipe_id, position, name, amount, unit, original_text, is_pantry)
  select e.target_id, (x.ord - 1)::int, x.v->>'name', (x.v->>'amount')::numeric, x.v->>'unit', x.v->>'original_text', coalesce((x.v->>'is_pantry')::boolean, false)
  from jsonb_array_elements(coalesce(b->'ingredients', '[]')) with ordinality as x(v, ord);
  perform set_config('app.restoring', '', true);
  insert into public.activity_log (household_id, actor_id, kind, action, target_id, target_label, owner_id, before, after)
  values (e.household_id, auth.uid(), 'recipe', 'restore', e.target_id, b->>'title', (b->>'owner_id')::uuid, v_now, b);
  return e.target_id;
end; $$;
revoke all on function public.restore_recipe_version(uuid) from public, anon;
grant execute on function public.restore_recipe_version(uuid) to authenticated;

-- Logboek 3 maanden bewaren
create or replace function private.cleanup_activity_log() returns void language sql security definer set search_path = '' as $$
  delete from public.activity_log where at < now() - interval '3 months';
$$;
select cron.schedule('logboek-opruimen', '25 4 * * *', 'select private.cleanup_activity_log()');
