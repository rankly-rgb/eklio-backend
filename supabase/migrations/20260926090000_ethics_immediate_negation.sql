-- ════════════════════════════════════════════════════════════════════════
--  F38 — UN TERME INTERDIT IMMÉDIATEMENT NIÉ EST CONFORME
-- ════════════════════════════════════════════════════════════════════════
--
-- Le 2026-09-24, un mois généré est sorti à 29 posts sur 30. Les trente
-- contrôles du mois étaient verts, dix échanges de contenu avaient abouti, et
-- c'est la gâchette `content_items_ethics_gate` qui a refusé le trentième :
--
--     Advertising ethics: guarantee
--
-- Le mois est tombé sur `month.short`. Le texte fautif disait, en substance,
-- « there is no guarantee that six weeks will change anything » — c'est-à-dire
-- l'ANTI-PROMESSE, exactement ce que l'ACA C.3.a cherche à obtenir d'une
-- publicité de praticien licencié.
--
-- Le côté TypeScript ne s'y trompait pas : `lib/ethics/rules.ts` exempte depuis
-- l'origine un terme interdit immédiatement précédé d'une négation
-- (`isProhibitiveMention`). Ce côté-ci ne connaissait pas cette notion. Le
-- recensement des motifs était pourtant vert des deux côtés — un recensement
-- compare des NOMS, et une exemption n'est pas un motif.
--
-- Décision de Naima, 2026-09-26 : c'est le motif du code qui est juste.
--
-- ⚠ ET SUR CE SEUL POINT. L'exemption ne vaut que pour la négation IMMÉDIATE.
-- Une négation à distance dans la même phrase, dans une autre phrase, ou après
-- le terme, ne l'ouvre pas — « I can cure your anxiety, no question » reste
-- bloqué, et doit le rester.
--
-- ── ⚠ POURQUOI PAS UN `exception_pattern` ──────────────────────────────────
--
-- La table en porte déjà un, et il aurait été tentant d'y écrire la négation.
-- Il est testé sur LE TEXTE ENTIER (`not p_text ~* exception_pattern`) : une
-- seule tournure prohibitive quelque part dans une légende de trois cents mots
-- aurait exempté la légende entière, promesse comprise. C'est précisément la
-- négation à distance que la décision exclut. Il reste pour ce qu'il sait
-- faire — `therapy_that_works` contre « an approach that works best for you ».
--
-- ── ⚠ POURQUOI PAS UN LOOKBEHIND ──────────────────────────────────────────
--
-- Les expressions régulières de Postgres portent le lookahead `(?=...)` et
-- PAS le lookbehind : `(?<=...)` lève `invalid regular expression`. La
-- contrainte « ce qui précède immédiatement » ne peut donc pas s'écrire comme
-- en JavaScript.
--
-- Elle s'obtient autrement, et plus simplement : on RETIRE d'une copie du
-- texte les occurrences précédées de la négation — la concaténation
-- `négation || motif` impose l'adjacence — puis on applique le motif inchangé
-- à ce qu'il reste. Deux propriétés tombent gratuitement :
--
--   * l'extrait cité dans le message d'erreur est automatiquement la première
--     occurrence NON niée, là où un booléen aurait nommé la première tout
--     court ;
--   * « no guarantee, but we guarantee results » reste bloqué sur la seconde,
--     sans qu'on ait à compter quoi que ce soit.
--
-- Le remplacement met une ESPACE et non rien : deux fragments ne peuvent pas
-- se souder en un mot qui n'existait pas.

/*
 * La négation, écrite UNE fois et lisible par un test.
 *
 * ⚠ JUMELLE DE `PROHIBITIVE_LEAD` DANS eklio-frontend/lib/ethics/rules.ts,
 * traduite en POSIX : `\b` devient `\y`, et l'apostrophe est doublée. Les deux
 * listes de marqueurs sont écrites en toutes lettres des deux côtés, comme
 * celle de `ethics_parity` : le fichier à contrôler est dans l'autre dépôt, et
 * une liste qui se lit elle-même ne contrôle rien.
 *
 * Après le marqueur, seuls des blancs, des guillemets ou des parenthèses
 * peuvent s'intercaler. NI VIRGULE NI MOT : « no matter what, we guarantee
 * results » reste bloqué, et c'est voulu.
 */
create or replace function public.ethics_prohibitive_lead()
returns text
language sql
immutable
as $$
  select '\y(no|not|never|without|avoid|avoids|avoiding|exclude|excludes|excluding|omit|omits|omitting)\y[[:space:]"''‘’“”(\[]*'
$$;

comment on function public.ethics_prohibitive_lead() is
  'F38 — la négation qui, IMMÉDIATEMENT accolée à un terme interdit, en fait '
  'une mention conforme. Jumelle de PROHIBITIVE_LEAD côté TypeScript.';

create or replace function public.ethics_scan(p_text text)
returns jsonb
language sql
stable
as $$
  with stripped as (
    select ep.rule_id,
           ep.severity,
           ep.sort_order,
           ep.pattern,
           /*
            * ⚠ UNE COPIE PAR MOTIF. Chaque motif est dépouillé de SES propres
            * occurrences niées : retirer la négation d'un coup pour tous les
            * motifs supprimerait le mot « no » que le motif d'à côté devait
            * lire.
            */
           regexp_replace(
             p_text,
             public.ethics_prohibitive_lead() || '(' || ep.pattern || ')',
             ' ',
             'gi'
           ) as kept
      from public.ethics_patterns ep
     where ep.active
       and p_text is not null
       and not coalesce(p_text ~* ep.exception_pattern, false)
  )
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'rule_id',  rule_id,
      'severity', severity,
      'excerpt',  coalesce(substring(kept from '(?i)(' || pattern || ')'), '(match)')
    ) order by sort_order),
    '[]'::jsonb)
    from stripped
   where kept ~* pattern
$$;

comment on function public.ethics_scan(text) is
  'Toutes les violations déontologiques d''un texte. F38 : une occurrence '
  'immédiatement précédée d''une négation n''en est pas une — voir '
  'ethics_prohibitive_lead(). Une négation à distance ne l''ouvre pas.';
