-- ============================================================================
-- F38 — la négation IMMÉDIATE exempte, celle à distance non — la moitié SQL
-- ============================================================================
-- Le 2026-09-24, un mois généré est sorti à 29 posts sur 30 : la gâchette a
-- refusé « there is no guarantee that six weeks will change anything », qui est
-- de la copy CONFORME — l'anti-promesse que l'ACA C.3.a cherche à obtenir.
--
-- Le côté TypeScript exemptait déjà cette tournure ; celui-ci ne connaissait pas
-- la notion. Le recensement des motifs était pourtant vert des deux côtés —
-- un recensement compare des NOMS, et une exemption n'est pas un motif. C'est
-- la limite exacte de `20260914200000_ethics_parity.test.sql`, et la raison de
-- ce fichier-ci : il tient les deux côtés sur le COMPORTEMENT, là où l'autre
-- tient le recensement.
--
-- Son jumeau, qui écrit les MÊMES phrases en toutes lettres :
--   eklio-frontend/lib/ethics/__tests__/immediate-negation.test.ts
--
-- ⚠ CE QUI EST VÉRIFIÉ N'EST PAS « l'exemption marche » mais « elle ne
-- s'étend pas ». Une exemption trop large ouvrirait la promesse elle-même : il
-- suffirait d'un « no » quelque part dans une légende de trois cents mots. Les
-- quatre positions de négation sont donc éprouvées séparément, et trois d'entre
-- elles doivent continuer à BLOQUER.

begin;

do $$
declare
  v_case   record;
  v_actual text;
  v_fail   int := 0;
begin
  for v_case in
    select * from (values
      -- ── position 1 : nue. Bloque, et c'est le socle même. ──────────────
      ('nue',            'I guarantee relief.',                                        'block'),
      ('nue',            'This is a clinically proven method.',                         'block'),
      ('nue',            'Limited spots available this month.',                         'block'),
      ('nue',            'My clients say they feel lighter afterwards.',                'block'),

      -- ── position 2 : négation IMMÉDIATE. Passe depuis F38. ─────────────
      -- Rien entre le marqueur et le terme : ni virgule, ni mot.
      ('immédiate',      'There is no guarantee that six weeks will change anything.',  'pass'),
      ('immédiate',      'Therapy comes without guarantees. What it offers is a place to look.', 'pass'),
      ('immédiate',      'No guaranteed outcome exists in this work.',                  'pass'),
      ('immédiate',      'I hold no success rate, because a number would flatten it.',  'pass'),
      ('immédiate',      'There are no limited spots and no reason to hurry.',          'pass'),
      ('immédiate',      'No weekend certification stands behind this.',                'pass'),

      -- ── position 3 : à distance dans la MÊME phrase. Bloque. ───────────
      -- ⚠ C'EST LA LIMITE QUI FAIT TOUT. Un mot s'intercale, et la phrase
      -- n'est plus une négation du terme : « no one can cure your anxiety »
      -- reste une phrase où « cure your anxiety » est affirmé de quelqu'un.
      ('à distance',     'No one can cure your anxiety.',                               'block'),
      ('à distance',     'Not a single clinically proven method exists here.',          'block'),
      ('à distance',     'No matter what, we guarantee results.',                       'block'),

      -- ── position 4 : dans la phrase d'AVANT. Bloque. ───────────────────
      ('phrase d''avant','I make no promises. I guarantee relief.',                     'block'),
      ('phrase d''avant','Nothing here is a promise. This is a clinically proven method.', 'block'),

      -- ── position 5 : APRÈS le terme. Bloque. ──────────────────────────
      ('après',          'I guarantee relief, or not.',                                 'block'),
      ('après',          'Limited spots available, no pressure.',                        'block')
    ) as t(position, texte, attendu)
  loop
    v_actual := case when public.ethics_blocks(v_case.texte) is null then 'pass' else 'block' end;
    if v_actual <> v_case.attendu then
      v_fail := v_fail + 1;
      raise warning 'F38 [%] attendu %, obtenu % : « % »',
        v_case.position, v_case.attendu, v_actual, v_case.texte;
    end if;
  end loop;

  if v_fail > 0 then
    raise exception
      '% sonde(s) de négation hors verdict. Si ce sont les « immédiate » qui '
      'bloquent, la migration 20260926090000 a été perdue. Si ce sont les '
      'autres qui passent, l''exemption s''est ÉLARGIE — et une négation à '
      'distance qui exempte ouvre la promesse elle-même.', v_fail;
  end if;

  -- ⚠ ET LA NÉGATION EST ÉCRITE UNE FOIS, DANS UNE FONCTION. Recopiée dans
  -- `ethics_scan`, elle aurait divergé de son jumeau TypeScript à la première
  -- correction.
  if public.ethics_prohibitive_lead() is null
     or public.ethics_prohibitive_lead() !~ 'without'
     or public.ethics_prohibitive_lead() !~ 'never' then
    raise exception
      'ethics_prohibitive_lead() ne porte plus la liste des marqueurs de '
      'négation ; son jumeau est PROHIBITIVE_LEAD dans lib/ethics/rules.ts.';
  end if;

  -- ⚠ L'EXTRAIT CITÉ EST LA PREMIÈRE OCCURRENCE NON NIÉE, pas la première
  -- tout court. C'est ce que le dépouillement donne gratuitement, et c'est ce
  -- que lit la praticienne dans le message d'erreur.
  if public.ethics_blocks('No guarantee here, but we guarantee results.') is null then
    raise exception
      'une promesse posée APRÈS une négation immédiate n''est plus vue : le '
      'dépouillement retire trop.';
  end if;

  raise notice 'F38 : 17 sondes, cinq positions de négation, verdicts tenus';
end $$;

rollback;
