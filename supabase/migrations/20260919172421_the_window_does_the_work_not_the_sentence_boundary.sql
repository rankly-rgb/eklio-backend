/*
 * ══════════════════════════════════════════════════════════════════════════
 * C'EST LA FENÊTRE QUI FAIT LE TRAVAIL DE POSITION, PAS LA FRONTIÈRE DE PHRASE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Deux limites ont été chargées ce matin, et toutes les deux ratent le cas
 * principal :
 *
 *   1. `[^.!?]` se fermait sur « Ph.D. ». Or « Sarah Chen, Ph.D., is a
 *      licensed psychologist » EST la cliente type. Une règle qui rate son
 *      cas principal est PIRE qu'absente : on croira qu'elle a regardé.
 *
 *   2. `supervision` seul faisait taire la règle sur le profil d'une
 *      SUPERVISEUSE. C'est la même famille de dégât que le cas texan — ne
 *      rien dire à quelqu'un dont le texte est correct — mais prise par
 *      l'autre bout.
 *
 * Les deux disparaissent ensemble :
 *
 *   pattern            ^[^!?]{0,40}\y(is|has|holds) (a |an )?(licensed|…)
 *   secondary_pattern  \y(supervised by|under the supervision of|my supervisor|supervisor's)\y
 *
 * Le point ne ferme plus la classe. Ce qui porte la POSITION est la fenêtre
 * de quarante caractères, pas la frontière de phrase — et elle la porte
 * mieux, puisqu'elle ne dépend pas de la ponctuation d'un titre.
 *
 * ── POURQUOI `[^!?]` ET NON `.`, MESURÉ PLUTÔT QU'AFFIRMÉ ───────────────
 *
 * Le point n'a pas le même rapport au saut de ligne dans les deux moteurs.
 * Sur le collage multiligne « Sarah Chen ⏎ Ph.D. ⏎ is a licensed… » :
 *
 *     ^.{0,40}…        PostgreSQL  true      JavaScript  FALSE   ← divergence
 *     ^[^!?]{0,40}…    PostgreSQL  true      JavaScript  true    ← d'accord
 *
 * Une classe négative contient le saut de ligne dans les deux moteurs ; le
 * point ne le contient qu'en POSIX. L'écriture choisie est celle qui ne fait
 * pas dire à la base autre chose qu'à l'écran.
 *
 * ── SEIZE CAS, LES DEUX MOTEURS, AVANT CHARGEMENT, ZÉRO ÉCART ───────────
 *
 *   « Sarah Chen, Ph.D., is a licensed psychologist. »            MORD  ⭐
 *   « Sarah Chen, LCSW, is a licensed clinical social worker. »   MORD  ⭐
 *   « …social worker. I provide clinical supervision… »           MORD  ⭐
 *   « Sarah Chen ⏎ Ph.D. ⏎ is a licensed psychologist… »          MORD
 *   « She is a licensed… », « José is… », « sarah is… »           MORD
 *   « I am a licensed therapist in Denver. »                      se tait  ⭐
 *   « …your day. My colleague is a licensed therapist. »          se tait
 *   « My supervisor is a licensed psychologist. »                 se tait  ⭐
 *   « …supervised by Dana Ruiz, LPC-S. »                          se tait  ⭐
 *   « …under the supervision of Dana Ruiz. »                      se tait
 *   « Her supervisor's name is Dana Ruiz. »                       se tait
 *
 * ── CE QUI RESTE VRAI, ET CE QUI N'EXISTE PLUS ──────────────────────────
 *
 * ⚠ LES DEUX LIMITES ÉCRITES CE MATIN DISPARAISSENT DE LA DESCRIPTION. Ni le
 * titre à points ni le profil de superviseuse ne sont ratés désormais. Une
 * limite documentée qui n'existe plus empêche de chercher celles qui
 * existent — même geste qu'hier pour les prénoms accentués.
 *
 * ⚠ ET IL EN RESTE UNE, MESURÉE CE TOUR : un en-tête long repousse le verbe
 * au-delà des quarante caractères et la règle se tait. « Sarah Chen, Ph.D.,
 * LMFT ⏎ 1234 Alder Street, Suite 200 ⏎ is a licensed psychologist. » ne
 * produit aucun constat. C'est la fenêtre qui fait son travail, mais c'est un
 * silence, et il est écrit plutôt que découvert.
 *
 * ⚠ ET LE COÛT CONNU NE BOUGE PAS : l'ancre sépare des POSITIONS, pas des
 * personnes. « My colleague is a licensed therapist. » en OUVERTURE mord.
 */

-- >>> THE WINDOW DOES THE WORK (mirrored verbatim in supabase/seed.sql) >>>

update public.positioning_patterns
   set pattern           = '^[^!?]{0,40}\y(is|has|holds) (a |an )?(licensed|certified|board-certified|master)',
       secondary_pattern = '\y(supervised by|under the supervision of|my supervisor|supervisor''s)\y'
 where id = 'written_in_third_person';

update public.positioning_rules
   set description = 'Third person reads like an entry someone else filed. The first contact a client has with you is this text — first person is the difference between a directory listing and a person speaking. The pattern is ANCHORED to the first 40 characters, because a profile written in the third person opens on the name, while "my colleague is a licensed therapist" mid-text is an aside. The window, not sentence punctuation, does that work: "Sarah Chen, Ph.D., is a licensed psychologist" is caught, dots and all. It stays silent only on the supervision line itself — "supervised by", "under the supervision of", "my supervisor", "supervisor''s" — because a Texas associate is REQUIRED to write it (22 TAC 681.91(m)), and reproaching someone for obeying the law is the one thing this product must never do. A supervisor''s own profile is NOT silenced. KNOWN LIMIT, measured, not an oversight: a long header before the verb pushes it past the 40-character window, so a pasted name-address-phone block ahead of the first sentence goes unnoticed.'
 where id = 'written_in_third_person';

-- <<< THE WINDOW DOES THE WORK <<<

/*
 * ── LA GARDE, ET ELLE SE SABOTE ELLE-MÊME ───────────────────────────────
 *
 * Elle rejoue les seize cas contre la ligne RÉELLEMENT écrite. Les deux
 * gardes précédentes tombent avec les deux limites qu'elles protégeaient :
 * celle du titre à points et celle du profil de superviseuse affirmaient un
 * SILENCE qui n'est plus voulu, et elles sont remplacées ici par les deux
 * assertions inverses.
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

  -- ⚠ Le point ne doit PAS être revenu dans la classe : il rouvrirait le cas Ph.D.
  if v_pattern ~ '\[\^\.' then
    raise exception 'le point a été remis dans la classe — « Sarah Chen, Ph.D. » redevient muet';
  end if;

  for v_cas in
    select * from (values
      ('Ph.D., la cliente type',       'Sarah Chen, Ph.D., is a licensed psychologist.', true),
      ('LCSW en ouverture',            'Sarah Chen, LCSW, is a licensed clinical social worker.', true),
      ('profil de superviseuse',       'Sarah Chen, LCSW, is a licensed clinical social worker. I provide clinical supervision to associates.', true),
      ('collage multiligne',           E'Sarah Chen\nPh.D.\nis a licensed psychologist in Sacramento.', true),
      ('l''exemple de la règle',       'Sarah is a licensed marriage and family therapist who has been practicing since 2014.', true),
      ('le pronom en ouverture',       'She is a licensed marriage and family therapist.', true),
      ('prénom accentué',              'José is a licensed therapist.', true),
      ('casse basse',                  'sarah is a licensed therapist.', true),
      ('première personne',            'I am a licensed therapist in Denver.', false),
      ('incise au milieu',             'The mornings are the hardest part of your day. My colleague is a licensed therapist.', false),
      ('« My supervisor is… »',        'My supervisor is a licensed psychologist.', false),
      ('supervised by',                'Chen is a licensed professional counselor, supervised by Dana Ruiz, LPC-S.', false),
      ('under the supervision of',     'Chen is a licensed professional counselor under the supervision of Dana Ruiz.', false),
      ('« supervisor''s »',            'Chen is a licensed professional counselor. Her supervisor''s name is Dana Ruiz.', false),
      ('incise en ouverture (coût)',   'My colleague is a licensed therapist.', true),
      ('en-tête long (limite connue)', E'Sarah Chen, Ph.D., LMFT\n1234 Alder Street, Suite 200\nis a licensed psychologist.', false)
    ) as t(quoi, texte, attendu)
  loop
    v_mord := (v_cas.texte ~* v_pattern) and not (v_cas.texte ~* v_secondary);
    if v_mord is distinct from v_cas.attendu then
      raise exception 'written_in_third_person, cas « % » : attendu %, obtenu %',
        v_cas.quoi, v_cas.attendu, v_mord;
    end if;
  end loop;

  /*
   * ⚠ LES DEUX LIMITES RETIRÉES NE DOIVENT PLUS ÊTRE ÉCRITES. Même garde
   * qu'hier pour « José » : une limite documentée qui n'existe plus empêche
   * de chercher celles qui existent.
   */
  if exists (
    select 1 from public.positioning_rules
     where id = 'written_in_third_person'
       and (description ilike '%is missed%' or description ilike '%silences a supervisor%')
  ) then
    raise exception 'la description porte encore une limite que cette migration a supprimée';
  end if;

  if not exists (
    select 1 from public.positioning_rules
     where id = 'written_in_third_person'
       and description ilike '%22 TAC 681.91(m)%'
       and description ilike '%40-character window%'
  ) then
    raise exception 'la description a perdu la règle texane ou la limite de la fenêtre';
  end if;
end $$;
