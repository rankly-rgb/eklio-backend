-- ============================================================================
-- La Californie est relevée — le premier État vendable
-- ============================================================================
-- `20260915101137` a posé la règle : un État dont les couples ne sont pas
-- vérifiés n'est pas vendable, et AUCUN ne l'était. Voici le premier qui
-- l'est. Quatre couples, quatre lignes, deux boards.
--
--   lcsw                  | LCSW | bbs.ca.gov/applicants/lcsw.html
--   lmft                  | LMFT | bbs.ca.gov/applicants/lmft.html
--   lpcc                  | LPCC | bbs.ca.gov/applicants/lpcc.html
--   licensed_psychologist | NULL | psychology.ca.gov/applicants/psychologist.shtml
--
-- ⚠ LE NULL DU PSYCHOLOGUE EST UN FAIT, PAS UNE IGNORANCE. C'est le cas qui a
-- justifié la colonne (`20260915125159`) et le relevé le confirme : la page du
-- Board of Psychology nomme la licence « Psychologist », sans préfixe
-- « Licensed » et SANS AUCUN SIGLE. Pas « LP », pas « PSY » — « PSY » est un
-- préfixe de NUMÉRO de licence. Avec `verified_at` posé, `title_abbreviation()`
-- rend NULL parce qu'il n'y a rien à imprimer, et l'appelant retombe sur
-- `license_types.description`, vrai partout. C'est exactement la moitié du
-- piège que la migration du sigle avait écrite d'avance.
--
-- ── PROVENANCE, ET SA LIMITE, ÉCRITE DANS LA LIGNE ──────────────────────
--
-- `verified_by` dit « relevé machine [...] non relu par un humain », et c'est
-- délibéré : personne n'a rouvert les pages derrière la machine. Deux choses
-- que la colonne ne peut pas porter et que ce commentaire porte à sa place :
--
--   1. LE RELEVÉ N'A PAS ÉTÉ FAIT DEPUIS CET ENVIRONNEMENT. Le proxy de sortie
--      y refuse tout HTTPS (403 sur CONNECT vers bbs.ca.gov comme vers
--      psychology.ca.gov, curl et fetch également). Il a été fait ailleurs et
--      relayé. Donc `source_url` est ici ce qui permettra de REFAIRE le
--      travail, pas ce qui prouve qu'il a été fait.
--
--   2. CE QUI EST RECOUPABLE L'A ÉTÉ, et concorde. `20260915125159` avait
--      établi indépendamment, avant ce relevé, que la Californie n'a aucun
--      sigle pour le psychologue et que « PSY » est un numéro. Et la matrice
--      elle-même n'a jamais donné à la Californie autre chose que lcsw, lmft
--      et lpcc. Le relevé ne contredit rien de ce que le dépôt savait déjà.
--
-- ⚠ LES CINQ SUPPRESSIONS SONT SANS OBJET, ET C'EST UN CONSTAT À ÉCRIRE. Il
-- était demandé de retirer lpc, lmhc, lcpc, licsw et lmsw pour 'CA'. Aucune
-- de ces lignes n'existe : `20260915100122` a construit la matrice famille par
-- famille et n'a jamais listé la Californie dans aucune des cinq. La
-- Californie était DÉJÀ à quatre lignes, pas neuf. Le DELETE reste écrit —
-- idempotent, il dit l'intention — mais le garde-fou en bas exige qu'il ait
-- touché ZÉRO ligne : s'il en touchait une un jour, c'est que la matrice
-- aurait changé sous nos pieds et il faudrait le savoir.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Ce que la Californie n'a pas, et n'avait déjà pas
-- ---------------------------------------------------------------------------
/*
 * Source unique pour les cinq : https://www.bbs.ca.gov/pdf/board_licensees.pdf
 * Le BBS y énumère exactement quatre licences — LMFT, LEP, LCSW, LPCC.
 * Aucune des cinq n'y figure. (Sur LEP, absent du catalogue : voir
 * DECISIONS_NEEDED.md.)
 */
do $$
declare v_supprimees int;
begin
  delete from public.license_type_states
   where state_code = 'CA'
     and license_type_id in ('lpc', 'lmhc', 'lcpc', 'licsw', 'lmsw');
  get diagnostics v_supprimees = row_count;

  if v_supprimees <> 0 then
    raise exception
      'californie: % ligne(s) parmi les cinq ont été trouvées et supprimées, attendu 0. La matrice a changé — relire 20260915100122 avant de rejouer. Migration abandonnée.',
      v_supprimees;
  end if;
end
$$;


-- ---------------------------------------------------------------------------
-- 2. Les quatre couples relevés
-- ---------------------------------------------------------------------------
update public.license_type_states
   set verified_at  = date '2026-09-17',
       verified_by  = 'nainarahal@gmail.com (relevé machine, pages du board lues le 2026-09-17, non relu par un humain)',
       abbreviation = v.abbrev,
       source_url   = v.url,
       note         = v.note
  from (values
    ('lcsw', 'LCSW',
     'https://www.bbs.ca.gov/applicants/lcsw.html',
     'Board of Behavioral Sciences. Page : « Licensed Clinical Social Worker (LCSW) Applicants ».'),
    ('lmft', 'LMFT',
     'https://www.bbs.ca.gov/applicants/lmft.html',
     'Board of Behavioral Sciences. Page : « Licensed Marriage and Family Therapist (LMFT) Applicants ».'),
    ('lpcc', 'LPCC',
     'https://www.bbs.ca.gov/applicants/lpcc.html',
     'Board of Behavioral Sciences. Page : « Licensed Professional Clinical Counselor (LPCC) applicants ».'),
    /* ⚠ Le seul NULL, et le seul board distinct. */
    ('licensed_psychologist', null,
     'https://www.psychology.ca.gov/applicants/psychologist.shtml',
     'Board of Psychology (PAS le BBS). La page nomme la licence « Psychologist », sans préfixe « Licensed » et sans aucun sigle. Ni « LP » ni « PSY » : « PSY » est un préfixe de numéro de licence, pas une abréviation du titre. NULL est le fait relevé.')
  ) as v(lt, abbrev, url, note)
 where license_type_states.state_code      = 'CA'
   and license_type_states.license_type_id = v.lt;


-- ---------------------------------------------------------------------------
-- 3. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int; v_abbrev text; v_etat text;
begin
  -- ── Ce que la Californie doit être, ligne à ligne ──────────────────────
  select count(*) into v_n from public.license_type_states where state_code = 'CA';
  if v_n <> 4 then
    raise exception 'californie: % ligne(s) pour CA, attendu 4. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n
    from public.license_type_states
   where state_code = 'CA' and verified_at is null;
  if v_n <> 0 then
    raise exception 'californie: % ligne(s) CA restent non vérifiées. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n
    from public.license_type_states
   where state_code = 'CA'
     and license_type_id in ('lcsw', 'lmft', 'lpcc', 'licensed_psychologist');
  if v_n <> 4 then
    raise exception
      'californie: les 4 lignes CA ne sont pas les 4 titres attendus. Migration abandonnée.';
  end if;

  -- ⚠ AUCUN AUTRE ÉTAT N'A ÉTÉ TOUCHÉ. Sans cette ligne, un `where` trop large
  -- ouvrirait cinquante juridictions sans que rien ne le dise.
  select count(*) into v_n
    from public.license_type_states where verified_at is not null;
  if v_n <> 4 then
    raise exception
      'californie: % ligne(s) vérifiées dans toute la matrice, attendu 4. Migration abandonnée.', v_n;
  end if;

  -- ── Les sigles, dont le NULL qui est un fait ───────────────────────────
  if public.title_abbreviation('lcsw', 'CA') <> 'LCSW' then
    raise exception 'californie: le sigle LCSW ne sort pas. Migration abandonnée.';
  end if;
  if public.title_abbreviation('lmft', 'CA') <> 'LMFT' then
    raise exception 'californie: le sigle LMFT ne sort pas. Migration abandonnée.';
  end if;
  if public.title_abbreviation('lpcc', 'CA') <> 'LPCC' then
    raise exception 'californie: le sigle LPCC ne sort pas. Migration abandonnée.';
  end if;

  select public.title_abbreviation('licensed_psychologist', 'CA') into v_abbrev;
  if v_abbrev is not null then
    raise exception
      'californie: un sigle (%) est rendu pour le psychologue californien, qui n''en a aucun. Migration abandonnée.', v_abbrev;
  end if;

  -- ── La vente : CA ouvre, les cinq autres restent fermés ────────────────
  if not public.state_is_sellable('CA') then
    raise exception 'californie: CA reste invendable après relevé. Migration abandonnée.';
  end if;

  foreach v_etat in array array['OR', 'TX', 'NY', 'FL', 'PA'] loop
    if public.state_is_sellable(v_etat) then
      raise exception
        'californie: % est devenu vendable alors que rien ne l''a relevé. Migration abandonnée.', v_etat;
    end if;
  end loop;

  select count(*) into v_n from public.sellable_states where sellable;
  if v_n <> 1 then
    raise exception
      'californie: % État(s) ouverts, attendu exactement 1. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET LA GARDE MORD ENCORE. Une fonction qui rendrait désormais toujours
  -- vrai passerait tout ce qui précède sauf ceci : on retire UNE vérification,
  -- la Californie doit se refermer, puis on la remet.
  update public.license_type_states
     set verified_at = null
   where state_code = 'CA' and license_type_id = 'lmft';

  if public.state_is_sellable('CA') then
    raise exception
      'californie: CA reste vendable à qui il manque une ligne — la garde ne mord plus. Migration abandonnée.';
  end if;
  if public.title_abbreviation('lmft', 'CA') is not null then
    raise exception
      'californie: un sigle sort d''une ligne non vérifiée. Migration abandonnée.';
  end if;

  update public.license_type_states
     set verified_at = date '2026-09-17'
   where state_code = 'CA' and license_type_id = 'lmft';

  if not public.state_is_sellable('CA') then
    raise exception 'californie: la sonde a laissé CA fermé. Migration abandonnée.';
  end if;

  select count(*) into v_n
    from public.license_type_states where verified_at is not null;
  if v_n <> 4 then
    raise exception
      'californie: la sonde a laissé % ligne(s) vérifiées, attendu 4. Migration abandonnée.', v_n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   update public.license_type_states
--      set verified_at = null, verified_by = null,
--          abbreviation = null, source_url = null, note = null
--    where state_code = 'CA';
--   -- Les cinq lignes supprimées ne sont pas à recréer : elles n'existaient pas.
