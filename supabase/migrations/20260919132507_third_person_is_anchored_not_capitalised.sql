/*
 * ══════════════════════════════════════════════════════════════════════════
 * CE N'EST PAS LA CASSE QUI DISTINGUE LA TROISIÈME PERSONNE, C'EST LA POSITION
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La version d'hier cherchait une majuscule : `\y[A-Z][a-z]+ (is|has|holds)`.
 * Elle ne pouvait pas marcher, et la mesure l'a montré : les deux moteurs
 * compilent ce motif SANS ÉGARD À LA CASSE (`~*` en PostgreSQL, le drapeau `i`
 * en JavaScript), donc `[A-Z]` ne contraignait rien du tout. La règle mordait
 * sur « my colleague is a licensed therapist » au milieu d'un texte écrit à la
 * première personne.
 *
 * Un profil écrit à la troisième personne s'ouvre sur le nom. « My colleague
 * is a licensed therapist » est une incise. On ANCRE donc, au lieu de chercher
 * une majuscule que le lecteur ne peut de toute façon pas voir :
 *
 *     ^[^.!?]{0,40}\y(is|has|holds) (a |an )?(licensed|certified|…)
 *
 * ── LES DEUX RAISONS, SONDÉES DANS LES DEUX MOTEURS AVANT CHARGEMENT ─────
 *
 * Douze cas passés au `~*` de PostgreSQL et à la regex JavaScript du lecteur :
 * AUCUN écart entre les deux. Ce que la mesure confirme :
 *
 *   « Sarah Chen, LCSW, is a licensed clinical social worker… »   MORD
 *   « Sarah is a licensed marriage and family therapist… »        MORD
 *   « She is a licensed marriage and family therapist. »          MORD
 *   « …your day. My colleague is a licensed therapist. »          se tait
 *   « I am a licensed therapist in Denver. »                      se tait
 *   « …supervised by Dana Ruiz, LPC-S. »                          se tait
 *   « …under the supervision of Dana Ruiz. »                      se tait
 *   « My supervisor is a licensed psychologist. »                 se tait
 *
 * Le dernier est la raison de l'élargissement du motif secondaire : c'est la
 * mention texane écrite autrement, et `supervised by|under the supervision of`
 * seuls ne l'attrapaient pas.
 *
 * ── ET LES TROIS CHOSES QUE LA MESURE A APPRISES, ÉCRITES ICI PLUTÔT QUE
 *    DÉCOUVERTES PLUS TARD ────────────────────────────────────────────────
 *
 * 1. L'ANCRE SÉPARE DES POSITIONS, PAS DES PERSONNES. « My colleague is a
 *    licensed therapist. » en OUVERTURE mord. Un vrai profil n'ouvre pas
 *    ainsi, donc le coût est faible — mais la règle n'est pas « une incise se
 *    tait », elle est « une incise qui n'ouvre pas se tait ».
 *
 * 2. `[^.!?]` SE FERME SUR « Ph.D. ». « Sarah Chen, Ph.D., is a licensed
 *    psychologist. » se tait : les points du titre coupent la fenêtre avant le
 *    verbe. C'est un faux négatif sur une ouverture qui est pourtant le cas
 *    visé. Limite connue, écrite dans la description ; l'élargir est une
 *    décision de produit, pas une correction à faire en passant.
 *
 * 3. `supervision` SEUL FAIT TAIRE LA RÈGLE SUR LE PROFIL D'UNE SUPERVISEUSE.
 *    « …is a licensed clinical social worker. I provide clinical supervision
 *    to associates. » ne produit plus de constat. C'est le prix de l'élargis-
 *    sement, et il est payé volontiers : taire un constat MINEUR chez une
 *    superviseuse coûte infiniment moins que reprocher à une associée texane
 *    d'avoir obéi à 22 TAC 681.91(m).
 *
 * ⚠ ET LA PHRASE D'HIER SUR LES PRÉNOMS ACCENTUÉS DEVIENT FAUSSE. La forme
 * ancrée n'a plus besoin de `[A-Z][a-z]+` : « José is a licensed therapist. »
 * mord, dans les deux moteurs. Laisser cette phrase serait pire que de ne rien
 * avoir écrit — une limite documentée qui n'existe pas empêche de chercher
 * celles qui existent. Elle est REMPLACÉE par les deux vraies, ci-dessus.
 */

-- >>> THIRD PERSON IS ANCHORED, NOT CAPITALISED (mirrored verbatim in supabase/seed.sql) >>>

update public.positioning_patterns
   set kind              = 'present_without',
       pattern           = '^[^.!?]{0,40}\y(is|has|holds) (a |an )?(licensed|certified|board-certified|master)',
       secondary_pattern = '\y(supervised by|under the supervision of|supervisor|supervision)\y',
       severity          = 'minor'
 where id = 'written_in_third_person';

update public.positioning_rules
   set description = 'Third person reads like an entry someone else filed. The first contact a client has with you is this text — first person is the difference between a directory listing and a person speaking. The pattern is ANCHORED: it looks at the opening only, because a profile written in the third person opens on the name, while "my colleague is a licensed therapist" mid-text is an aside. TWO KNOWN LIMITS, both measured, neither an oversight: (1) a title containing dots closes the window early, so "Sarah Chen, Ph.D., is a licensed psychologist" is missed; (2) it stays silent on any text containing "supervised by", "under the supervision of", "supervisor" or "supervision" — which also silences a supervisor''s own profile. That second cost is paid on purpose: a Texas associate is REQUIRED to write the supervision line (22 TAC 681.91(m)), and reproaching someone for obeying the law is the one thing this product must never do.'
 where id = 'written_in_third_person';

-- <<< THIRD PERSON IS ANCHORED, NOT CAPITALISED <<<

/*
 * ── LA GARDE, ET ELLE SE SABOTE ELLE-MÊME ───────────────────────────────
 *
 * Elle rejoue les cas de la mesure contre la ligne RÉELLEMENT écrite, pas
 * contre les chaînes ci-dessus. Si un seul s'écarte, la migration ne passe
 * pas. La garde d'hier — celle qui exigeait `[A-Z][a-z]+` — devait tomber, et
 * elle tombe ici : c'est cette garde-ci qui la remplace. Sabotée avant
 * application : rejouée avec le motif d'hier, elle refuse les trois cas qui
 * ont motivé le changement.
 */
do $$
declare
  v_pattern   text;
  v_secondary text;
  v_cas       record;
  v_mord      boolean;
begin
  select pattern, secondary_pattern into v_pattern, v_secondary
    from public.positioning_patterns where id = 'written_in_third_person';

  if v_pattern is null or v_secondary is null then
    raise exception 'written_in_third_person a perdu un de ses deux motifs';
  end if;

  if v_pattern !~ '^\^' then
    raise exception 'le motif n''est plus ancré : %', v_pattern;
  end if;

  for v_cas in
    select * from (values
      ('ouverture sur le nom',      'Sarah Chen, LCSW, is a licensed clinical social worker in Sacramento.', true),
      ('l''exemple de la règle',    'Sarah is a licensed marriage and family therapist who has been practicing since 2014.', true),
      ('le pronom en ouverture',    'She is a licensed marriage and family therapist.', true),
      ('prénom accentué',           'José is a licensed therapist.', true),
      ('incise au milieu',          'The mornings are the hardest part of your day. My colleague is a licensed therapist.', false),
      ('première personne',         'I am a licensed therapist in Denver.', false),
      ('supervised by',             'Chen is a licensed professional counselor, supervised by Dana Ruiz, LPC-S.', false),
      ('under the supervision of',  'Chen is a licensed professional counselor under the supervision of Dana Ruiz.', false),
      ('« My supervisor is… »',     'My supervisor is a licensed psychologist.', false)
    ) as t(quoi, texte, attendu)
  loop
    v_mord := (v_cas.texte ~* v_pattern) and not (v_cas.texte ~* v_secondary);
    if v_mord is distinct from v_cas.attendu then
      raise exception 'written_in_third_person, cas « % » : attendu %, obtenu %',
        v_cas.quoi, v_cas.attendu, v_mord;
    end if;
  end loop;

  -- ⚠ La description ne doit plus porter la limite devenue fausse.
  if exists (
    select 1 from public.positioning_rules
     where id = 'written_in_third_person' and description ilike '%José%'
  ) then
    raise exception 'la description porte encore la limite « prénoms accentués », que la mesure a rendue fausse';
  end if;

  -- ⚠ Et elle doit porter les deux qui sont vraies.
  if not exists (
    select 1 from public.positioning_rules
     where id = 'written_in_third_person'
       and description ilike '%Ph.D.%' and description ilike '%22 TAC 681.91(m)%'
  ) then
    raise exception 'la description a perdu une de ses deux limites mesurées';
  end if;
end $$;
