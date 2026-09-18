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
       -- L'écart connu : l'exemple dit « Sarah », le motif exige un pronom.
       and rl.id <> 'written_in_third_person'
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
   * ⚠ L'ÉCART CONNU, SONDÉ DANS LES DEUX SENS. Le motif exige un pronom, donc
   * il mord sur « She is a licensed… » et se tait sur « Sarah is a licensed… ».
   * Le second est la forme la plus courante dans un vrai profil : la règle ne
   * la voit pas, et cette sonde est ce qui empêche de l'oublier.
   */
  assert pg_temp.mord('written_in_third_person', 'She is a licensed marriage and family therapist.'),
    'written_in_third_person ne mord pas sur un pronom — le motif est cassé';
  assert not pg_temp.mord('written_in_third_person',
    'Sarah is a licensed marriage and family therapist who has been practicing since 2014.'),
    'written_in_third_person mord désormais sur un prénom : l''écart connu est réparé, '
    'retirez l''exception de ce fichier et de la migration.';

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
