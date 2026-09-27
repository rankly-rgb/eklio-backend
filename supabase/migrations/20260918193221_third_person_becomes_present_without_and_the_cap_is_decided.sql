-- ============================================================================
-- Deux décisions : le plafond est 3, et la troisième personne change de forme
-- ============================================================================
--
-- ── 1. LE PLAFOND EST 3, ET CE N'EST PLUS UNE VALEUR PROVISOIRE ─────────
--
-- `20260918190034` posait 3 faute de décision — le repère « [MON CHOIX] »
-- était resté vide. La décision est prise, et sa raison est celle-ci :
--
--   UN RAPPORT GRATUIT À TROIS CONSTATS OUVRE UNE CONVERSATION ; À DIX, IL
--   HUMILIE.
--
-- Ce n'est pas un compromis technique ni une contrainte d'écran. C'est une
-- affirmation sur ce qu'une clinicienne fait d'un diagnostic qu'elle n'a pas
-- demandé : trois choses, elle les lit ; dix, elle ferme l'onglet et n'écrit à
-- personne. Le produit ne vend rien à quelqu'un qu'il vient d'accabler.
--
-- ⚠ LA RAISON NE PEUT PAS TENIR DANS LA LIGNE ELLE-MÊME, et il faut le dire :
-- `app_settings` est une table clé/valeur sans colonne de commentaire, donc un
-- `comment on column` porterait sur les dix-neuf réglages à la fois. La raison
-- vit donc à trois endroits qui, eux, se lisent : cet en-tête, le commentaire
-- de `lib/positioning/cap.ts` juste au-dessus de la constante de repli, et
-- `DECISIONS.md`. Aucun n'est la ligne ; tous les trois sont à un clic d'elle.
--
-- La valeur ne change pas — 3 hier par défaut, 3 aujourd'hui par décision. Ce
-- qui change est qu'elle est désormais tenue par quelqu'un.
--
-- ── 2. `written_in_third_person` DEVIENT `present_without` ──────────────
--
-- L'écart relevé au lot précédent — le motif exigeait un pronom, l'exemple
-- disait « Sarah » — ne se corrige PAS en élargissant le motif aux prénoms
-- seuls. Cela créerait un faux positif grave :
--
--   ⚠ UNE ASSOCIÉE TEXANE DOIT ÉCRIRE « supervised by (nom) » — 22 TAC
--   681.91(m). Un motif qui attrape « Chen is a licensed… » reprocherait à
--   quelqu'un de RESPECTER LA LOI, dans un produit dont toute la raison d'être
--   est de ne jamais faire ça.
--
-- La règle change donc de forme : `present_without`. Le motif attrape la
-- construction, et la mention de supervision la fait taire.
--
--   pattern            \y[A-Z][a-z]+ (is|has|holds) (a |an )?(licensed|…)
--   secondary_pattern  \y(supervised by|under the supervision of)\y
--
-- ⚠ CE QUI A ÉTÉ VÉRIFIÉ AVANT DE CHARGER, sur dix cas, dans LES DEUX moteurs
-- (PostgreSQL `~*` et la regex JavaScript du lecteur) :
--
--   · les deux COÏNCIDENT, cas par cas, sur les dix. `[A-Z][a-z]+` traverse la
--     traduction `\y` → `\b` sans changer de sens ;
--   · `[[:upper:]]` est REFUSÉ par JavaScript (erreur de syntaxe) et `\p{Lu}`
--     est refusé par PostgreSQL. Le choix de `[A-Z][a-z]+` était le bon, et
--     c'est vérifié plutôt que supposé ;
--   · ⚠ MAIS LA MAJUSCULE N'EST PAS CONTRAINTE. Le lecteur compile avec le
--     drapeau `i`, et `~*` est insensible à la casse : « sarah is a
--     licensed… » et « My colleague is a licensed… » déclenchent aussi. Les
--     deux moteurs sont d'accord là-dessus — c'est une propriété de la règle,
--     pas une divergence. À relire par son autrice.
-- ============================================================================

-- >>> THIRD PERSON BECOMES PRESENT WITHOUT (mirrored verbatim in supabase/seed.sql) >>>

update public.positioning_patterns
   set kind              = 'present_without',
       pattern           = '\y[A-Z][a-z]+ (is|has|holds) (a |an )?(licensed|certified|board-certified|master)',
       secondary_pattern = '\y(supervised by|under the supervision of)\y'
 where id = 'written_in_third_person';

update public.positioning_rules
   set description = 'Third person reads like an entry someone else filed. The first contact a client has with you is this text — first person is the difference between a directory listing and a person speaking. KNOWN LIMIT, not an oversight: the pattern matches an unaccented first name, so José, Chloé and Zoë are missed. It also stays silent when the text says "supervised by" or "under the supervision of" — a Texas associate is REQUIRED to write it (22 TAC 681.91(m)), and reproaching someone for obeying the law is the one thing this product must never do.'
 where id = 'written_in_third_person';

-- <<< THIRD PERSON BECOMES PRESENT WITHOUT <<<


do $$
declare v_n int;
begin
  -- ── Le plafond ─────────────────────────────────────────────────────────
  select (value #>> '{}')::int into v_n
    from public.app_settings where key = 'first_line_findings_shown';
  if v_n <> 3 then
    raise exception 'plafond: % au lieu de 3. Migration abandonnée.', v_n;
  end if;

  -- ── La règle a bien changé de forme, et porte ses deux motifs ─────────
  select count(*) into v_n from public.positioning_patterns
   where id = 'written_in_third_person'
     and kind = 'present_without'
     and secondary_pattern is not null;
  if v_n <> 1 then
    raise exception
      'troisième personne: la règle n''est pas passée en present_without avec son second motif. Migration abandonnée.';
  end if;

  -- La sévérité ne bouge pas : c'était la consigne.
  select count(*) into v_n from public.positioning_patterns
   where id = 'written_in_third_person' and severity = 'minor';
  if v_n <> 1 then
    raise exception 'troisième personne: la sévérité a changé. Migration abandonnée.';
  end if;

  -- ── ⚠ L'ÉCART EST FERMÉ : l'exemple déclenche enfin son propre motif ──
  select count(*) into v_n
    from public.positioning_rules r
    join public.positioning_patterns p on p.rule_id = r.id
   where r.id = 'written_in_third_person'
     and r.example_weak ~* p.pattern
     and r.example_weak !~* p.secondary_pattern;
  if v_n <> 1 then
    raise exception
      'troisième personne: « Sarah is a licensed… » ne déclenche toujours pas la règle. Migration abandonnée.';
  end if;

  -- ⚠ ET LE PRONOM MARCHE AUSSI. Sans cette ligne, un motif qui n'attraperait
  -- que les prénoms aurait remplacé un trou par un autre.
  if not ('She is a licensed marriage and family therapist.'
          ~* (select pattern from public.positioning_patterns where id = 'written_in_third_person')) then
    raise exception 'troisième personne: le motif ne voit plus le pronom. Migration abandonnée.';
  end if;

  -- ⚠⚠ LE FAUX POSITIF QUE CETTE FORME EXISTE POUR ÉVITER. C'est la sonde qui
  -- compte le plus de ce fichier : une associée texane qui obéit à
  -- 22 TAC 681.91(m) ne doit recevoir aucun reproche.
  if not ('Chen is a licensed professional counselor, supervised by Dana Ruiz, LPC-S.'
          ~* (select secondary_pattern from public.positioning_patterns where id = 'written_in_third_person')) then
    raise exception
      'troisième personne: la mention de supervision ne fait pas taire la règle — une associée texane serait accusée de respecter la loi. Migration abandonnée.';
  end if;
  if not ('Chen is a licensed professional counselor under the supervision of Dana Ruiz.'
          ~* (select secondary_pattern from public.positioning_patterns where id = 'written_in_third_person')) then
    raise exception
      'troisième personne: la seconde formulation de la supervision n''est pas reconnue. Migration abandonnée.';
  end if;

  -- La limite connue est écrite dans la règle, pas seulement ici.
  select count(*) into v_n from public.positioning_rules
   where id = 'written_in_third_person' and description like '%KNOWN LIMIT%';
  if v_n <> 1 then
    raise exception
      'troisième personne: la limite des prénoms accentués n''est pas dans la description. Migration abandonnée.';
  end if;

  -- Rien d'autre n'a bougé : dix règles, dix motifs, cinq costly.
  select count(*) into v_n from public.positioning_rules;
  if v_n <> 10 then
    raise exception 'troisième personne: % règles au lieu de 10. Migration abandonnée.', v_n;
  end if;
  select count(*) into v_n from public.positioning_patterns where severity = 'costly';
  if v_n <> 5 then
    raise exception 'troisième personne: % costly au lieu de 5. Migration abandonnée.', v_n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Aucune. Revenir au motif à pronoms rouvrirait l'écart, et revenir à un
--   motif sans `secondary_pattern` accuserait une associée texane de respecter
--   la loi.
