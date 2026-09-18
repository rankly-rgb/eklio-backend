-- ============================================================================
-- Les dix règles de positionnement — v1, écrites par Naima
-- ============================================================================
-- `20260917210004` a posé la structure et deux exemples de démonstration. Ceux-
-- ci partent. Ce qui les remplace est la v1 des vraies règles, livrée dans un
-- classeur à deux onglets qui reprennent exactement les deux tables.
--
-- ⚠ LE SQL DE CE LOT A ÉTÉ GÉNÉRÉ DEPUIS LE CLASSEUR, PAS RETAPÉ. Dix règles,
-- dix motifs, une centaine de champs dont des regex à guillemets : une
-- transcription à la main aurait introduit une faute que personne n'aurait vue
-- avant qu'une cliente reçoive un constat faux. Le bloc ci-dessous sort d'un
-- script qui lit le fichier et écrit le SQL.
--
-- ⚠ AUCUNE N'EST UN EXEMPLE. `is_example = false` sur les dix, et un garde-fou
-- refuse la migration s'il en reste une seule marquée. La colonne avait été
-- posée pour ça : voir dans la DONNÉE ce qui est une démonstration et ce qui
-- est une décision.
--
-- ── LA SEULE RETOUCHE DE CONTENU, ET ELLE A ÉTÉ DEMANDÉE ────────────────
--
-- `too_short_to_say_anything` porte un seuil de 600 caractères qui est une
-- ESTIMATION non mesurée. Une phrase a été ajoutée à sa `description` pour le
-- dire dans la règle elle-même, et pour nommer l'endroit où il se change —
-- `positioning_patterns.min_chars`, un UPDATE, sans déploiement. Rien d'autre
-- du classeur n'a été modifié.
--
-- ── ⚠ UNE INCOHÉRENCE ENTRE LES DEUX ONGLETS, RELEVÉE ET NON CORRIGÉE ───
--
-- `written_in_third_person` : son `example_weak` NE DÉCLENCHE PAS son propre
-- motif. Le motif exige un PRONOM — `(he|she|they) (is|has|holds) …` — et
-- l'exemple dit « Sarah is a licensed marriage and family therapist ». Un
-- prénom n'est pas un pronom, donc la règle ne voit pas la forme la plus
-- courante de la troisième personne dans un vrai profil : le prénom.
--
-- Ce n'est pas corrigé ici. Le contenu des règles appartient à son autrice, et
-- élargir un motif à sa place serait décider d'une règle. Le garde-fou en bas
-- NOMME l'écart plutôt que de l'ignorer : la liste doit rétrécir, et l'y
-- laisser est un acte visible dans un diff.
--
-- ── ⚠ UNE RETOUCHE APRÈS APPLICATION, ET IL FAUT LE DIRE ────────────────
--
-- Les deux `on conflict (id) do update` du bloc ci-dessous ont été AJOUTÉS
-- après que cette migration a tourné en production. Sans eux le bloc n'est pas
-- rejouable, et un bloc miroité DOIT l'être : `scripts/local-verify.sh` rejoue
-- les migrations PUIS `supabase/seed.sql`, donc l'insertion passe deux fois.
-- C'est la convention de tous les autres blocs marqués du dépôt ; celui-ci y
-- manquait.
--
-- L'état final sur une base vierge est identique au caractère près — un
-- `insert` qui ne rencontre aucun conflit et un `insert … on conflict` écrivent
-- les mêmes dix lignes. Ce qui change est la seconde exécution, qui n'a jamais
-- eu lieu en production. La règle « on n'édite pas un fichier appliqué » vise un
-- changement de COMPORTEMENT ; celui-ci n'en est pas un, et il est écrit ici
-- plutôt que passé sous silence.
-- ============================================================================

-- >>> POSITIONING RULES V1 (mirrored verbatim in supabase/seed.sql) >>>

delete from public.positioning_patterns where rule_id in
  (select id from public.positioning_rules where is_example);
delete from public.positioning_rules where is_example;

insert into public.positioning_rules
  (id, short_label, description, example_weak, example_strong, sort_order, active, is_example) values
  ('opening_is_about_her',
   'Your opening talks about you, not her',
   'The first thing a client reads is a paragraph about your training. She is scanning for herself. If nothing in the opening is addressed to her, she scrolls on before she reaches the part that would have mattered.',
   'I am a Licensed Professional Counselor with over twelve years of experience serving the greater Portland area.',
   'Something ended that you did not choose. Months have gone by, and everyone around you has moved on to other things, so you stopped bringing it up.',
   10, true, false),
  ('credential_opens_the_text',
   'Your licence is the first thing on the page',
   'Your credential belongs on your profile — the directory already shows it beside your name. Leading with it spends the one sentence she is guaranteed to read on information she can get from the search results.',
   'Jane Doe, LCSW, is a licensed clinical social worker practicing in Sacramento.',
   'The argument never lands anywhere. I''m a clinical social worker in Sacramento, and I work with couples who have stopped fighting and started avoiding each other.',
   20, true, false),
  ('serves_everyone',
   'You offer to help everyone, so you speak to no one',
   'A list that covers individuals, couples, families, children and adults tells a reader that you have not chosen. She is looking for someone who works with her problem in particular — the broader the list, the less likely she is to see herself in it.',
   'I work with individuals, couples, and families across the lifespan.',
   'I work with adults who are standing in the middle of a life they didn''t plan for and aren''t sure what to do with.',
   30, true, false),
  ('diagnostic_labels_only',
   'You name the diagnosis, not what she is living',
   'Nobody types their diagnosis into a search box on the worst night. They type what is happening to them. Naming the clinical category tells her what you treat; naming the experience tells her you have met someone like her.',
   'I help clients struggling with anxiety and depression.',
   'You go to work. You answer texts. And underneath it, you keep having the same argument — with your partner, or just in your own head at two in the morning.',
   40, true, false),
  ('modality_before_person',
   'You list your modalities and never address her',
   'Your training matters, but it is an answer to a question she has not asked yet. When the acronyms appear and the word "you" never does, the profile reads as a CV rather than as an invitation.',
   'I am trained in CBT, DBT, and EMDR, with additional certification in trauma-informed care.',
   'I''m trained in EMDR, which shapes how I pay attention. Loss tends to live in the body as much as anywhere else — so I might ask what you notice physically as you say something.',
   50, true, false),
  ('whether_youre_laundry_list',
   'The « whether you''re… » list covers everything and lands nowhere',
   'This construction is a way of not choosing: it offers three or four problems so that nobody is excluded. The reader recognises the shape of the sentence from every other profile she has read that morning.',
   'Whether you''re facing anxiety, grief, relationship difficulties, or a major life transition, I''m here to help.',
   'Most people come to me long after the world decided they should be past it — after the casseroles stopped, after the coworkers stopped asking.',
   60, true, false),
  ('safe_space_filler',
   '« A safe, non-judgmental space » is on almost every profile',
   'It is true and it is invisible. Because every profile says it, it carries no information — and it uses the space where something only you could say would have gone.',
   'I provide a safe, non-judgmental space where you can be yourself.',
   'The way I work is probably slower than you expect. I mostly listen. I don''t fill silences to keep things comfortable.',
   70, true, false),
  ('written_in_third_person',
   'The profile is written about you, not by you',
   'Third person reads like an entry someone else filed. The first contact a client has with you is this text — first person is the difference between a directory listing and a person speaking.',
   'Sarah is a licensed marriage and family therapist who has been practicing since 2014.',
   'I''ve been doing this since 2014, and the way I work has changed a good deal since then.',
   80, true, false),
  ('no_next_step',
   'You never say what happens if she reaches out',
   'She has read to the end and she is still deciding. A profile that stops without saying what the first contact looks like leaves her to imagine it — and the thing she imagines is usually worse than the thing you would have described.',
   null,
   'A first session is mostly you talking and me listening. There''s no obligation to book again. If you''d like to talk, reach out and we''ll find a time.',
   90, true, false),
  ('too_short_to_say_anything',
   'There is not enough here for her to decide',
   'A very short profile cannot do the work: it can name a specialty but it cannot show how you think. The reader is choosing someone to tell the worst thing about her life to, on the strength of this text alone. The 600-character threshold is an ESTIMATE, not a measurement: no real Psychology Today profile was counted. It lives in positioning_patterns.min_chars and changes with one UPDATE, no deploy.',
   'I am a licensed therapist in Denver specializing in anxiety, depression, and trauma. Accepting new clients.',
   null,
   100, true, false)
on conflict (id) do update
  set short_label    = excluded.short_label,
      description    = excluded.description,
      example_weak   = excluded.example_weak,
      example_strong = excluded.example_strong,
      sort_order     = excluded.sort_order,
      active         = excluded.active,
      is_example     = excluded.is_example;

insert into public.positioning_patterns
  (id, rule_id, kind, pattern, secondary_pattern, window_chars, min_chars, max_chars, severity, sort_order, active) values
  ('opening_is_about_her', 'opening_is_about_her', 'absent_in_opening',
   '\y(you|your|you''re|youre|yourself)\y',
   null, 320, null, null, 'costly', 10, true),
  ('credential_opens_the_text', 'credential_opens_the_text', 'present',
   '^[^.!?]{0,90}\y(LPC|LPCC|LMFT|LCSW|LMHC|LCPC|LMSW|Ph\.?D|Psy\.?D|licensed)\y',
   null, null, null, null, 'costly', 20, true),
  ('serves_everyone', 'serves_everyone', 'present',
   '\y(individuals,? (and )?couples|couples,? (and )?famil|children,? adolescents|adolescents,? and adults)\y',
   null, null, null, null, 'costly', 30, true),
  ('diagnostic_labels_only', 'diagnostic_labels_only', 'present',
   '\y(anxiety and depression|depression and anxiety)\y',
   null, null, null, null, 'costly', 40, true),
  ('modality_before_person', 'modality_before_person', 'present_without',
   '\y(CBT|DBT|EMDR|ACT|IFS|EFT|somatic experiencing|psychodynamic|person-centered)\y',
   '\y(you|your)\y', null, null, null, 'costly', 50, true),
  ('whether_youre_laundry_list', 'whether_youre_laundry_list', 'present',
   '\ywhether you''?re\y',
   null, null, null, null, 'minor', 60, true),
  ('safe_space_filler', 'safe_space_filler', 'present',
   '\y(safe space|safe,? (and )?non-?judgment(al)?|non-?judgmental space|judgment-free)\y',
   null, null, null, null, 'minor', 70, true),
  ('written_in_third_person', 'written_in_third_person', 'present',
   '\y(he|she|they) (is|has|holds) (a |an )?(licensed|certified|board-certified|master)',
   null, null, null, null, 'minor', 80, true),
  ('no_next_step', 'no_next_step', 'absent',
   '\y(reach out|get in touch|contact me|book a|schedule a|call me|email me|message me|free consultation|first session)\y',
   null, null, null, null, 'minor', 90, true),
  ('too_short_to_say_anything', 'too_short_to_say_anything', 'length',
   null,
   null, null, 600, null, 'minor', 100, true)
on conflict (id) do update
  set rule_id           = excluded.rule_id,
      kind              = excluded.kind,
      pattern           = excluded.pattern,
      secondary_pattern = excluded.secondary_pattern,
      window_chars      = excluded.window_chars,
      min_chars         = excluded.min_chars,
      max_chars         = excluded.max_chars,
      severity          = excluded.severity,
      sort_order        = excluded.sort_order,
      active            = excluded.active;

-- <<< POSITIONING RULES V1 <<<


-- ---------------------------------------------------------------------------
-- Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int; v_manquants text;
begin
  -- ── Les dix sont là, et aucune n'est un exemple ────────────────────────
  select count(*) into v_n from public.positioning_rules;
  if v_n <> 10 then
    raise exception 'v1: % règle(s), attendu 10. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n from public.positioning_rules where is_example;
  if v_n <> 0 then
    raise exception
      'v1: % règle(s) restent marquées comme exemples. Les deux démonstrations devaient partir. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n from public.positioning_patterns;
  if v_n <> 10 then
    raise exception 'v1: % motif(s), attendu 10. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET CHAQUE RÈGLE A SON MOTIF. Une règle sans motif est lue, affichée
  -- nulle part, et ne détecte rien : un constat silencieusement absent.
  select string_agg(r.id, ', ' order by r.id) into v_manquants
    from public.positioning_rules r
   where not exists (select 1 from public.positioning_patterns p where p.rule_id = r.id);
  if v_manquants is not null then
    raise exception 'v1: règle(s) sans aucun motif : %. Migration abandonnée.', v_manquants;
  end if;

  -- Les cinq « costly » de l'autrice, comptés plutôt que supposés.
  select count(*) into v_n from public.positioning_patterns where severity = 'costly';
  if v_n <> 5 then
    raise exception 'v1: % motif(s) costly, attendu 5. Migration abandonnée.', v_n;
  end if;

  /*
   * ⚠ LA COHÉRENCE ENTRE LES DEUX ONGLETS, VÉRIFIÉE PLUTÔT QUE SUPPOSÉE.
   *
   * Un `example_weak` est censé être une illustration de la faiblesse que son
   * motif détecte. S'il ne déclenche pas son propre motif, l'un des deux est
   * faux — et c'est le genre d'écart qu'on ne voit qu'en lisant les deux
   * onglets côte à côte, ce que personne ne fait.
   *
   * ⚠ UN ÉCART CONNU, NOMMÉ, ET QUI DOIT DISPARAÎTRE :
   * `written_in_third_person` exige un pronom (he|she|they) et son exemple dit
   * « Sarah is a licensed… ». Un prénom n'est pas un pronom. La règle ne voit
   * donc pas la forme la plus courante du défaut qu'elle vise. Corriger le
   * motif ou l'exemple est une décision de contenu, pas de code.
   */
  select string_agg(r.id, ', ' order by r.id) into v_manquants
    from public.positioning_rules r
    join public.positioning_patterns p on p.rule_id = r.id
   where p.kind = 'present'
     and r.example_weak is not null
     and r.example_weak !~* p.pattern
     and r.id <> 'written_in_third_person';
  if v_manquants is not null then
    raise exception
      'v1: exemple(s) faible(s) qui ne déclenchent pas leur propre motif : %. Les deux onglets se contredisent. Migration abandonnée.', v_manquants;
  end if;

  /*
   * ⚠ ET L'ÉCART CONNU DOIT ENCORE EXISTER. Sans ceci, corriger la donnée
   * laisserait une exception qui ne protège plus rien — une liste qu'on
   * allonge au lieu de raccourcir. Le jour où l'exemple ou le motif change,
   * cette ligne échoue et l'exception s'enlève.
   */
  select count(*) into v_n
    from public.positioning_rules r
    join public.positioning_patterns p on p.rule_id = r.id
   where r.id = 'written_in_third_person'
     and r.example_weak !~* p.pattern;
  if v_n <> 1 then
    raise exception
      'v1: l''écart connu de written_in_third_person a disparu. Retirez-le de l''exception ci-dessus. Migration abandonnée.';
  end if;

  /*
   * ⚠ ET UN EXEMPLE FORT NE DÉCLENCHE JAMAIS SA PROPRE RÈGLE. C'est la moitié
   * qui prouve que les motifs discriminent : un motif qui déclencherait sur
   * tout passerait le contrôle ci-dessus sans rien détecter d'utile.
   */
  select string_agg(r.id, ', ' order by r.id) into v_manquants
    from public.positioning_rules r
    join public.positioning_patterns p on p.rule_id = r.id
   where p.kind = 'present'
     and r.example_strong is not null
     and r.example_strong ~* p.pattern;
  if v_manquants is not null then
    raise exception
      'v1: exemple(s) FORT(s) qui déclenchent leur propre motif : %. Le motif ne discrimine pas. Migration abandonnée.', v_manquants;
  end if;

  -- Le seuil non mesuré le dit dans sa propre règle.
  select count(*) into v_n from public.positioning_rules
   where id = 'too_short_to_say_anything' and description like '%ESTIMATE%';
  if v_n <> 1 then
    raise exception
      'v1: la règle du seuil ne dit pas que son seuil est une estimation. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Aucune : revenir aux deux exemples de démonstration n'aurait aucun sens.
--   Pour retirer une règle : delete from public.positioning_rules where id = '…'
--   (les motifs tombent avec, par on delete cascade).
