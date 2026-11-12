# Momentopname: Tom's Receptenboek vóór het redesign

Vastgelegd op **12 november 2026**, vlak voordat het redesign begon.
Laatste commit: `3ecd684`, "Gebruiksstatistieken in Beheer met tijdschaal en per persoon".

## Waar staat wat

| Wat | Waar | Hoe terug |
|---|---|---|
| Code (app, service worker, iconen, Edge Function) | Branch **`versie-voor-redesign`** op GitHub | Zie "Terug naar deze versie" hieronder |
| Database: alle gegevens | Schema **`backup_voor_redesign`** in Supabase-project `recepten-app` (`eyhdbqnjyjwyjxwjiwkn`) | Tabellen heten `public__recipes`, `private__usage_daily` enz. |
| Database: structuur (kolommen, functies, RLS-regels, triggers, indexen, cron) | Tabel `backup_voor_redesign._schema_defs` | Kolom `definition` bevat de SQL per onderdeel |
| Foto's (buckets `recipe-photos`, `avatars`) | Niet gekopieerd. Ze blijven staan in Supabase Storage | Niet nodig, zolang het redesign geen foto's verwijdert |

Het redesign zelf gebeurt op de branch **`redesign`**. `main` blijft de live versie op GitHub Pages tot het redesign af is.

## Terug naar deze versie

**Alleen de vormgeving en code terugzetten** (meestal genoeg):
```bash
git fetch origin
git checkout main
git reset --hard origin/versie-voor-redesign
git push --force origin main
```
GitHub Pages toont dan binnen een paar minuten weer deze versie. Gebruikers moeten de app één keer verversen, want de service worker houdt een oude versie in de cache.

**Ook de gegevens terugzetten** (alleen als het redesign de database heeft veranderd): voer dit per tabel uit in de Supabase SQL Editor, en begin bij tabellen zonder afhankelijkheden (`households` → `household_members`/`profiles` → `recipes` → `recipe_ingredients` → de rest):
```sql
-- voorbeeld voor recepten; let op: dit overschrijft de huidige inhoud
truncate public.recipes cascade;
insert into public.recipes select * from backup_voor_redesign.public__recipes;
```
Zijn er inmiddels kolommen bij gekomen of verwijderd, zet de structuur dan eerst terug met de definities uit `_schema_defs`, of vraag Claude om dat te doen.

## Hoe de app er nu uitziet

- **Eén bestand:** `index.html` (vanilla JS, geen framework), PWA met `manifest.webmanifest` en `sw.js`. Naam op het beginscherm: "Tom's Recepten".
- **Kleuren (licht):** achtergrond `#F4F6F1` (groen getint papier), vlakken `#FFFFFF`, verzonken `#E8ECE4`, tekst `#18241D`, gedempt `#5F6D63`, lijnen `#D5DCD0`, hoofdkleur basilicumgroen `#2F6B4F`, accent saffraan `#E3A02F` (favorieten, porties), fout `#B3402E`.
- **Kleuren (donker):** achtergrond `#111814`, vlakken `#19221C`, tekst `#E9EFE9`, groen `#6FB892`, saffraan `#F0B54E`. Weergave instelbaar: licht, donker of systeem.
- **Lettertypes:** koppen in Bricolage Grotesque (600/800), tekst in Figtree (400–700). Afrondingen 14px.
- **Navigatie:** tabbalk onderin met Recepten, Weekmenu, Boodschappen, en voor beheerders Beheer (met stip bij nieuwe tips).

## Schermen en functies

- **Recepten ("Wat koken we?"):** lijst met zoeken, filteren op tags (en/of), sorteren, favorieten.
- **Recept-detail:** ingrediënten (porties schaalbaar), bereiding, kooktips, beoordeling, notities, bron-link.
- **Recept bewerken / toevoegen:** handmatig, via link (Edge Function `recept-ophalen`), via geplakte tekst uit Notes, of Instagram-bijschrift. Bereidingstijd kan geschat zijn.
- **Koelkast-zoeker:** "wat kan ik maken met wat ik heb", gratis ingrediëntmatching zonder AI. Voorraadkast per huishouden.
- **Weekmenu:** persoonlijk, of gedeeld via een plangroep (partnerverzoek). Recept of los gerecht per maaltijd.
- **Boodschappen:** lijst uit weekmenu of handmatig, voorraad checken, gedeeld binnen plangroep.
- **Huishouden en leden:** uitnodigen met code (aanmelden kan alleen met geldige code), rollen beheerder, bewerker en kijker, emoji als avatar (geen foto's).
- **Beheer (alleen beheerder):** gebruiksstatistieken met tijdschaal en per persoon, activiteitenlog van recepten/leden/uitnodigingen/voorraad met herstelknop, tips/feedback van leden. Bewaartermijn 3 maanden.
- **Instellingen:** weergave, wachtwoord wijzigen, op beginscherm zetten.
- **Inloggen:** e-mail en wachtwoord, geen Apple/Google-login. E-mailbevestiging staat uit.

## Database in het kort

Tabellen in `public`: `households`, `household_members`, `household_invites`, `profiles`, `recipes`, `recipe_ingredients`, `favorites`, `meal_plan`, `plan_groups`, `plan_members`, `plan_requests`, `shopping_items`, `activity_log`, `feedback`.
In `private`: `usage_daily`, `recipe_opens_daily`, `recipe_plan_counts`, plus hulpfuncties voor RLS (`is_household_member`, `can_edit`, `is_admin`, `my_plan_group`) en logging.
Alle tabellen hebben Row Level Security aan.

Aantallen op het moment van de momentopname: 148 recepten, 1.958 ingrediëntregels, 7 leden, 1 huishouden.
