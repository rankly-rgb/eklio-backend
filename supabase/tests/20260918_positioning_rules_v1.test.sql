-- ============================================================================
-- Les dix règles v1 — chacune sur un texte qui doit mordre et un qui ne doit pas
-- ============================================================================
-- ⚠ CE FICHIER SONDE LA DONNÉE, PAS LE CODE, et c'est délibéré : les règles
-- SONT la donnée. Un motif faux ne casse aucune compilation, ne lève aucune
-- exception et ne se voit nulle part — il rend simplement un constat que
-- personne n'a écrit, ou n'en rend aucun là où il en fallait un.
--
-- ⚠ ET LES DEUX MOITIÉS SONT OBLIGATOIRES. Un motif qui déclenche sur tout
-- passerait une suite qui ne teste que « ça mord ». Chaque règle est donc
-- sondée sur un texte qui DOIT la déclencher et un qui NE DOIT PAS.
--
-- ⚠ CE QUI EST DÉRIVÉ, ET CE QUI NE PEUT PAS L'ÊTRE. Quand la règle porte un
-- `example_weak` et un `example_strong`, ce sont EUX qui servent de sondes :
-- ils viennent de la donnée, et si quelqu'un les modifie sans rouvrir le motif,
-- ce fichier le dit. Trois règles n'ont pas la paire complète et leurs textes
-- sont écrits ici, nommément.
--
-- La sémantique des cinq formes est réécrite en SQL ci-dessous. C'est une
-- SECONDE implémentation de ce que fait `lib/positioning/review.ts`, et il faut
-- le savoir : elle ne prouve pas que l'application se comporte pareil, elle
-- prouve que les MOTIFS discriminent. L'écart entre `~*` de Postgres et la
-- regex JavaScript (`\y` contre `\b`) est sondé côté frontend, où il vit.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- La sémantique des cinq formes, telle que l'application l'applique
-- ---------------------------------------------------------------------------
create or replace function pg_temp.mord(p_rule text, p_texte text)
returns boolean
language sql
stable
as $$
  select case p.kind
    when 'present'           then p_texte ~* p.pattern
    when 'absent'            then p_texte !~* p.pattern
    when 'absent_in_opening' then left(p_texte, p.window_chars) !~* p.pattern
    when 'present_without'   then p_texte ~* p.pattern and p_texte !~* p.secondary_pattern
    when 'length'            then length(btrim(p_texte)) < coalesce(p.min_chars, 0)
                                or length(btrim(p_texte)) > coalesce(p.max_chars, 2147483647)
  end
    from public.positioning_patterns p
   where p.rule_id = p_rule and p.active
$$;

-- ---------------------------------------------------------------------------
-- 1. Les sept règles dont la paire faible/fort vient de la donnée
-- ---------------------------------------------------------------------------
/*
 * ⚠ LA LISTE EST DÉRIVÉE, PAS ÉCRITE. Toute règle qui porte les deux exemples
 * est sondée, y compris une onzième ajoutée demain. Ce qui est écrit à la main
 * ci-dessous est la liste des EXCEPTIONS, et elle doit rester courte.
 */
do $$
declare r record; v_rates text := '';
begin
  for r in
    select rl.id, rl.example_weak, rl.example_strong
      from public.positioning_rules rl
     where rl.active and rl.example_weak is not null and rl.example_strong is not null
     /*
      * ⚠ PLUS AUCUNE EXCEPTION. `written_in_third_person` en était exclue au
      * lot précédent — son exemple disait « Sarah », son motif exigeait un
      * pronom. La règle est passée en `present_without` le 18 septembre, puis
      * ancrée le 19, et son exemple déclenche enfin son propre motif : elle
      * rentre dans la boucle comme les autres, et l'exception a disparu plutôt
      * que d'être reconduite.
      */
     order by rl.sort_order
  loop
    if not pg_temp.mord(r.id, r.example_weak) then
      v_rates := v_rates || format(E'\n  %s : son example_weak NE LA DÉCLENCHE PAS', r.id);
    end if;
    if pg_temp.mord(r.id, r.example_strong) then
      v_rates := v_rates || format(E'\n  %s : son example_strong LA DÉCLENCHE', r.id);
    end if;
  end loop;

  if v_rates <> '' then
    raise exception 'v1: les exemples et les motifs se contredisent :%', v_rates;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Les trois qui n'ont pas la paire, ou dont la paire est en écart
-- ---------------------------------------------------------------------------
do $$
begin
  /*
   * ⚠ `written_in_third_person` EST ANCRÉE, ET LA SONDE LA PLUS IMPORTANTE DE
   * TOUT CE FICHIER EST CELLE DU SILENCE.
   *
   * Ce n'est pas la casse qui distingue la troisième personne — la comparaison
   * est insensible à la casse des deux côtés, donc `[A-Z][a-z]+` ne contrai-
   * gnait rien. C'est la POSITION : un profil écrit à la troisième personne
   * s'ouvre sur le nom, tandis que « my colleague is a licensed therapist »
   * au milieu d'un texte est une incise. D'où l'ancre `^[^.!?]{0,40}`.
   *
   * Et une associée texane DOIT écrire « supervised by (nom) » : 22 TAC
   * 681.91(m). Un produit qui reproche à quelqu'un de respecter la loi n'a
   * aucune raison d'exister, donc la mention de supervision fait taire la
   * règle — dans les TROIS formulations, la dernière comprise.
   */
  assert pg_temp.mord('written_in_third_person', 'She is a licensed marriage and family therapist.'),
    'troisième personne: le motif ne voit plus le PRONOM en ouverture';
  assert pg_temp.mord('written_in_third_person',
    'Sarah is a licensed marriage and family therapist who has been practicing since 2014.'),
    'troisième personne: le motif ne voit pas le PRÉNOM — l''écart de la v1 est revenu';
  assert pg_temp.mord('written_in_third_person',
    'Sarah Chen, LCSW, is a licensed clinical social worker in Sacramento.'),
    'troisième personne: une ouverture nom + credential ne mord plus';

  /*
   * ⚠ CE QUE L'ANCRE ACHÈTE, ET C'EST LA RAISON DE LA VERSION FINALE : une
   * incise au MILIEU d'un texte écrit à la première personne se tait. La
   * version d'hier mordait ici, et c'était le faux positif à éliminer.
   */
  assert not pg_temp.mord('written_in_third_person',
    'The mornings are the hardest part of your day. My colleague is a licensed therapist.'),
    'troisième personne: une incise au milieu d''un texte en « je » reçoit un reproche';
  assert not pg_temp.mord('written_in_third_person', 'I am a licensed therapist in Denver.'),
    'troisième personne: la première personne reçoit un reproche';

  assert not pg_temp.mord('written_in_third_person',
    'Chen is a licensed professional counselor, supervised by Dana Ruiz, LPC-S.'),
    'troisième personne: une associée texane qui obéit à 22 TAC 681.91(m) reçoit un reproche';
  assert not pg_temp.mord('written_in_third_person',
    'Chen is a licensed professional counselor under the supervision of Dana Ruiz.'),
    'troisième personne: la seconde formulation de la supervision ne fait pas taire la règle';
  assert not pg_temp.mord('written_in_third_person', 'My supervisor is a licensed psychologist.'),
    'troisième personne: la mention texane écrite à l''envers ne fait pas taire la règle';

  /*
   * ⚠ LES DEUX LIMITES CONNUES, SONDÉES POUR QU'ELLES RESTENT CONNUES. Elles
   * sont écrites dans la description de la règle ; ces deux sondes sont ce qui
   * le dira le jour où quelqu'un les répare — ou les aggrave — sans le vouloir.
   *
   * 1. Un titre à points ferme `[^.!?]` avant le verbe.
   * 2. `supervision` seul fait taire la règle sur le profil d'une SUPERVISEUSE,
   *    qui n'est pas une associée supervisée. C'est le prix, payé exprès, de
   *    l'élargissement qui attrape « My supervisor is… ».
   */
  assert not pg_temp.mord('written_in_third_person',
    'Sarah Chen, Ph.D., is a licensed psychologist.'),
    'troisième personne: le titre à points ne ferme plus la fenêtre — mettez à jour la description';
  assert not pg_temp.mord('written_in_third_person',
    'Sarah Chen, LCSW, is a licensed clinical social worker. I provide clinical supervision to associates.'),
    'troisième personne: le profil d''une superviseuse n''est plus tu — mettez à jour la description';

  /*
   * ⚠ ET CE QUE L'ANCRE N'ACHÈTE PAS, écrit plutôt que découvert : elle sépare
   * des POSITIONS, pas des personnes. La même incise, quand elle OUVRE le
   * texte, mord. Un vrai profil n'ouvre pas ainsi, donc le coût est faible —
   * mais la règle n'est pas « une incise se tait ».
   */
  assert pg_temp.mord('written_in_third_person', 'My colleague is a licensed therapist.'),
    'troisième personne: l''ancre s''est mise à distinguer les personnes — le comportement a changé';

  /*
   * ⚠ LA MAJUSCULE N'EST TOUJOURS PAS CONTRAINTE, et le prénom accentué EST vu
   * — la forme ancrée n'a plus besoin de `[A-Z][a-z]+`. La limite « José,
   * Chloé, Zoë sont ratés » était vraie hier et ne l'est plus ; elle a été
   * retirée de la description, et c'est ici que ça se vérifie.
   */
  assert pg_temp.mord('written_in_third_person', 'sarah is a licensed therapist.'),
    'troisième personne: la casse est devenue contraignante — le comportement a changé';
  assert pg_temp.mord('written_in_third_person', 'José is a licensed therapist.'),
    'troisième personne: un prénom accentué est de nouveau raté — la limite retirée est revenue';

  /* `no_next_step` est une ABSENCE : elle n'a pas d'example_weak, et ne peut pas en avoir. */
  assert pg_temp.mord('no_next_step',
    'Something ended that you did not choose. Months have gone by and nobody asks any more.'),
    'no_next_step ne mord pas sur un texte sans aucune invitation à écrire';
  assert not pg_temp.mord('no_next_step',
    'If you would like to talk, reach out and we will find a time.'),
    'no_next_step mord alors que le texte dit quoi faire';

  /* `too_short_to_say_anything` n'a pas d'example_strong : un texte long fait l'affaire. */
  assert pg_temp.mord('too_short_to_say_anything',
    'I am a licensed therapist in Denver specializing in anxiety, depression, and trauma.'),
    'too_short_to_say_anything ne mord pas sur un profil de 83 caractères';
  assert not pg_temp.mord('too_short_to_say_anything', repeat('x ', 400)),
    'too_short_to_say_anything mord sur un texte de 800 caractères';
end $$;

-- ---------------------------------------------------------------------------
-- 3. ⚠ L'ANCRAGE ^ DE credential_opens_the_text, LA SEULE RÈGLE ANCRÉE
-- ---------------------------------------------------------------------------
/*
 * En POSIX comme en JavaScript sans le drapeau `m`, `^` désigne le début du
 * TEXTE ENTIER, pas celui de chaque ligne. La question qui compte est donc :
 * que se passe-t-il quand elle colle son profil avec son nom, ou un titre, en
 * première ligne ?
 *
 * La réponse tient à `[^.!?]` : une classe NÉGATIVE contient le saut de ligne.
 * La fenêtre de 90 caractères traverse donc les lignes, et le credential reste
 * atteint. Les trois premières sondes le prouvent.
 *
 * Ce qui la fait taire, et c'est le bon sens du refus : une adresse assez
 * longue pour repousser le credential au-delà de 90 caractères, ou une phrase
 * qui se termine avant lui. Les deux sont des faux négatifs — la règle se tait
 * quand elle n'est pas sûre, jamais l'inverse.
 */
do $$
begin
  assert pg_temp.mord('credential_opens_the_text',
    'Jane Doe, LCSW, is a licensed clinical social worker practicing in Sacramento.'),
    'ancrage: le cas nu ne mord pas';

  assert pg_temp.mord('credential_opens_the_text',
    E'Jane Doe\nLCSW\n\nThe argument never lands anywhere.'),
    'ancrage: un NOM en première ligne fait rater le credential de la ligne suivante';

  assert pg_temp.mord('credential_opens_the_text',
    E'About My Practice\n\nI am a licensed therapist in Denver.'),
    'ancrage: un TITRE en première ligne fait rater le credential';

  -- La fenêtre de 90 caractères est une vraie borne, et elle se voit.
  assert not pg_temp.mord('credential_opens_the_text',
    E'Jane Doe\n1234 Alder Street, Suite 200, Sacramento, California 95814-2201\n(916) 555-0142\nI am a licensed therapist.'),
    'ancrage: la fenêtre de 90 caractères ne borne plus rien';

  -- Une phrase qui se termine ferme la fenêtre : c'est ce que `[^.!?]` veut dire.
  assert not pg_temp.mord('credential_opens_the_text',
    'The argument never lands anywhere. I am a licensed clinical social worker.'),
    'ancrage: le motif franchit une fin de phrase';

  assert not pg_temp.mord('credential_opens_the_text',
    'Something ended that you did not choose. Months have gone by.'),
    'ancrage: mord sur un texte sans aucun credential';
end $$;

-- ---------------------------------------------------------------------------
-- 4. Le plafond d'affichage
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  select (value #>> '{}')::int into v_n
    from public.app_settings where key = 'first_line_findings_shown';
  assert v_n is not null, 'le plafond d''affichage n''existe pas en base';
  assert v_n >= 1, 'un rapport qui ne montre aucun constat n''est pas un rapport';
  assert v_n < (select count(*) from public.positioning_rules where active),
    'le plafond est au-dessus du nombre de règles : il ne plafonne rien';
end $$;

rollback;

-- ⚠ APRÈS LE ROLLBACK : ce fichier n'écrit rien, mais on le prouve plutôt que
-- de le supposer — la fonction temporaire meurt avec la session, les dix règles
-- restent.
do $$
declare v_n int;
begin
  select count(*) into v_n from public.positioning_rules;
  assert v_n = 10, format('le test a laissé %s règle(s) au lieu de 10', v_n);
end $$;
