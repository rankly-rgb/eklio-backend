-- ============================================================================
-- Le positionnement est une seconde famille de règles, et ce sont des DONNÉES
-- ============================================================================
-- Le palier gratuit promet « on vous dit ce qui ne va pas ». Il ne savait
-- répondre que sur la déontologie — six motifs qui détectent une FAUTE. Or la
-- cliente type n'en commet aucune :
--
--   « I hold a PhD from Berkeley and have been licensed in California for
--     twelve years. »  →  zéro constat. Mesuré, pas supposé.
--
-- Irréprochable et vide. Le produit répondait « rien » à celle qui en a le plus
-- besoin, et c'est le défaut le plus coûteux du lot précédent.
--
-- ⚠ LES DEUX FAMILLES NE SE MÉLANGENT PAS, ET LA SÉVÉRITÉ LE DIT. Une faute
-- déontologique est « à corriger » : `ethics_patterns.severity` vaut `block` ou
-- `warn`, et un `block` REFUSE une écriture. Une faiblesse de positionnement
-- est « voilà pourquoi personne ne vous écrit » : elle n'a jamais refusé quoi
-- que ce soit, et son vocabulaire est donc AUTRE — `costly` ou `minor`. Deux
-- ensembles de valeurs disjoints, pour qu'aucun code ne puisse traiter l'un
-- pour l'autre par distraction.
--
-- ── CE QUE LA TABLE PEUT DÉTECTER, ET CE QU'ELLE NE PEUT PAS ────────────
--
-- Une règle de positionnement est une affirmation SUR LE TEXTE SEUL, vérifiable
-- en comptant ou en filtrant. Cinq formes, et elles suffisent parce qu'elles
-- couvrent les deux choses que la déontologie ne sait pas voir : une ABSENCE,
-- et une PROPORTION.
--
--   present            un motif apparaît                    (comme l'éthique)
--   absent             un motif n'apparaît nulle part
--   absent_in_opening  un motif n'apparaît pas dans les N premiers caractères
--   present_without    A apparaît sans que B apparaisse
--   length             le texte sort d'un encadrement de longueur
--
-- ⚠ ET CE QU'AUCUNE RÈGLE ICI NE POURRA JAMAIS DIRE, écrit pour que personne
-- n'essaie de l'y faire entrer :
--
--   · si c'est VRAI — que le texte dise qu'elle reçoit des jeunes mères ne
--     prouve pas qu'elle en reçoit ;
--   · si c'est DIFFÉRENCIANT — il faudrait les profils voisins, et aucune
--     source de données des deux dépôts ne les porte ;
--   · si la PROSE est bonne, si le TON sonne juste ;
--   · si le problème nommé est celui que SA cliente nommerait.
--
-- Une règle qui aurait besoin de l'une de ces quatre réponses n'est pas une
-- règle de cette table. Elle appartient à un humain qui relit.
--
-- ── DEUX TABLES, COMME POUR LA DÉONTOLOGIE ──────────────────────────────
--
--   positioning_rules     ce qu'elle LIT — le constat, en mots
--   positioning_patterns  comment on le DÉTECTE — la mécanique
--
-- ⚠ ET UNE DIFFÉRENCE ASSUMÉE AVEC `ethics_patterns` : celle-ci est lue par
-- L'APPLICATION. `ethics_patterns` a un jumeau TypeScript (`lib/ethics/rules.ts`)
-- parce que le scan doit aussi tourner dans un trigger SQL ; deux copies de la
-- même vérité, que le dépôt assume et surveille. Le positionnement n'a pas de
-- chemin d'écriture en base à garder : une seule copie, et c'est la table.
-- Recopier ces motifs en TypeScript serait refaire volontairement un problème
-- qu'on subit ailleurs.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Ce qu'elle lit
-- ---------------------------------------------------------------------------
create table if not exists public.positioning_rules (
  id             text     not null,
  short_label    text     not null,
  description    text     not null,
  /*
   * ⚠ DEUX EXEMPLES, LÀ OÙ LA DÉONTOLOGIE N'EN A QU'UN. `ethics_rules` porte
   * `example_forbidden` et rien d'autre, parce que le correctif d'une faute est
   * de ne pas la commettre — montrer la version juste n'apprend rien.
   *
   * Un positionnement faible n'a pas cette propriété : « ne dites pas ça » ne
   * dit pas quoi dire à la place, et c'est justement ce qu'elle ne sait pas.
   * La paire faible/fort EST l'enseignement.
   */
  example_weak   text,
  example_strong text,
  sort_order     smallint not null,
  active         boolean  not null default true,
  /*
   * ⚠ POSÉ PAR CE LOT, ET IL DOIT REDEVENIR FAUX PARTOUT. Les lignes semées
   * ici sont des démonstrations de structure, pas des décisions produit. La
   * colonne existe pour qu'on le voie DANS LA DONNÉE et pas seulement dans un
   * commentaire de migration que personne ne relit.
   */
  is_example     boolean  not null default false,

  constraint positioning_rules_pkey primary key (id),
  constraint positioning_rules_label_check check (btrim(short_label) <> ''),
  constraint positioning_rules_description_check check (btrim(description) <> ''),
  /* Pas de chaîne vide : l'absence d'exemple est NULL, une seule façon de le dire. */
  constraint positioning_rules_weak_check
    check (example_weak is null or btrim(example_weak) <> ''),
  constraint positioning_rules_strong_check
    check (example_strong is null or btrim(example_strong) <> '')
);

comment on table public.positioning_rules is
  'The positioning findings a practitioner reads, as DATA. Sibling of ethics_rules and deliberately NOT the same family: an ethics rule says "fix this", a positioning rule says "this is why nobody writes to you". A profile can be flawless and empty, and only this table sees that.';
comment on column public.positioning_rules.example_strong is
  'The same thing done differently. ethics_rules has no equivalent on purpose: not committing a breach is its own fix, whereas "do not say that" leaves a weak opening with nothing to become.';
comment on column public.positioning_rules.is_example is
  'TRUE on rows seeded as structural demonstrations rather than product decisions. Meant to go back to false everywhere once real rules are written. Visible in the data, not only in a migration comment.';


-- ---------------------------------------------------------------------------
-- 2. Comment on le détecte
-- ---------------------------------------------------------------------------
create table if not exists public.positioning_patterns (
  id                text     not null,
  rule_id           text     not null,
  /*
   * ⚠ LES CINQ FORMES, ET LA RAISON D'AVOIR PLUS QU'UN MOTIF. `ethics_patterns`
   * n'a qu'une forme — « ce texte CONTIENT ceci » — parce qu'une faute est
   * toujours quelque chose de présent. Une faiblesse de positionnement est le
   * plus souvent une ABSENCE, et une absence ne se détecte pas avec un motif
   * positif, quel qu'il soit.
   */
  kind              text     not null,
  /* Motif POSIX, comme ethics_patterns.pattern. NULL pour `length` seulement. */
  pattern           text,
  /* Le B de `present_without` : A est là, B manque. */
  secondary_pattern text,
  /* La fenêtre d'ouverture, en caractères. `absent_in_opening` seulement. */
  window_chars      integer,
  min_chars         integer,
  max_chars         integer,
  /*
   * ⚠ `costly` OU `minor`, JAMAIS `block`. Le vocabulaire est disjoint de
   * celui de la déontologie pour qu'un `block` ne puisse pas arriver ici par
   * copier-coller, et parce qu'un positionnement faible ne refuse rien : il
   * explique. `costly` veut dire « ceci seul explique plausiblement qu'on ne
   * lui écrive pas » ; `minor`, « à gagner, mais ce n'est pas la raison ».
   */
  severity          text     not null,
  sort_order        smallint not null,
  active            boolean  not null default true,

  constraint positioning_patterns_pkey primary key (id),
  constraint positioning_patterns_rule_fkey
    foreign key (rule_id) references public.positioning_rules (id) on delete cascade,
  constraint positioning_patterns_kind_check
    check (kind = any (array['present', 'absent', 'absent_in_opening', 'present_without', 'length'])),
  constraint positioning_patterns_severity_check
    check (severity = any (array['costly', 'minor'])),

  /*
   * ⚠ CHAQUE FORME EXIGE SES CHAMPS ET REFUSE LES AUTRES. Sans ces trois
   * contraintes, une règle `length` sans bornes ne détecterait jamais rien et
   * une règle `absent_in_opening` sans fenêtre non plus : elles seraient
   * INSÉRÉES, elles seraient LUES, et elles ne diraient rien — un constat
   * silencieusement absent, que personne ne remarque parce qu'il n'y a rien à
   * remarquer. C'est le défaut permissif de ce dépôt, révoqué à l'insertion.
   */
  constraint positioning_patterns_pattern_check check (
    case when kind = 'length' then pattern is null
         else pattern is not null and btrim(pattern) <> '' end
  ),
  constraint positioning_patterns_secondary_check check (
    case when kind = 'present_without'
         then secondary_pattern is not null and btrim(secondary_pattern) <> ''
         else secondary_pattern is null end
  ),
  constraint positioning_patterns_window_check check (
    case when kind = 'absent_in_opening' then window_chars is not null and window_chars > 0
         else window_chars is null end
  ),
  constraint positioning_patterns_length_check check (
    case when kind = 'length'
         then (min_chars is not null or max_chars is not null)
              and coalesce(min_chars, 0) >= 0
              and coalesce(max_chars, 2147483647) > coalesce(min_chars, 0)
         else min_chars is null and max_chars is null end
  )
);

comment on table public.positioning_patterns is
  'How each positioning rule is detected, as DATA the APPLICATION reads. Five kinds, because a positioning weakness is usually an ABSENCE or a PROPORTION and neither is expressible as a positive match. Unlike ethics_patterns it has no TypeScript twin: there is no SQL write path to guard here, so one copy, and this is it.';
comment on column public.positioning_patterns.kind is
  'present | absent | absent_in_opening | present_without | length. What a rule can be about: something said, something never said, something not said EARLY, something said without its companion, or a size. Anything needing to know whether the claim is TRUE, whether it is DIFFERENT from the neighbours, or whether the prose is any good is not a rule for this table.';
comment on column public.positioning_patterns.severity is
  'costly | minor -- deliberately disjoint from ethics_patterns.severity (block | warn) so the two families can never be treated alike by accident. Nothing here ever blocks a write.';


-- ---------------------------------------------------------------------------
-- 3. Lisibles par l'écran, écrites par personne
-- ---------------------------------------------------------------------------
/*
 * Même régime qu'`ethics_patterns` : le palier gratuit n'a pas de session, donc
 * `anon` doit pouvoir lire. Écriture refusée à tout le monde côté navigateur —
 * ces lignes changent par migration ou par le rôle de service, jamais depuis un
 * onglet.
 */
alter table public.positioning_rules    enable row level security;
alter table public.positioning_patterns enable row level security;

drop policy if exists positioning_rules_select_all on public.positioning_rules;
create policy positioning_rules_select_all on public.positioning_rules
  for select to anon, authenticated using (true);
drop policy if exists positioning_rules_write_denied on public.positioning_rules;
create policy positioning_rules_write_denied on public.positioning_rules
  for all using (false) with check (false);

drop policy if exists positioning_patterns_select_all on public.positioning_patterns;
create policy positioning_patterns_select_all on public.positioning_patterns
  for select to anon, authenticated using (true);
drop policy if exists positioning_patterns_write_denied on public.positioning_patterns;
create policy positioning_patterns_write_denied on public.positioning_patterns
  for all using (false) with check (false);

grant select on public.positioning_rules    to anon, authenticated, service_role;
grant select on public.positioning_patterns to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 4. Deux exemples, étiquetés comme tels
-- ---------------------------------------------------------------------------
-- >>> POSITIONING RULE EXAMPLES (mirrored verbatim in supabase/seed.sql) >>>

/*
 * ⚠ CES DEUX LIGNES SONT DES EXEMPLES DE STRUCTURE, PAS DES RÈGLES. Elles
 * portent `is_example = true`, leur libellé commence par « EXAMPLE », et elles
 * sont là pour UNE raison : qu'on puisse voir la mécanique tourner avant que
 * les vraies règles soient écrites. Elles ne sont pas le fruit d'une décision
 * produit et personne ne doit les lire comme telles.
 *
 * Les remplacer est un INSERT et un DELETE, sans déploiement.
 */
insert into public.positioning_rules
  (id, short_label, description, example_weak, example_strong, sort_order, is_example) values
  ('example_opens_on_the_writer',
   'EXAMPLE — the opening is about you, not about her',
   'PROVISIONAL EXAMPLE, NOT A REAL RULE. Someone scanning a directory reads two or three lines before deciding. If those lines are about your training, she has learned nothing about whether you understand what is happening to her.',
   'I hold a PhD from Berkeley and have been licensed in California for twelve years.',
   'The mornings are the hardest part, and you have stopped telling people how little you slept.',
   1, true),
  ('example_length_for_the_snippet',
   'EXAMPLE — the opening is longer than a search result shows',
   'PROVISIONAL EXAMPLE, NOT A REAL RULE. The bounds below are a placeholder: nobody has measured what Psychology Today actually truncates in search results. See FIRST_LINE_TARGET_CHARS in lib/check/first-line.ts.',
   null, null, 2, true)
on conflict (id) do update
  set short_label   = excluded.short_label,
      description   = excluded.description,
      example_weak  = excluded.example_weak,
      example_strong = excluded.example_strong,
      sort_order    = excluded.sort_order,
      is_example    = excluded.is_example;

insert into public.positioning_patterns
  (id, rule_id, kind, pattern, window_chars, min_chars, max_chars, severity, sort_order) values
  /* La fenêtre : est-ce que la lectrice apparaît dans l'ouverture ? */
  ('example_no_second_person_up_front', 'example_opens_on_the_writer',
   'absent_in_opening', '\y(you|your|yours|you''re|you''ve)\y', 320, null, null, 'costly', 1),
  /* La longueur, seule des cinq formes à ne porter aucun motif. */
  ('example_opening_too_long', 'example_length_for_the_snippet',
   'length', null, null, 40, 700, 'minor', 2)
on conflict (id) do update
  set rule_id      = excluded.rule_id,
      kind         = excluded.kind,
      pattern      = excluded.pattern,
      window_chars = excluded.window_chars,
      min_chars    = excluded.min_chars,
      max_chars    = excluded.max_chars,
      severity     = excluded.severity,
      sort_order   = excluded.sort_order;

-- <<< POSITIONING RULE EXAMPLES <<<


-- ---------------------------------------------------------------------------
-- 5. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  -- ── Ce qui est semé est semé, et c'est étiqueté ────────────────────────
  select count(*) into v_n from public.positioning_rules;
  if v_n <> 2 then
    raise exception 'positionnement: % règle(s) semées, attendu 2. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n from public.positioning_rules where not is_example;
  if v_n <> 0 then
    raise exception
      'positionnement: % règle(s) semées ne sont pas marquées comme exemples. Ce lot ne décide AUCUNE règle de contenu. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n from public.positioning_patterns;
  if v_n <> 2 then
    raise exception 'positionnement: % motif(s) semés, attendu 2. Migration abandonnée.', v_n;
  end if;

  -- ── ⚠ ET LES CONTRAINTES DE FORME MORDENT, UNE PAR UNE ────────────────
  --
  -- Sans ces six sondes, les `check` ci-dessus seraient des déclarations
  -- d'intention. Une règle mal formée est pire qu'une règle absente : elle est
  -- insérée, elle est lue, et elle ne détecte rien — un constat silencieux.

  begin
    insert into public.positioning_patterns (id, rule_id, kind, pattern, severity, sort_order)
    values ('_probe', 'example_opens_on_the_writer', 'length', 'x', 'minor', 99);
    raise exception 'positionnement: une règle « length » a été acceptée AVEC un motif. Migration abandonnée.';
  exception when check_violation then null;
  end;

  begin
    insert into public.positioning_patterns (id, rule_id, kind, min_chars, max_chars, severity, sort_order)
    values ('_probe', 'example_opens_on_the_writer', 'length', 700, 40, 'minor', 99);
    raise exception 'positionnement: une règle « length » dont le maximum est sous le minimum a été acceptée. Migration abandonnée.';
  exception when check_violation then null;
  end;

  begin
    insert into public.positioning_patterns (id, rule_id, kind, pattern, severity, sort_order)
    values ('_probe', 'example_opens_on_the_writer', 'absent_in_opening', '\yyou\y', 'costly', 99);
    raise exception 'positionnement: une règle « absent_in_opening » SANS fenêtre a été acceptée — elle n''aurait jamais rien détecté. Migration abandonnée.';
  exception when check_violation then null;
  end;

  begin
    insert into public.positioning_patterns (id, rule_id, kind, pattern, severity, sort_order)
    values ('_probe', 'example_opens_on_the_writer', 'present_without', '\yEMDR\y', 'minor', 99);
    raise exception 'positionnement: une règle « present_without » SANS second motif a été acceptée. Migration abandonnée.';
  exception when check_violation then null;
  end;

  begin
    insert into public.positioning_patterns (id, rule_id, kind, pattern, severity, sort_order)
    values ('_probe', 'example_opens_on_the_writer', 'present', '\yEMDR\y', 'block', 99);
    raise exception 'positionnement: la sévérité « block » de la déontologie a été acceptée ici. Les deux familles ne se mélangent pas. Migration abandonnée.';
  exception when check_violation then null;
  end;

  begin
    insert into public.positioning_patterns (id, rule_id, kind, pattern, severity, sort_order)
    values ('_probe', 'example_opens_on_the_writer', 'vibes', '\yEMDR\y', 'minor', 99);
    raise exception 'positionnement: une sixième forme inventée a été acceptée. Migration abandonnée.';
  exception when check_violation then null;
  end;

  -- ⚠ ET LA MOITIÉ QUI PROUVE QUE LA PORTE EST UNE PORTE. Sans elle, une table
  -- qui refuserait TOUT passerait les six sondes ci-dessus.
  insert into public.positioning_patterns
    (id, rule_id, kind, pattern, secondary_pattern, severity, sort_order)
  values ('_probe_ok', 'example_opens_on_the_writer', 'present_without',
          '\yEMDR\y', '\yyou\y', 'minor', 99);
  select count(*) into v_n from public.positioning_patterns where id = '_probe_ok';
  if v_n <> 1 then
    raise exception 'positionnement: une règle BIEN formée est refusée. Migration abandonnée.';
  end if;
  delete from public.positioning_patterns where id = '_probe_ok';

  -- La sonde n'a rien laissé.
  select count(*) into v_n from public.positioning_patterns;
  if v_n <> 2 then
    raise exception 'positionnement: la sonde a laissé % motif(s), attendu 2. Migration abandonnée.', v_n;
  end if;

  -- ── La surface : le palier gratuit n'a pas de session ─────────────────
  if not has_table_privilege('anon', 'public.positioning_rules', 'select') then
    raise exception 'positionnement: les règles ne sont pas lisibles sans compte. Migration abandonnée.';
  end if;
  if not has_table_privilege('anon', 'public.positioning_patterns', 'select') then
    raise exception 'positionnement: les motifs ne sont pas lisibles sans compte. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop table if exists public.positioning_patterns;
--   drop table if exists public.positioning_rules;
