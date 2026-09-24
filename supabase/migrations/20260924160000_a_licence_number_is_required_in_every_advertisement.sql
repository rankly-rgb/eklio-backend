-- ============================================================================
-- Eklio — un numéro de licence dans chaque publicité
-- ============================================================================
--
-- ⚠ QUATRE CENTS POSTS PRODUITS, ZÉRO NUMÉRO DE LICENCE.
--
-- Trouvé par l'audit du corpus (F35). Californie B&P §4980.44 (LMFT), §4996.2
-- (LCSW) et §4999.80 (LPCC) exigent le TYPE et le NUMÉRO de licence dans
-- **toute** publicité ; le Texas, la Virginie et d'autres imposent
-- l'équivalent. Chacun des quatre cents posts déjà produits est une infraction
-- publicitaire en l'état.
--
-- ⚠ ET CE N'ÉTAIT PAS UN DÉFAUT DE CONTRÔLE. `project_briefs` porte déjà
-- `license_type_id` et `state`, mais aucune colonne pour le NUMÉRO : aucun
-- contrôle ne peut exiger ce qu'il n'y a rien à mettre. C'est la raison pour
-- laquelle le trou a tenu quatre cents posts.
--
-- ── ⚠ LA RÈGLE LA PLUS STRICTE, PAS CINQUANTE RÈGLES ────────────────────
--
-- Les cinquante-et-un territoires servis n'imposent pas la même chose : tous
-- exigent le titre, une partie exige le numéro. Gérer cinquante variantes
-- demanderait de vérifier cinquante boards ET de maintenir la table ensuite ;
-- appliquer la plus stricte partout demande une colonne. Le produit porte donc
-- **abréviation + numéro** dans chaque publicité, dans tous les États.
--
-- Ce choix se paie d'un champ de plus au brief, et il s'achète une conformité
-- qui ne dépend pas de l'exactitude d'une matrice de cinquante lignes.
-- ============================================================================

alter table public.project_briefs
  add column if not exists license_number text,
  add column if not exists license_state_code char(2);

/*
 * ⚠ L'ÉTAT DE DÉLIVRANCE N'EST PAS L'ÉTAT DU CABINET. Une praticienne peut
 * exercer en télésanté depuis un État et porter une licence d'un autre ; c'est
 * le numéro et l'État qui l'a délivré qui identifient la licence auprès du
 * board. Par défaut c'est le même, et la colonne le reste jusqu'à ce que
 * quelqu'un dise le contraire.
 */
comment on column public.project_briefs.license_state_code is
  'The state that ISSUED the licence, which is not always the state the practice sits in: a clinician may work by telehealth from one state under another state''s licence, and it is the issuing board that the number belongs to. Null means "the same as state".';

comment on column public.project_briefs.license_number is
  'The licence number as the board prints it. California B&P 4980.44, 4996.2 and 4999.80 require the licence type AND number in every advertisement, and other states match; the product applies that rule everywhere rather than maintaining fifty variants. Four hundred posts were produced without it because there was no column to put it in -- no check can demand what there is nowhere to write.';

/*
 * ⚠ PAS DE `not null`, ET C'EST VOULU. Les briefs existants n'ont pas ce
 * numéro, et une colonne obligatoire les rendrait tous invalides d'un coup —
 * y compris ceux du harnais, qui servent à mesurer. Le refus se fait au moment
 * de GÉNÉRER, avec un message qui nomme le champ à remplir, pas au moment de
 * lire une ligne écrite avant que la colonne existe.
 *
 * ⚠ MAIS LE FORMAT EST CONTRAINT DÈS QU'IL Y A QUELQUE CHOSE. Un numéro vide,
 * un espace, ou une phrase entière ne sont pas des numéros, et ils
 * s'imprimeraient tels quels sur une carte publiable.
 */
alter table public.project_briefs drop constraint if exists project_briefs_license_number_shape;
alter table public.project_briefs
  add constraint project_briefs_license_number_shape
  check (
    license_number is null
    or (
      btrim(license_number) = license_number
      and char_length(license_number) between 3 and 20
      and license_number ~ '^[A-Za-z0-9][A-Za-z0-9 .#-]*[A-Za-z0-9]$'
      and license_number ~ '[0-9]'
    )
  );

comment on constraint project_briefs_license_number_shape on public.project_briefs is
  'A licence number has digits, no leading or trailing space, and is short. Boards print them in many shapes (LMFT 12345, PSY29384, 0701-004321) so the pattern is permissive about separators and strict about the rest -- but a number that is blank, or a sentence, is not a number, and it would print as written on a publishable card.';

alter table public.project_briefs drop constraint if exists project_briefs_license_state_shape;
alter table public.project_briefs
  add constraint project_briefs_license_state_shape
  check (license_state_code is null or license_state_code ~ '^[A-Z]{2}$');

/*
 * ── ⚠ LA RLS N'A PAS À CHANGER, ET IL FAUT LE DIRE PLUTÔT QUE LE SUPPOSER ──
 *
 * Les policies de `project_briefs` sont au niveau de la LIGNE : elles
 * autorisent une praticienne à lire et écrire SES briefs, quelle que soit la
 * colonne. Deux colonnes de plus sont donc couvertes par les policies
 * existantes sans une ligne de SQL.
 *
 * ⚠ CE NE SERAIT PAS VRAI AVEC DES DROITS PAR COLONNE (`grant ... (col)`), qui
 * doivent être étendus à la main à chaque ajout. La vérification ci-dessous le
 * prouve plutôt que de le croire — et elle LÈVE au lieu d'avertir : une
 * colonne sans droit serait illisible pour la praticienne, ce qui est pire
 * qu'une migration qui refuse de s'appliquer.
 */
do $$
declare
  v_policies integer;
  v_colgrants integer;
begin
  select count(*) into v_policies from pg_policies where tablename = 'project_briefs';
  if v_policies = 0 then
    raise exception 'project_briefs n''a aucune policy : les deux colonnes seraient sans protection';
  end if;

  /*
   * ⚠ `information_schema.column_privileges` NE DISTINGUE PAS LES DEUX CAS :
   * elle énumère un droit de TABLE colonne par colonne, et rend donc dix-huit
   * lignes pour deux colonnes neuves alors qu'aucun droit par colonne
   * n'existe. Un premier jet a lu ces dix-huit lignes comme un avertissement,
   * ce qui était faux dans le sens qui inquiète pour rien.
   *
   * La grandeur juste est `pg_attribute.attacl` : elle n'est renseignée QUE
   * pour un droit réellement posé sur une colonne. Zéro veut dire que tous les
   * droits sont au niveau de la table, donc que les colonnes neuves les
   * héritent sans une ligne de SQL.
   */
  select count(*) into v_colgrants
    from pg_attribute a
   where a.attrelid = 'public.project_briefs'::regclass
     and a.attacl is not null;

  if v_colgrants > 0 then
    raise exception
      'project_briefs porte % droit(s) PAR COLONNE : les deux colonnes neuves doivent être ajoutées à la main',
      v_colgrants;
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='project_briefs'
       and column_name in ('license_number','license_state_code')
     group by table_name having count(*) = 2
  ) then
    raise exception 'les deux colonnes ne sont pas là';
  end if;
end $$;
