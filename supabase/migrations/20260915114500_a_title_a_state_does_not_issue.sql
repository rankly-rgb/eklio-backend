-- ============================================================================
-- Un titre d'exercice que l'État ne délivre pas
-- ============================================================================
-- ⚠ TROUVÉ SUR LE CHEMIN DE PRODUCTION RÉEL, PAS EN RELECTURE. La prose du
-- profil annonçait « I'm a Licensed Mental Health Counselor (LMHC) in
-- Portland, Oregon ». L'Oregon ne délivre pas de LMHC : le titre y est LPC.
-- Un titre d'exercice faux sur une page publique n'est pas une faute de style,
-- c'est un problème réglementaire pour la praticienne, devant son board.
--
-- ── D'OÙ VENAIT « LMHC » ────────────────────────────────────────────────
--
-- Pas du modèle. De la SAISIE :
--
--   project_briefs(e9c42fc1-…) : license_type_id = 'lmhc', city = 'Portland',
--                                state = 'OR'
--
-- `license_types` est un catalogue NATIONAL et SANS ÉTAT : dix titres, aucun
-- lien avec une juridiction. L'écran 1 les proposait donc tous les dix, quel
-- que soit l'État tapé deux champs plus bas, et la base a accepté le couple.
-- Le modèle n'a fait que développer fidèlement l'acronyme qu'on lui tendait.
--
-- ⚠ LE DÉFAUT EST DONC UNE ABSENCE, pas une erreur : rien, nulle part, ne
-- savait qu'un titre appartient à une juridiction. C'est la forme que le
-- README de ce dépôt décrit en tête — « qu'est-ce que le défaut autorise que
-- je n'ai pas nommé ? ». Il autorisait 10 × 51 couples là où une fraction
-- existe.
--
-- ── CE QUE CETTE MIGRATION POSE ─────────────────────────────────────────
--
-- 1. `license_type_states` — QUELLE juridiction délivre QUEL titre. Un
--    catalogue, en base (§6), comme `license_types` lui-même.
-- 2. Un trigger sur `project_briefs` qui REFUSE le couple impossible à
--    l'écriture. Refusé à la saisie, jamais rattrapé après : une prose déjà
--    écrite et déjà payée n'est pas le bon endroit pour découvrir ça.
--
-- ⚠ UNE CONTRAINTE CHECK NE PEUT PAS FAIRE ÇA. Un CHECK ne lit pas une autre
-- table. C'est donc un trigger, avec le coût qu'on connaît : il ne s'applique
-- qu'aux écritures, et ne dit rien des lignes déjà là. La section 4 traite les
-- lignes existantes explicitement plutôt que de les laisser survivre en
-- silence.
--
-- ⚠ ET LA DONNÉE DE LA SECTION 3 N'EST PAS VÉRIFIÉE BOARD PAR BOARD. Elle est
-- la meilleure connaissance disponible au moment de l'écrire, et elle est
-- marquée comme telle (`verified_at`). Le MÉCANISME est prouvé par les
-- garde-fous de la section 5 ; la MATRICE demande une relecture contre les
-- sites des boards avant la mise en vente. Un couple absent de la table est
-- REFUSÉ — l'échec est fermé, donc visible et réparable par une ligne, jamais
-- une page publique fausse.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. La table
-- ---------------------------------------------------------------------------
create table if not exists public.license_type_states (
  license_type_id text not null references public.license_types (id) on delete restrict,
  /* Code USPS à deux lettres, MAJUSCULES ici — `project_briefs.state` garde
     ce que la praticienne a tapé, la comparaison se fait en upper(). */
  state_code      char(2) not null,
  /*
   * ⚠ NULL = « personne n'a encore vérifié cette ligne contre le board ».
   * Ce n'est pas un détail d'audit : c'est ce qui distingue une matrice
   * relue d'une matrice plausible, et la seconde est exactement ce que ce
   * dépôt appelle un défaut permissif.
   */
  verified_at     timestamptz,
  verified_by     text,
  primary key (license_type_id, state_code)
);

alter table public.license_type_states drop constraint if exists license_type_states_code_check;
alter table public.license_type_states
  add constraint license_type_states_code_check check (state_code ~ '^[A-Z]{2}$');

comment on table public.license_type_states is
  'Which jurisdiction issues which practice title. A pair that is absent is REFUSED at brief write time by project_briefs_license_state_gate -- Oregon issues LPC, not LMHC, and the brief that said otherwise reached a public profile. verified_at NULL means the row has not been checked against that state board yet.';
comment on column public.license_type_states.verified_at is
  'When someone checked this pair against the state board itself. NULL means nobody has. The pair still applies -- this column says how much to trust it, it does not gate it.';

create index if not exists license_type_states_state_idx
  on public.license_type_states (state_code);


-- ---------------------------------------------------------------------------
-- 2. RLS — même règle que les autres catalogues
-- ---------------------------------------------------------------------------
-- Lisible par une session OU par un brief anonyme vivant : l'écran 1 doit
-- filtrer les puces AVANT qu'elle ne choisisse, et l'écran 1 est le premier
-- que touche une visiteuse sans compte (cf. 20260915053102).
alter table public.license_type_states enable row level security;

drop policy if exists license_type_states_select_all on public.license_type_states;
create policy license_type_states_select_all on public.license_type_states
  for select to anon, authenticated
  using ((select current_user) = 'authenticated'
         or (select public.holds_anon_brief()));


-- ---------------------------------------------------------------------------
-- 3. La matrice
-- ---------------------------------------------------------------------------
/*
 * ⚠ LIRE L'AVERTISSEMENT DE L'EN-TÊTE AVANT DE S'APPUYER LÀ-DESSUS.
 * `verified_at` est NULL partout : aucune de ces lignes n'a été relue contre
 * le site d'un board. Elles sont posées pour que le mécanisme existe et que le
 * défaut signalé soit refusé dès maintenant, pas pour tenir lieu de source.
 *
 * Trois familles, et elles ne se comportent pas pareil :
 *
 *   PSYCHOLOGUES (PsyD, PhD) — ce sont des DIPLÔMES, pas des licences. Ils
 *   s'écrivent partout ; c'est « Licensed Psychologist » qui est la licence.
 *   Donc les 51 juridictions, sans exception.
 *
 *   TRAVAIL SOCIAL ET COUPLE/FAMILLE (LCSW, LMFT) — quasi universels. LMSW
 *   (niveau master, pré-clinique) et LICSW (variante « independent ») ne le
 *   sont PAS : ils dépendent de la nomenclature de chaque État.
 *
 *   CONSEIL (LPC, LPCC, LMHC, LCPC) — C'EST ICI QUE TOUT SE JOUE, et c'est
 *   exactement la famille du défaut. Le même métier porte quatre noms selon
 *   la juridiction, et aucun État n'en délivre plus d'un ou deux.
 */
insert into public.license_type_states (license_type_id, state_code)
select lt, st
  from (values
    /* ── Diplômes de psychologie : partout ─────────────────────────────── */
    ('psyd'), ('phd'),
    /* ── Quasi universels ──────────────────────────────────────────────── */
    ('lcsw'), ('lmft')
  ) as t(lt)
  cross join (values
    ('AL'),('AK'),('AZ'),('AR'),('CA'),('CO'),('CT'),('DE'),('DC'),('FL'),
    ('GA'),('HI'),('ID'),('IL'),('IN'),('IA'),('KS'),('KY'),('LA'),('ME'),
    ('MD'),('MA'),('MI'),('MN'),('MS'),('MO'),('MT'),('NE'),('NV'),('NH'),
    ('NJ'),('NM'),('NY'),('NC'),('ND'),('OH'),('OK'),('OR'),('PA'),('RI'),
    ('SC'),('SD'),('TN'),('TX'),('UT'),('VT'),('VA'),('WA'),('WV'),('WI'),('WY')
  ) as s(st)
on conflict do nothing;

/*
 * ⚠ LA FAMILLE CONSEIL, ÉTAT PAR ÉTAT. Une juridiction absente d'une ligne
 * ci-dessous REFUSE ce titre — c'est le comportement voulu, et c'est lui qui
 * fait échouer 'lmhc' + 'OR'.
 */
insert into public.license_type_states (license_type_id, state_code) values
  /* LPC — le nom le plus répandu, dont l'Oregon. */
  ('lpc','AL'),('lpc','AK'),('lpc','AZ'),('lpc','AR'),('lpc','CO'),('lpc','CT'),
  ('lpc','DE'),('lpc','DC'),('lpc','GA'),('lpc','HI'),('lpc','IN'),('lpc','KY'),
  ('lpc','LA'),('lpc','MI'),('lpc','MS'),('lpc','MO'),('lpc','MT'),('lpc','NE'),
  ('lpc','NV'),('lpc','NH'),('lpc','NJ'),('lpc','NM'),('lpc','NC'),('lpc','ND'),
  ('lpc','OH'),('lpc','OK'),('lpc','OR'),('lpc','PA'),('lpc','SC'),('lpc','SD'),
  ('lpc','TN'),('lpc','TX'),('lpc','UT'),('lpc','VT'),('lpc','VA'),('lpc','WV'),
  ('lpc','WI'),('lpc','WY'),('lpc','IL'),('lpc','MN'),

  /* LMHC — et l'Oregon n'y est PAS. C'est la ligne du défaut. */
  ('lmhc','FL'),('lmhc','NY'),('lmhc','MA'),('lmhc','WA'),('lmhc','IA'),
  ('lmhc','RI'),('lmhc','ME'),

  /* LPCC — palier clinique là où il existe sous ce nom. */
  ('lpcc','CA'),('lpcc','OH'),('lpcc','KY'),('lpcc','MN'),('lpcc','NM'),

  /* LCPC — même métier, encore un autre nom. */
  ('lcpc','IL'),('lcpc','MD'),('lcpc','ME'),('lcpc','KS'),('lcpc','MT'),
  ('lcpc','ID'),

  /* LICSW — la variante « independent » du travail social. */
  ('licsw','MA'),('licsw','WA'),('licsw','DC'),('licsw','MN'),('licsw','RI'),
  ('licsw','NH'),('licsw','VT'),('licsw','AL'),

  /* LMSW — niveau master, pré-clinique. */
  ('lmsw','NY'),('lmsw','MI'),('lmsw','TX'),('lmsw','KS'),('lmsw','GA'),
  ('lmsw','LA'),('lmsw','OK'),('lmsw','AR'),('lmsw','NE'),('lmsw','ND'),
  ('lmsw','SD'),('lmsw','IA'),('lmsw','KY'),('lmsw','MS'),('lmsw','AL'),
  ('lmsw','TN'),('lmsw','VA'),('lmsw','WV'),('lmsw','NM'),('lmsw','MT')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 4. Le refus, à l'écriture
-- ---------------------------------------------------------------------------
/*
 * ⚠ LE PRÉDICAT EST ÉCRIT POUR NE JAMAIS RENDRE NULL, et c'est la première
 * règle du README de ce dépôt. Un brief sans titre, ou sans État, n'est pas
 * en faute : il est simplement incomplet, et l'étape 1 a sa propre phrase
 * pour ça. Seul un couple RENSEIGNÉ DES DEUX CÔTÉS et absent du catalogue est
 * refusé.
 */
/*
 * ⚠ `security INVOKER`, ET C'EST UNE DÉCISION. Les autres prédicats de ce
 * schéma sont DEFINER parce qu'ils lisent des lignes que l'appelant n'a pas le
 * droit de voir (`projects`, `comp_grants`). Celui-ci lit un CATALOGUE, dont
 * la policy de la section 2 ouvre déjà la lecture à exactement les deux
 * appelants qui écrivent un brief — une session, ou un jeton anonyme vivant.
 * Il n'a donc rien à emprunter, et le rendre DEFINER lui ferait franchir une
 * porte déjà ouverte tout en le faisant tomber sous la règle de
 * `20260911170458_function_surface.test.sql` : « une fonction DEFINER que le
 * navigateur peut appeler doit demander qui appelle ». Celle-ci n'a pas à le
 * demander, parce qu'elle n'accorde rien.
 *
 * Conséquence assumée : si la RLS cachait un jour le catalogue à quelqu'un qui
 * écrit, `exists` rendrait faux et le couple serait REFUSÉ. Échec fermé,
 * visible à la saisie, réparable — l'inverse serait une page publique fausse.
 */
create or replace function public.license_state_allowed(
  p_license_type_id text,
  p_state text
)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $function$
  select case
    when p_license_type_id is null then true
    when nullif(btrim(coalesce(p_state, '')), '') is null then true
    else exists (
      select 1 from public.license_type_states s
       where s.license_type_id = p_license_type_id
         and s.state_code = upper(btrim(p_state))
    )
  end
$function$;

revoke execute on function public.license_state_allowed(text, text) from public;
grant execute on function public.license_state_allowed(text, text)
  to anon, authenticated, service_role;

comment on function public.license_state_allowed(text, text) is
  'True when this state issues this title, or when either half is still blank (an incomplete brief is not a false one). Never returns null: the brief gate and the form both read it, and a null predicate would read as a refusal nobody could explain.';

create or replace function public.project_briefs_license_state_gate()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if not public.license_state_allowed(new.license_type_id, new.state) then
    raise exception
      'license_state_mismatch: % is not a title issued in %. A practice title the state does not issue is a board problem for the clinician, so it is refused here rather than corrected downstream.',
      new.license_type_id, upper(btrim(new.state))
      using errcode = '23514';
  end if;
  return new;
end
$function$;

/*
 * ⚠ LA QUATRIÈME LIGNE DU TABLEAU DU README, RÉVOQUÉE À LA MAIN. Une fonction
 * naît avec EXECUTE accordé à PUBLIC, celle-ci comprise — et une fonction de
 * trigger publiée, même inappelable utilement, figure dans le document
 * OpenAPI anonyme de PostgREST, qui est la façon dont on apprend un schéma.
 * `20260911170458_function_surface.test.sql` refuse exactement ça, et l'a
 * refusé ici avant que cette ligne n'existe.
 */
revoke execute on function public.project_briefs_license_state_gate()
  from public, anon, authenticated;

drop trigger if exists project_briefs_license_state_gate on public.project_briefs;
create trigger project_briefs_license_state_gate
  before insert or update of license_type_id, state on public.project_briefs
  for each row execute function public.project_briefs_license_state_gate();

/*
 * ⚠ LES LIGNES DÉJÀ ÉCRITES. Un trigger ne regarde que les écritures ; les
 * briefs existants portant un couple impossible resteraient tels quels, et le
 * silence est précisément ce qu'on répare. On ne les CORRIGE pas — deviner
 * quel titre elle détient vraiment serait inventer un credential, ce que la
 * règle 4 du socle déontologique interdit au modèle et qu'on ne va pas faire
 * à sa place. On les NOMME, pour qu'ils soient repris à la main.
 */
do $$
declare
  v_row record;
  v_n int := 0;
begin
  for v_row in
    select b.project_id, b.license_type_id, b.state
      from public.project_briefs b
     where not public.license_state_allowed(b.license_type_id, b.state)
  loop
    v_n := v_n + 1;
    raise warning
      'license_state_mismatch (ligne existante, NON corrigée) : project_briefs.% porte % en %.',
      v_row.project_id, v_row.license_type_id, upper(btrim(v_row.state));
  end loop;

  if v_n > 0 then
    raise warning
      'license_state_mismatch : % brief(s) existants portent un couple que cet État ne délivre pas. À reprendre à la main -- deviner le bon titre serait inventer un credential.', v_n;
  end if;
end
$$;


-- ---------------------------------------------------------------------------
-- 5. Garde-fous — le défaut signalé, et son contraire
-- ---------------------------------------------------------------------------
-- La matrice de la section 3 n'est pas vérifiée. Le MÉCANISME, lui, l'est ici :
-- ces quatre assertions échouent la migration si le couple du rapport passe,
-- ou si le couple légitime est refusé.

do $$
declare v_refused boolean;
begin
  -- ⚠ LE DÉFAUT. L'Oregon ne délivre pas de LMHC.
  if public.license_state_allowed('lmhc', 'OR') then
    raise exception 'license_state: lmhc + OR est encore accepté. Migration abandonnée.';
  end if;

  -- ⚠ ET SON CONTRAIRE, sinon on aurait pu tout refuser et passer au vert.
  if not public.license_state_allowed('lpc', 'OR') then
    raise exception 'license_state: lpc + OR est refusé. La matrice refuse tout. Migration abandonnée.';
  end if;
  if not public.license_state_allowed('lmhc', 'NY') then
    raise exception 'license_state: lmhc + NY est refusé. Migration abandonnée.';
  end if;

  -- La casse de l'État ne décide de rien : `project_briefs.state` garde ce
  -- qu'elle a tapé, et « or » est le même État que « OR ».
  if public.license_state_allowed('lmhc', 'or') then
    raise exception 'license_state: lmhc + "or" passe en minuscules. Migration abandonnée.';
  end if;

  -- Un brief incomplet n'est pas un brief faux.
  if not public.license_state_allowed(null, 'OR') then
    raise exception 'license_state: un brief sans titre est refusé. Migration abandonnée.';
  end if;
  if not public.license_state_allowed('lmhc', null) then
    raise exception 'license_state: un brief sans État est refusé. Migration abandonnée.';
  end if;
  if not public.license_state_allowed('lmhc', '   ') then
    raise exception 'license_state: un État vide est traité comme un État. Migration abandonnée.';
  end if;

  /*
   * Anti-vacuité. Le plancher est 250 et il se déduit : les quatre titres
   * universels (psyd, phd, lcsw, lmft) font à eux seuls 4 × 51 = 204 lignes.
   * Passer 250 prouve donc que les familles conseil et travail social ont
   * elles aussi été semées — une table réduite aux universels passerait un
   * plancher plus bas sans que rien ne le dise.
   */
  if (select count(*) from public.license_type_states) < 250 then
    raise exception 'license_state: la matrice est trop courte pour être la bonne. Migration abandonnée.';
  end if;
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.project_briefs'::regclass
       and tgname = 'project_briefs_license_state_gate'
       and not tgisinternal
  ) then
    raise exception 'license_state: le trigger n''est pas posé. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger if exists project_briefs_license_state_gate on public.project_briefs;
--   drop function if exists public.project_briefs_license_state_gate();
--   drop function if exists public.license_state_allowed(text, text);
--   drop table if exists public.license_type_states;
