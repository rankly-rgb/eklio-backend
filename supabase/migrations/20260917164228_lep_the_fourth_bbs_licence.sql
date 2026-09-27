-- ============================================================================
-- LEP — la quatrième licence du BBS, qui manquait au catalogue
-- ============================================================================
-- `DECISIONS_NEEDED` #20 : le Board of Behavioral Sciences délivre QUATRE
-- licences — LMFT, LEP, LCSW, LPCC — et le catalogue n'en portait que trois.
-- Une praticienne LEP californienne n'avait aucun titre correct à choisir à
-- l'écran 1, et la garde ne rattrapait pas le cas : le trigger refuse un titre
-- que l'État ne délivre pas, mais LEP n'étant nulle part, il n'y avait rien à
-- refuser. L'absence ne déclenche aucune garde.
--
-- ⚠ FERMÉ MAINTENANT PARCE QUE LA CALIFORNIE EST LE SEUL ÉTAT OUVERT, donc le
-- seul endroit où le trou est réel : ailleurs, `state_is_sellable` refuse déjà
-- tout. Le trou devient une page publique le jour où l'État s'ouvre, pas avant.
--
-- ⚠ UNE SEULE JURIDICTION POSÉE, ET C'EST VOULU. D'autres États délivrent un
-- équivalent de la psychologie scolaire sous d'autres noms. Les ajouter de
-- mémoire referait exactement l'erreur que ce lot répare — c'est la leçon de
-- `20260915125159` sur la Pennsylvanie et LSW. La matrice vérifiée dira
-- lesquels.
--
-- ── PROVENANCE, IDENTIQUE AUX QUATRE AUTRES ─────────────────────────────
--
-- Même relevé, mêmes réserves, et elles ne s'atténuent pas d'être répétées :
--
--   1. RELEVÉ MACHINE, PAGES NON RELUES PAR UN HUMAIN. C'est ce que dit
--      `verified_by`, littéralement.
--
--   2. LE RELEVÉ N'A PAS ÉTÉ FAIT DEPUIS CET ENVIRONNEMENT, et je n'ai pas pu
--      atteindre `bbs.ca.gov/applicants/lep.html` non plus : le proxy de
--      sortie y refuse tout HTTPS (403 sur CONNECT). Relayé, transcrit, pas
--      vérifié ici. `source_url` est ce qui permet de REFAIRE le travail, pas
--      ce qui prouve qu'il a été fait.
--
-- ── POURQUOI LE BLOC EST MIROITÉ, ET CE QU'IL RATTRAPE ──────────────────
--
-- ⚠ `20260917160202` A OUBLIÉ SON MIROIR. Elle a vérifié les quatre couples
-- californiens sans bloc marqué, donc `supabase/seed.sql` ne les porte pas :
-- une base locale reconstruite par `db reset` a une Californie FERMÉE là où la
-- production l'a ouverte. Le rejeu des migrations, lui, la voit — c'est
-- pourquoi rien ne l'a signalé.
--
-- On n'édite pas un fichier appliqué. Le bloc ci-dessous réécrit donc la
-- vérification des CINQ couples de façon idempotente : pour les quatre
-- premiers il pose les mêmes valeurs qu'avant, pour LEP il les pose. Le miroir
-- est complet à partir d'ici, et il est placé APRÈS le bloc LSW dans seed.sql
-- parce qu'il écrit des lignes que les blocs antérieurs écrivent aussi.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Le titre, le couple, et le relevé des cinq
-- ---------------------------------------------------------------------------
-- >>> CALIFORNIA VERIFIED PAIRS, LEP INCLUDED (mirrored verbatim in supabase/seed.sql) >>>

insert into public.license_types (id, label, description, sort_order, active) values
  ('lep', 'LEP', 'Licensed Educational Psychologist', 11, true)
on conflict (id) do update
  set label = excluded.label,
      description = excluded.description;

insert into public.license_type_states (license_type_id, state_code) values
  ('lep', 'CA')
on conflict do nothing;

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
    ('lep', 'LEP',
     'https://www.bbs.ca.gov/applicants/lep.html',
     'Board of Behavioral Sciences. Page : « Information for Licensed Educational Psychologist (LEP) Applicants ». Aucune inscription pré-licence pour ce titre.'),
    ('licensed_psychologist', null,
     'https://www.psychology.ca.gov/applicants/psychologist.shtml',
     'Board of Psychology (PAS le BBS). La page nomme la licence « Psychologist », sans préfixe « Licensed » et sans aucun sigle. Ni « LP » ni « PSY » : « PSY » est un préfixe de numéro de licence, pas une abréviation du titre. NULL est le fait relevé.')
  ) as v(lt, abbrev, url, note)
 where license_type_states.state_code      = 'CA'
   and license_type_states.license_type_id = v.lt;

-- <<< CALIFORNIA VERIFIED PAIRS, LEP INCLUDED <<<


-- ---------------------------------------------------------------------------
-- 2. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int; v_abbrev text; v_etat text;
begin
  -- ── Le titre existe, et il est proposable en Californie ────────────────
  select count(*) into v_n from public.license_types where id = 'lep' and active;
  if v_n <> 1 then
    raise exception 'lep: le titre n''est pas au catalogue ou n''est pas actif. Migration abandonnée.';
  end if;

  if not public.license_state_allowed('lep', 'CA') then
    raise exception 'lep: la Californie refuse un titre qu''elle délivre. Migration abandonnée.';
  end if;

  -- ⚠ ET IL N'EST PROPOSABLE QUE LÀ. Sans cette ligne, une insertion trop
  -- large aurait posé LEP dans cinquante juridictions de mémoire — l'erreur
  -- même que cette migration répare.
  select count(*) into v_n from public.license_type_states where license_type_id = 'lep';
  if v_n <> 1 then
    raise exception
      'lep: le titre est posé dans % juridictions, attendu 1 (CA). Migration abandonnée.', v_n;
  end if;

  -- ── La Californie est à cinq, toutes vérifiées ─────────────────────────
  select count(*) into v_n from public.license_type_states where state_code = 'CA';
  if v_n <> 5 then
    raise exception 'lep: % ligne(s) pour CA, attendu 5. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n
    from public.license_type_states where state_code = 'CA' and verified_at is null;
  if v_n <> 0 then
    raise exception
      'lep: % ligne(s) CA non vérifiées — ajouter un titre sans le relever REFERME l''État. Migration abandonnée.', v_n;
  end if;

  -- Aucune autre juridiction n'a été touchée.
  select count(*) into v_n from public.license_type_states where verified_at is not null;
  if v_n <> 5 then
    raise exception
      'lep: % ligne(s) vérifiées dans toute la matrice, attendu 5. Migration abandonnée.', v_n;
  end if;

  -- ── Les sigles ─────────────────────────────────────────────────────────
  if public.title_abbreviation('lep', 'CA') <> 'LEP' then
    raise exception 'lep: le sigle LEP ne sort pas. Migration abandonnée.';
  end if;

  select public.title_abbreviation('licensed_psychologist', 'CA') into v_abbrev;
  if v_abbrev is not null then
    raise exception
      'lep: un sigle (%) est rendu pour le psychologue californien, qui n''en a aucun. Migration abandonnée.', v_abbrev;
  end if;

  -- ── La Californie reste ouverte, les autres restent fermés ─────────────
  if not public.state_is_sellable('CA') then
    raise exception 'lep: ajouter LEP a REFERMÉ la Californie. Migration abandonnée.';
  end if;

  foreach v_etat in array array['OR', 'TX', 'NY', 'FL', 'PA'] loop
    if public.state_is_sellable(v_etat) then
      raise exception 'lep: % est devenu vendable. Migration abandonnée.', v_etat;
    end if;
  end loop;

  select count(*) into v_n from public.sellable_states where sellable;
  if v_n <> 1 then
    raise exception 'lep: % État(s) ouverts, attendu exactement 1. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET LA GARDE MORD SUR LA LIGNE NEUVE. Poser un titre non relevé doit
  -- refermer l'État : sans cette preuve, LEP pourrait être exempté par accident
  -- et le trou reviendrait sous une autre forme.
  update public.license_type_states
     set verified_at = null where state_code = 'CA' and license_type_id = 'lep';

  if public.state_is_sellable('CA') then
    raise exception
      'lep: la Californie reste ouverte avec un LEP non relevé. Migration abandonnée.';
  end if;
  if public.title_abbreviation('lep', 'CA') is not null then
    raise exception 'lep: un sigle sort d''une ligne non vérifiée. Migration abandonnée.';
  end if;

  update public.license_type_states
     set verified_at = date '2026-09-17' where state_code = 'CA' and license_type_id = 'lep';

  if not public.state_is_sellable('CA') then
    raise exception 'lep: la sonde a laissé la Californie fermée. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   delete from public.license_type_states where license_type_id = 'lep';
--   delete from public.license_types where id = 'lep';
