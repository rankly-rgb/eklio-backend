-- ============================================================================
-- Tests — the tenancy layer, and the enumeration of every table in it
-- ============================================================================
-- THE FOURTH ENUMERATION IN THIS PROJECT. Routes are enumerated in the
-- frontend, the funnel's reach into the product is enumerated, functions are
-- enumerated by `20260911170458_function_surface.test.sql`, and tables are
-- enumerated here.
--
-- ── WHAT THIS FILE IS ACTUALLY FOR ──────────────────────────────────────────
--
-- Not to check that `organizations` exists. To make the NEXT table a decision.
--
-- Every table in `public` must fall into one of four classes, and three of
-- them are computed rather than declared:
--
--   0. THE LAYER itself — projects, profiles, organizations, members.
--   1. TENANTED — it reaches `projects` through foreign keys that already
--      exist, so it reaches an organization for free. 22 tables today.
--   2. PER PERSON, BY DECISION — it reaches a person but not a project, and
--      somebody decided it stays per person. Three tables, each named below
--      with its reason.
--   3. NEVER TENANTED — reference data and Eklio's own instruments. Giving
--      `funnel_events` an organization_id would make Eklio's funnel into a
--      customer's data.
--
-- A new table that reaches a project needs nothing. A new table that does not
-- FAILS THIS FILE until somebody writes its name into list 2 or list 3 and
-- says why. That is the whole mechanism: the cost of a new untenanted table is
-- one sentence of justification, paid at the time, by the person who knows.
--
-- ⚠ THE CLOSURE FOLLOWS `auth.users` AS WELL AS `public.profiles`. The first
-- version did not, and it silently classified `comp_grants` — whose user_id
-- references auth.users directly — as owned by nobody. A table can hang off a
-- person through either, and a classifier that knows only one produces a
-- plausible answer, which is this codebase's characteristic failure.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 0. Anti-vacuous: the sweep finds a schema at all
-- ---------------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r';
  assert v_n > 50, format('only %s tables found in public — the sweep is broken', v_n);

  select count(*) into v_n
    from pg_constraint con join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where con.contype = 'f' and n.nspname = 'public';
  assert v_n > 40, format('only %s foreign keys found — the closure is broken', v_n);
end
$$;

-- ---------------------------------------------------------------------------
-- 1. ⚠ THE ENUMERATION
-- ---------------------------------------------------------------------------
create temp view tenancy_class as
with recursive fk as (
  select con.conrelid::regclass::text as child,
         replace(con.confrelid::regclass::text, 'public.', '') as parent
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where con.contype = 'f' and n.nspname = 'public'
     and con.confrelid <> con.conrelid
),
to_projects as (
  select child as t from fk where parent = 'projects'
  union
  select f.child from fk f join to_projects r on f.parent = r.t
),
to_person as (
  -- Both roots. See the header: one of them alone gets `comp_grants` wrong.
  select child as t from fk where parent in ('profiles', 'auth.users')
  union
  select f.child from fk f join to_person r on f.parent = r.t
),
all_tables as (
  select c.relname as t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
)
select t,
       case
         when t in ('projects', 'profiles', 'organizations', 'organization_members') then 'layer'
         when t in (select t from to_projects) then 'tenanted'
         when t in (select t from to_person)   then 'per_person'
         else 'no_owner'
       end as class
  from all_tables;

/*
 * ── LIST 2: PER PERSON, BY DECISION ─────────────────────────────────────────
 *
 * Each of these reaches a person and not a project. Being on this list means
 * somebody asked "per clinician or per practice?" and answered. It does not
 * mean "we haven't got to it yet" — that state is what this file exists to
 * make impossible.
 *
 *   check_rewrite_usage  A DAILY CEILING ON ONE PERSON'S REWRITES. Per
 *                        clinician is the decision: the ceiling exists because
 *                        each rewrite costs a model call made by a human being
 *                        sitting at a screen, and two clinicians in a practice
 *                        are two people doing that. A per-practice ceiling
 *                        would make the second clinician's afternoon depend on
 *                        the first one's morning.
 *
 *   subscriptions        PER-SEAT BILLING IS EXPLICITLY NOT OCTOBER. A
 *                        subscription belongs to the person who pays, and
 *                        today that is always the owner. The day it belongs to
 *                        a practice is the day per-seat billing is designed,
 *                        and it will move then, deliberately, not by drift.
 *
 *   comp_grants          Eklio's own act, outside the product, denied to every
 *                        browser (20260911180918). It grants access to a
 *                        PERSON, which is what a comp is. Never a practice —
 *                        comping a practice is a commercial decision nobody
 *                        has taken.
 */
create temp table per_person_by_decision(t text primary key);
insert into per_person_by_decision values
  ('check_rewrite_usage'), ('subscriptions'), ('comp_grants'),
  /*
   * ── `credit_ledger` et `credit_balances` — LA DÉCISION SUIT L'ARGENT ────
   *
   * Toutes les autres tables de Content sont clefées sur `brand_kit_id`, et
   * celles-ci ne le sont pas. Ce n'est pas une inattention, c'est la même
   * décision que `subscriptions` juste au-dessus, prise pour la même raison :
   *
   *   Monthly Presence s'achète UNE FOIS PAR PERSONNE.
   *   `subscriptions.user_id` est `not null unique` — un abonnement par
   *   compte, jamais un par kit.
   *
   * Un compteur de régénérations remis à zéro par kit se multiplierait donc
   * par le nombre de kits qu'elle possède, et `countUnpaidProjects` lui en
   * laisse trois. Dix régénérations par mois deviendraient trente pour un
   * seul abonnement, sans que personne l'ait décidé.
   *
   * Le contenu, lui, reste par kit : une caption appartient à une marque. Le
   * pont entre les deux est `brand_kits → projects.user_id`, la jointure que
   * chaque policy de Content fait déjà.
   *
   * ⚠ CE QUE ÇA COÛTE DANS UN CABINET À DEUX. Le même que `subscriptions`
   * coûte aujourd'hui, et pas un de plus : l'abonnement et son allocation
   * appartiennent à la personne qui l'a pris. Le jour où un cabinet achète des
   * sièges, c'est `subscriptions` qui devra répondre en premier, et ces deux
   * tables-ci la suivront — jamais l'inverse.
   */
  ('credit_ledger'), ('credit_balances');

/*
 * ── LIST 3: NEVER TENANTED ──────────────────────────────────────────────────
 *
 * Two kinds, and the distinction matters more than the list.
 *
 * REFERENCE DATA — the vocabularies the brief is built out of. The same for
 * everybody, owned by nobody, readable by everybody who is asked to choose
 * from them.
 *
 * EKLIO'S OWN INSTRUMENTS — the funnel, the spend counters, the Stripe event
 * log, the settings table. ⚠ These must NEVER gain an organization_id. Not
 * because it would be hard, but because the column would be a claim that this
 * data is a customer's, and it is not: it is Eklio's measurement of its own
 * business. `funnel_events` with an organization_id is one join away from a
 * screen that says "twelve practitioners chose this direction".
 */
create temp table never_tenanted(t text primary key);
insert into never_tenanted values
  -- Reference data: the vocabularies.
  ('asset_catalog'), ('builder_targets'), ('client_persona_cards'), ('color_names'),
  ('content_registers'), ('degrees'), ('ethics_rules'), ('gain_cards'), ('license_types'),
  /*
   * `degrees` — les diplômes. Une université les délivre, aucun board ne les
   * accorde ni ne les retire : c'est du vocabulaire, pas la donnée d'une
   * cliente. Elle est séparée de `license_types` parce qu'un diplôme
   * n'autorise à exercer nulle part, et c'est cette séparation qui permet à la
   * garde déontologique d'accepter « PsyD » en refusant « psychologist ».
   */
  /*
   * `license_type_states` — QUELLE juridiction délivre QUEL titre. Du
   * vocabulaire, au même titre que `license_types` dont elle est l'annexe :
   * elle décrit les États-Unis, pas une cliente. Lui donner un
   * organization_id prétendrait qu'une praticienne possède la nomenclature de
   * son board.
   */
  ('license_type_states'),
  ('modality_cards'), ('modality_prominence_options'), ('not_a_fit_cards'),
  ('palette_families'), ('plans'), ('primary_actions'), ('problem_cards'),
  ('section_types'), ('session_style_cards'), ('site_goals'),
  ('site_output_templates'), ('specialties'), ('tone_cards'), ('type_pairings'),
  ('banned_phrases'), ('usp_stopwords'),
  /*
   * `credit_quotas` — combien d'actes de chaque sorte un PLAN donne par mois.
   * Du vocabulaire tarifaire : les huit lignes décrivent l'offre, pas une
   * cliente. Le fait qui appartient à quelqu'un est `credit_balances`, qui
   * porte un `user_id` et est clefée dessus.
   *
   * ⚠ ET ELLE EST LUE PAR TOUT LE MONDE, VOLONTAIREMENT. Le compteur de
   * crédits (`credit_meter`) doit pouvoir dire « swaps illimités » à qui n'a
   * encore rien dépensé, donc avant qu'aucune ligne de solde n'existe. Lui
   * donner un propriétaire prétendrait que le plafond d'une praticienne diffère
   * de celui d'une autre à plan égal — ce qui n'est pas l'offre, et ce qui
   * ferait du barème une donnée à tenir par compte.
   */
  ('credit_quotas'),
  /*
   * `site_platforms` — which website platforms Eklio will publish to. The same
   * for everybody, owned by nobody, and READ BEFORE THERE IS ANYBODY: the
   * qualification happens at signup, so an anonymous visitor with no project
   * and no account must be able to see the list to learn that hers is not on
   * it. An organization_id on this table would be a claim that one practice's
   * list of supported platforms differs from another's, which is not a product
   * anyone has asked for.
   */
  ('site_platforms'),
  /*
   * `site_pages` — which page keys a site specification may carry. Reference
   * data in the strictest sense: `site_spec_page_keys()` reads it and
   * `site_spec_pages_valid()` reads that, so it is read from inside a CHECK
   * constraint, on every write, for every practice. An organization_id here
   * would mean one practice's site may carry a page another's may not — which
   * would make the same specification valid for one customer and invalid for
   * the next, decided by a column nobody looks at.
   */
  ('site_pages'),
  /*
   * `ethics_patterns` — the deterministic advertising-ethics patterns. The
   * same six rules bind every licensed clinician in the United States: they
   * come from the ACA Code of Ethics, the APA Ethics Code and state licensing
   * boards, not from anything a practice decides. An organization_id here
   * would say one practice may advertise what another may not, which is not a
   * thing Eklio is entitled to offer.
   *
   * Its sibling `ethics_rules` is already on this list, two lines up.
   */
  ('ethics_patterns'),
  -- Eklio's own instruments. Never a customer's data.
  ('anon_generation_counters'), ('app_settings'), ('brand_image_daily_spend'),
  ('direction_asset_daily_spend'), ('funnel_events'), ('funnel_steps'),
  ('stripe_events');

do $$
declare unclassified text;
begin
  select string_agg(c.t, ', ' order by c.t) into unclassified
    from tenancy_class c
   where c.class = 'no_owner'
     and c.t not in (select t from never_tenanted);

  assert unclassified is null, coalesce(
    'These tables reach neither a project nor a person, and nobody has said why: '
    || unclassified || E'\n'
    || 'Add each to `per_person_by_decision` or `never_tenanted` in this file, '
    || 'WITH THE REASON — or give it a foreign key that reaches `projects`, '
    || 'which is the answer in most cases and costs nothing.', '');
end
$$;

do $$
declare unclassified text;
begin
  select string_agg(c.t, ', ' order by c.t) into unclassified
    from tenancy_class c
   where c.class = 'per_person'
     and c.t not in (select t from per_person_by_decision);

  assert unclassified is null, coalesce(
    'These tables hang off a PERSON rather than a project, which with two '
    || 'members in one practice is a decision, not a default: ' || unclassified
    || E'\n' || 'Name each in `per_person_by_decision` with the reason, or give '
    || 'it a path to `projects`.', '');
end
$$;

-- ⚠ AND THE LISTS MUST NOT ROT. A name left behind after its table is dropped
-- or tenanted is a name that silently exempts nothing — until someone creates
-- a table with that name again.
do $$
declare stale text;
begin
  select string_agg(t, ', ' order by t) into stale
    from (select t from never_tenanted union all select t from per_person_by_decision) l
   where not exists (select 1 from tenancy_class c where c.t = l.t);
  assert stale is null, coalesce(
    'Named in this file but no longer a table in public: ' || stale
    || '. Remove the name.', '');

  select string_agg(l.t, ', ' order by l.t) into stale
    from (select t from never_tenanted union all select t from per_person_by_decision) l
    join tenancy_class c on c.t = l.t
   where c.class in ('tenanted', 'layer');
  assert stale is null, coalesce(
    'Named as untenanted but now reaches a project on its own: ' || stale
    || '. Remove the name — the foreign key is the better answer and it is '
    || 'already there.', '');
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Every table says what it allows. RLS on with no policy at all is silent.
-- ---------------------------------------------------------------------------
do $$
declare silent text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into silent
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'public' and p.tablename = c.relname);
  assert silent is null, coalesce(
    'RLS on and not one policy: ' || silent || E'\n'
    || 'The effect (deny everything to the browser) may well be right, but it '
    || 'reads identically to a forgotten policy. Write it out: '
    || '`for all using (false) with check (false)`.', '');
end
$$;

-- And every table has RLS on in the first place, which `rls_auto_enable` does
-- automatically — this asserts the event trigger is still doing it.
do $$
declare open_tables text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into open_tables
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  assert open_tables is null, coalesce(
    'RLS is off on: ' || open_tables, '');
end
$$;

-- ---------------------------------------------------------------------------
-- 3. The layer's own invariants
-- ---------------------------------------------------------------------------
do $$
declare v_n integer; v_roles text;
begin
  /*
   * Two roles, and the list is closed.
   *
   * ⚠ NAMED, NOT "THE CHECK CONSTRAINT". This read was
   * `where conrelid = ... and contype = 'c'` with no name, which was true
   * while the table had exactly one check and silently picked an arbitrary
   * one the moment 20260911195907 added two more — reporting the status shape
   * as though it were the role list. Written in the same session as the
   * standing rule about hand-written singulars, and caught by CI within the
   * hour.
   */
  select pg_get_constraintdef(oid) into v_roles
    from pg_constraint
   where conrelid = 'public.organization_members'::regclass
     and conname = 'organization_members_role_check';
  assert v_roles like '%owner%' and v_roles like '%clinician%',
    format('the role check is not the two agreed roles: %s', v_roles);
  assert v_roles not like '%admin%' and v_roles not like '%member%',
    format('a third role appeared without a decision: %s', v_roles);

  -- One owned organization per person, by index rather than by care.
  assert exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and indexname = 'organization_members_one_owned_org_per_user'),
    'organization_members_one_owned_org_per_user is gone — the claim''s scalar '
    'subquery can now return two rows and raise 21000 at runtime';

  -- ⚠ AND IT MUST EXCLUDE NON-ACTIVE ROWS. Since the invitation lives on the
  -- membership row (20260911195907), a removed owner would otherwise block the
  -- same person from owning anywhere else, forever.
  assert (select indexdef from pg_indexes
           where schemaname = 'public'
             and indexname = 'organization_members_one_owned_org_per_user')
         like '%status%',
    'the owner index no longer filters on status — a removed owner blocks the person for good';

  -- The constraint that makes the claim together-or-neither.
  assert exists (
    select 1 from pg_constraint
     where conrelid = 'public.projects'::regclass
       and conname = 'projects_tenant_present_check'),
    'projects_tenant_present_check is gone — a claimed project can now be '
    'written with no practice';

  -- The trigger that fills the column, so no call site has to.
  assert exists (
    select 1 from pg_trigger
     where tgrelid = 'public.projects'::regclass
       and tgname = 'projects_bind_organization' and not tgisinternal),
    'projects_bind_organization is gone — `insert into projects (user_id, name)` '
    'now violates projects_tenant_present_check and project creation is broken';

  -- `is_org_member` gates on the SESSION, which is what makes it safe to put
  -- in a policy reachable by `anon`.
  assert exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'is_org_member'
       and p.prosecdef
       and pg_get_functiondef(p.oid) like '%auth.uid()%'),
    'is_org_member must be SECURITY DEFINER and must read auth.uid()';

  -- Every profile owns exactly one ACTIVE organization. handle_new_user
  -- creates it; without it the claim raises and a brief is lost at signup.
  select count(*) into v_n
    from public.profiles p
   where not exists (select 1 from public.organization_members m
                      where m.user_id = p.id and m.role = 'owner'
                        and m.status = 'active');
  assert v_n = 0, format('%s profiles own no active organization', v_n);

  /*
   * ⚠ THE THREE STATES, AND WHAT EACH ONE REQUIRES. An 'active' row with no
   * user, or an 'invited' row with no token, is a row that reads as valid and
   * means nothing.
   */
  assert exists (select 1 from pg_constraint
     where conrelid = 'public.organization_members'::regclass
       and conname = 'organization_members_invited_shape_check'),
    'an invited membership can be written with no token or no email';
  assert exists (select 1 from pg_constraint
     where conrelid = 'public.organization_members'::regclass
       and conname = 'organization_members_active_shape_check'),
    'an active membership can be written with no user';

  -- ⚠ ACCESS FOLLOWS status = 'active'. Without this clause in is_org_member a
  -- REMOVED clinician keeps access to the practice, silently.
  assert (select pg_get_functiondef(p.oid)
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'is_org_member')
         like '%status%',
    'is_org_member no longer checks status — invited and removed rows grant access';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. The layer, exercised — not read
-- ---------------------------------------------------------------------------
-- `insert into auth.users` fires `handle_new_user`, which must now produce a
-- profile AND an organization AND an owner membership. Fifty-two other test
-- files depend on that chain without knowing it.
insert into auth.users (id, email) values
  ('cccccccc-0000-0000-0000-000000000001', 'owner@example.com'),
  ('cccccccc-0000-0000-0000-000000000002', 'stranger@example.com');

do $$
declare v_org uuid; v_other uuid;
begin
  select m.organization_id into v_org from public.organization_members m
   where m.user_id = 'cccccccc-0000-0000-0000-000000000001' and m.role = 'owner';
  assert v_org is not null, 'signing up produced no organization';

  select m.organization_id into v_other from public.organization_members m
   where m.user_id = 'cccccccc-0000-0000-0000-000000000002' and m.role = 'owner';
  assert v_other is not null and v_other <> v_org,
    'two signups landed in the same organization';
end
$$;

-- The shape both call sites in the frontend use, unchanged: no organization_id.
insert into public.projects (id, user_id, name) values
  ('dddddddd-0000-0000-0000-000000000001',
   'cccccccc-0000-0000-0000-000000000001', 'Elm & Ember Counseling');

do $$
declare v_org uuid; v_expected uuid;
begin
  select organization_id into v_org from public.projects
   where id = 'dddddddd-0000-0000-0000-000000000001';
  select organization_id into v_expected from public.organization_members
   where user_id = 'cccccccc-0000-0000-0000-000000000001' and role = 'owner';
  assert v_org = v_expected,
    'the browser''s insert shape did not come out tenanted';
end
$$;

-- ⚠ AND A CALLER NAMING SOMEBODY ELSE'S PRACTICE IS OVERRIDDEN, NOT HONOURED.
--
-- ⚠ THIS BLOCK HAS TO SAY WHO IT IS, AND IT DID NOT. It asserted what "an
-- authenticated caller" may do while running as psql with no request context
-- at all, and passed by accident: the trigger's honour-branch then required
-- `auth.role() = 'service_role'`, which was equally false, so the override
-- happened for the wrong reason. 20260911195907 added
-- `caller_is_the_database()` to that branch — deliberately, because it is the
-- seam the invitation needs to place a clinician's project in the practice
-- rather than in their personal organization — and the accident stopped
-- holding. CI said so within the hour.
--
-- Both callers are now asserted, because they are genuinely different rules:
-- the browser may not name a practice, and the database may.
do $$
declare v_org uuid; v_stranger uuid;
begin
  select organization_id into v_stranger from public.organization_members
   where user_id = 'cccccccc-0000-0000-0000-000000000002'
     and role = 'owner' and status = 'active';

  -- (a) AN AUTHENTICATED BROWSER. Whatever it sends is overwritten with the
  -- owner's own practice.
  set local request.jwt.claims =
    '{"role":"authenticated","sub":"cccccccc-0000-0000-0000-000000000001"}';
  set local request.headers = '{}';

  insert into public.projects (user_id, name, organization_id)
  values ('cccccccc-0000-0000-0000-000000000001', 'probe', v_stranger)
  returning organization_id into v_org;

  assert v_org <> v_stranger,
    'an authenticated caller placed their project inside a stranger''s practice';

  -- (b) THE DATABASE ITSELF — a migration, a backfill, the invitation's
  -- provisioning path. It MAY name a practice, and that is the seam, not a
  -- hole: anyone holding a direct connection already outranks this trigger.
  reset request.jwt.claims;
  reset request.headers;

  insert into public.projects (user_id, name, organization_id)
  values ('cccccccc-0000-0000-0000-000000000001', 'provisioned', v_stranger)
  returning organization_id into v_org;

  assert v_org = v_stranger,
    'the database could not place a project in a named practice — the seam the '
    'invitation needs is closed';
end
$$;

-- An anonymous brief has no practice, and the constraint accepts it.
do $$
declare v_org uuid;
begin
  insert into public.projects (name, anon_token_hash, anon_expires_at)
  values ('anonymous', repeat('e', 64), now() + interval '30 days')
  returning organization_id into v_org;
  assert v_org is null, 'an anonymous brief was given a practice';
end
$$;

-- The claim: user_id and organization_id, together, in the one statement
-- `lib/anon/claim.ts` already writes.
do $$
declare v_org uuid;
begin
  update public.projects
     set user_id = 'cccccccc-0000-0000-0000-000000000002',
         anon_token_hash = null,
         anon_expires_at = null
   where anon_token_hash = repeat('e', 64)
  returning organization_id into v_org;
  assert v_org is not null,
    'the claim attached a user and left the project with no practice';
end
$$;

-- ⚠ AND THE CONSTRAINT HOLDS EVEN WITH THE TRIGGER GONE. Two mechanisms, and
-- the test proves they are two rather than one wearing a second name.
alter table public.projects disable trigger projects_bind_organization;
do $$
begin
  begin
    update public.projects set organization_id = null
     where user_id is not null and anon_token_hash is null;
    assert false, 'a claimed project was written with no practice — '
                  'projects_tenant_present_check did not bite';
  exception when check_violation then
    null; -- what should happen
  end;
end
$$;
alter table public.projects enable trigger projects_bind_organization;

-- ---------------------------------------------------------------------------
-- 5. Isolation, through the policies, as the browser sees it
-- ---------------------------------------------------------------------------
do $$
declare v_visible integer; v_own uuid;
begin
  select organization_id into v_own from public.organization_members
   where user_id = 'cccccccc-0000-0000-0000-000000000001' and role = 'owner';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"cccccccc-0000-0000-0000-000000000001"}';

  select count(*) into v_visible from public.organizations;
  assert v_visible = 1, format('an owner sees %s organizations, not just their own', v_visible);

  select count(*) into v_visible from public.organizations where id = v_own;
  assert v_visible = 1, 'an owner cannot see their own organization';

  select count(*) into v_visible from public.organization_members;
  assert v_visible = 1, format('an owner sees %s memberships, not just their own', v_visible);

  reset role;
end
$$;

-- CANARY — the isolation above is not vacuously true because the table is
-- empty. There is more than one organization to be wrong about.
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.organizations;
  assert v_n >= 2, format('only %s organizations exist — section 5 proves nothing', v_n);
end
$$;

-- CANARY — the enumeration bites. A table with no path to anyone and no name
-- in either list must be caught.
do $$
declare v_caught boolean := false;
begin
  create table public.canary_untenanted(id uuid primary key);

  if exists (
    with recursive fk as (
      select con.conrelid::regclass::text as child,
             replace(con.confrelid::regclass::text, 'public.', '') as parent
        from pg_constraint con join pg_class c on c.oid = con.conrelid
        join pg_namespace n on n.oid = c.relnamespace
       where con.contype = 'f' and n.nspname = 'public' and con.confrelid <> con.conrelid
    ),
    reach as (
      select child as t from fk where parent in ('projects', 'profiles', 'auth.users')
      union select f.child from fk f join reach r on f.parent = r.t
    )
    select 1 where 'canary_untenanted' not in (select t from reach)
      and 'canary_untenanted' not in (select t from never_tenanted)
      and 'canary_untenanted' not in (select t from per_person_by_decision)
  ) then
    v_caught := true;
  end if;

  drop table public.canary_untenanted;
  assert v_caught, 'the enumeration did not catch an untenanted, unnamed table';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. The invitation, walked
-- ---------------------------------------------------------------------------
-- The token is the whole security boundary here: it does not pass through
-- `auth.uid()`, so it is an argument to a SECURITY DEFINER function and never a
-- permissive policy. What this section pins is that the boundary holds in both
-- directions — a holder of the token gets her page before she has an account,
-- and everyone else gets nothing.
do $$
declare
  v_owner uuid := 'cccccccc-0000-0000-0000-000000000001';
  v_clin  uuid := 'cccccccc-0000-0000-0000-000000000002';
  v_org   uuid;
  v_token text;
  v_res   jsonb;
begin
  select organization_id into v_org from public.organization_members
   where user_id = v_owner and role = 'owner' and status = 'active';

  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_owner)::text, true);
  perform set_config('request.headers', '{}', true);
  v_token := public.invite_clinician(v_org, 'Invited.Person@Example.com');

  -- ⚠ THE PLAINTEXT IS NOT IN THE TABLE. Only its hash is, which is the whole
  -- of the anonymous-brief pattern reused rather than reinvented.
  assert length(v_token) = 43, format('the token is %s characters, not 43', length(v_token));
  assert not exists (select 1 from public.organization_members where invite_token_hash = v_token),
    '⚠ THE PLAINTEXT TOKEN IS STORED';
  assert exists (select 1 from public.organization_members
                  where invite_token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex')
                    and status = 'invited' and user_id is null),
    'the invitation did not land as an invited row with no user';

  -- The address is normalised, or two invitations to the same person do not
  -- recognise each other.
  assert exists (select 1 from public.organization_members
                  where status = 'invited' and invited_email = 'invited.person@example.com'),
    'the invited address was not lower-cased';

  -- She sees her page before she has an account; nobody else sees anything.
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  assert public.organization_invitation_preview(v_token) is not null,
    'the invited clinician cannot see her page before signing up';
  assert public.organization_invitation_preview(repeat('z', 43)) is null,
    'a wrong token was previewed';
  assert public.organization_invitation_preview(null) is null,
    'a null token was previewed';

  -- An invitation is not membership.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_clin)::text, true);
  assert public.is_org_member(v_org) is false,
    '⚠ AN INVITED PERSON ALREADY HAS ACCESS TO THE PRACTICE';

  v_res := public.accept_organization_invitation(v_token);
  assert (v_res ->> 'accepted')::boolean, format('accepting failed: %s', v_res);
  assert public.is_org_member(v_org) is true, 'accepting did not grant access';

  -- ⚠ SINGLE USE, by verify-then-consume in one statement.
  v_res := public.accept_organization_invitation(v_token);
  assert (v_res ->> 'accepted')::boolean is false,
    format('the token was spent twice: %s', v_res);
  assert not exists (select 1 from public.organization_members where invite_token_hash = ''),
    'a spent token was written as the empty string rather than null';

  -- Removal takes access away. This is the assertion that would have caught
  -- Session 3's is_org_member if it had shipped unchanged into this table.
  perform set_config('request.jwt.claims', '', true);
  update public.organization_members set status = 'removed'
   where user_id = v_clin and organization_id = v_org;
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_clin)::text, true);
  assert public.is_org_member(v_org) is false,
    '⚠ A REMOVED CLINICIAN STILL HAS ACCESS TO THE PRACTICE';

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);
end
$$;

-- CANARY — an invitation that has expired is not previewable and not
-- acceptable, which is a different code path from a wrong token.
do $$
declare
  v_org   uuid;
  v_token text := 'expired_token_' || repeat('e', 30);
begin
  select organization_id into v_org from public.organization_members
   where user_id = 'cccccccc-0000-0000-0000-000000000001' and role = 'owner';

  insert into public.organization_members
    (organization_id, user_id, role, status, invited_email, invite_token_hash, invite_expires_at)
  values (v_org, null, 'clinician', 'invited', 'late@example.com',
          encode(extensions.digest(v_token, 'sha256'), 'hex'), now() - interval '1 day');

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  assert public.organization_invitation_preview(v_token) is null,
    'an expired invitation is still previewable';

  perform set_config('request.jwt.claims',
    '{"role":"authenticated","sub":"cccccccc-0000-0000-0000-000000000002"}', true);
  assert (public.accept_organization_invitation(v_token) ->> 'accepted')::boolean is false,
    'an expired invitation was accepted';
  perform set_config('request.jwt.claims', '', true);
end
$$;

rollback;
