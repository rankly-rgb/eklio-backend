-- ============================================================================
-- L'Ethics Guard entre dans l'écriture
-- ============================================================================
-- ⚠ C'EST LE SEUL LOT DE CE CHANTIER DONT L'ABSENCE COÛTE UNE LICENCE
-- PROFESSIONNELLE À UNE CLIENTE, PAS UN CLIENT À EKLIO.
--
-- Aujourd'hui la garde déontologique vit ENTIÈREMENT dans l'application :
-- `lib/ethics/rules.ts` compile dix-huit motifs, `enforceEthics` réécrit le
-- champ fautif, et le verdict est rangé dans `brand_kits.ethics_check`.
--
-- Elle couvre donc ce qui passe par la pipeline de génération. Elle ne couvre
-- PAS ce qui entre par une RPC :
--
--   site_spec_patch      la praticienne édite la copy de son site
--   update_content_item  elle édite une légende
--
-- Les deux écrivent du texte qui sera publié sous sa licence, et aucune ne
-- scanne quoi que ce soit. `FINDINGS.md` (frontend) le nomme depuis un moment :
-- « ⚠ The Lovable re-scan does NOT cover her copy ».
--
-- ── DEUX DÉCISIONS, ET IL FAUT LES DIRE ─────────────────────────────────────
--
-- 1. LES MOTIFS DEVIENNENT UNE DONNÉE. Ils sont aujourd'hui dans du
--    TypeScript ; une fonction SQL ne peut pas les lire. Les recopier dans le
--    corps d'une fonction SQL serait la divergence que ce dépôt a déjà payée
--    trois fois. Ils vont donc dans une table, à côté de `ethics_rules` qui
--    porte déjà le TEXTE des six règles et de `banned_phrases` qui porte déjà
--    trente formulations. C'est le motif établi de ce schéma.
--
--    ⚠ ET IL RESTE DEUX IMPLÉMENTATIONS. Le scanner TypeScript garde ses
--    expressions régulières compilées ; celui-ci est en SQL. Les deux sont
--    tenus au MÊME CORPUS — `ethics_rules.example_forbidden`, six phrases que
--    chacun doit bloquer — et un test de chaque côté le vérifie. C'est une
--    réconciliation partielle, pas une fusion : elle est consignée comme telle
--    dans OUT_OF_SCOPE.md plutôt que présentée comme réglée.
--
-- 2. LE SCAN EST UN TRIGGER, PAS UNE LIGNE DANS `site_spec_patch`.
--    Le cahier demande « un scan à l'intérieur de `site_spec_patch` et
--    `update_content_item`, pas seulement en amont ». Un trigger sur la table
--    est à l'intérieur de l'écriture et couvre PLUS : `site_spec_patch` n'est
--    pas le seul écrivain possible de `site_specs`, et le prochain ne se
--    souviendra pas d'appeler le scan. Un garde qu'il faut penser à appeler
--    est un garde qu'on oubliera.
--
-- ── CE QUE LE SCAN SQL NE FAIT PAS ──────────────────────────────────────────
--
-- Il ne RÉÉCRIT pas. `enforceEthics` demande au modèle de corriger le champ
-- fautif ; une contrainte d'écriture ne peut que refuser. C'est le bon partage :
-- la génération répare, l'édition à la main est arrêtée avec la phrase fautive
-- citée, et la praticienne corrige ses propres mots elle-même.
-- ============================================================================

-- ── 1. Les motifs, en données ───────────────────────────────────────────────

create table if not exists public.ethics_patterns (
  id               text        not null,
  rule_id          text        not null,
  -- Expression régulière POSIX, insensible à la casse à l'usage (`~*`).
  pattern          text        not null,
  -- ⚠ POSTGRES N'A PAS D'ANTICIPATION NÉGATIVE. Un des motifs TypeScript
  -- utilise `(?!\s+(?:best\s+)?for\s+you)` pour laisser passer « a therapy
  -- that works best for you ». Sans exception explicite, la traduction SQL
  -- REFUSERAIT cette phrase — un faux positif qui bloque une écriture
  -- légitime, dans le sens qui fait perdre son travail à quelqu'un. La
  -- deuxième colonne porte donc l'exception, au lieu de la perdre.
  exception_pattern text,
  severity         text        not null,
  sort_order       smallint    not null,
  active           boolean     not null default true,
  constraint ethics_patterns_pkey primary key (id),
  constraint ethics_patterns_rule_fkey foreign key (rule_id) references public.ethics_rules (id),
  constraint ethics_patterns_severity_check check (severity = any (array['block', 'warn'])),
  constraint ethics_patterns_pattern_check  check (btrim(pattern) <> ''),
  -- `is null or`, parce qu'un CHECK accepte NULL.
  constraint ethics_patterns_exception_check
    check (exception_pattern is null or btrim(exception_pattern) <> '')
);

comment on table public.ethics_patterns is
  'The deterministic advertising-ethics patterns, as DATA. They lived only in TypeScript, where no SQL function can read them - and a scan that runs only in the application does not cover text written straight through a RPC. Sibling of ethics_rules (the six rules in words) and banned_phrases (thirty literal formulations).';
comment on column public.ethics_patterns.exception_pattern is
  'Postgres has no negative lookahead. A pattern that needs one carries its exception here instead of losing it, which would turn a legitimate sentence into a refused write.';

alter table public.ethics_patterns enable row level security;

drop policy if exists ethics_patterns_select_all on public.ethics_patterns;
-- Comme `ethics_rules` : la praticienne a le droit de lire la règle qu'elle a
-- enfreinte. Un refus dont on ne peut pas lire la raison est un mur.
create policy ethics_patterns_select_all on public.ethics_patterns
  for select to anon, authenticated using (true);
drop policy if exists ethics_patterns_write_denied on public.ethics_patterns;
create policy ethics_patterns_write_denied on public.ethics_patterns
  for all using (false) with check (false);

grant select on public.ethics_patterns to anon, authenticated;

-- >>> ETHICS PATTERN DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ TRADUITS UN À UN DEPUIS `lib/ethics/rules.ts`, pas réinventés. `\b` devient
-- `\y`, qui est la limite de mot de PostgreSQL ; le reste de la syntaxe est
-- commun. L'ordre est celui du fichier source, pour que les deux se relisent
-- en vis-à-vis.
insert into public.ethics_patterns (id, rule_id, pattern, exception_pattern, severity, sort_order) values
  ('resolution_verb', 'proven',
   '\y(heal|heals|healed|healing|cure|cures|cured|curing|fix|fixes|fixed|fixing|eliminate|eliminates|eliminated|eliminating|erase|erases|erasing|end|ends|ending|resolve|resolves|resolved|resolving|overcome|overcomes|overcoming|banish|banishes|banishing|remove|removes|removing|conquer|conquers|conquering|defeat|defeats)\y( +\w+){0,3} +\y(anxiety|anxieties|depression|trauma|traumas|ptsd|panic +attacks?|panic|ocd|grief|addiction|addictions|burnout|stress|insomnia|adhd|phobias?|shame|codependency|overwhelm)\y',
   null, 'block', 1),

  ('free_you_from', 'proven',
   '\y(free +you +from|rid +you +of|get +rid +of|take +away +your|make +(it|your +\w+) +go +away)\y',
   null, 'block', 2),

  ('is_gone', 'proven',
   '\y(anxiety|anxieties|depression|trauma|traumas|ptsd|panic +attacks?|panic|ocd|grief|addiction|addictions|burnout|stress|insomnia|adhd|phobias?|shame|codependency|overwhelm)\y[^.!?]{0,30}\y(is|are|will +be|''?ll +be) +(gone|behind +you|history|a +thing +of +the +past|no +longer +(a +problem|an +issue))\y',
   null, 'block', 3),

  ('dated_promise', 'timeframe',
   '\y(results?|relief|change|changes|healing|progress|improvement|breakthrough|transformation|better)\y[^.!?]{0,40}\yin +(as +little +as +|just +|only +)?[0-9]+ *(days?|weeks?|months?|sessions?)\y',
   null, 'block', 4),

  ('guarantee', 'proven', '\yguarantee(s|d|ing)?\y', null, 'block', 5),

  ('clinically_proven', 'proven',
   '\y(clinically|scientifically|medically|statistically) +proven\y|\yproven +(to\y|results?\y|method|approach|system|technique|protocol|track +record)',
   null, 'block', 6),

  ('success_rate', 'proven',
   '\y([0-9]{1,3} *(%|percent)|[0-9]+ +out +of +[0-9]+|nine +out +of +ten) +(of +)?(my|our|her|his|their)? *(clients?|patients?)\y|\ysuccess +rate\y',
   null, 'block', 7),

  ('lasting_relief', 'proven',
   '\y(lasting|permanent|life-?long|complete|full) +(relief|results?|recovery|healing|peace|calm|freedom)\y',
   null, 'block', 8),

  ('therapy_that_works', 'proven',
   '\y(treatment|therapy|approach|method) +that +(actually +|really +)?(works|will +work)\y',
   -- ⚠ L'EXCEPTION QUE POSTGRES NE SAIT PAS EXPRIMER EN LIGNE. « a therapy
   -- that works best for you » est une phrase correcte et fréquente.
   '\y(treatment|therapy|approach|method) +that +(actually +|really +)?(works|will +work) +(best +)?for +you\y',
   'block', 9),

  ('testimonial_word', 'client_voice', '\ytestimonials?\y', null, 'block', 10),

  ('clients_say', 'client_voice',
   '\y((my|our|her|his|their) +)?(clients?|patients?) +(often|frequently|sometimes|usually|always|regularly|routinely|consistently)? *(say|says|said|report|reports|reported|tell|tells|told|describe|describes|rave|love|feel|feels|felt)\y',
   null, 'block', 11),

  ('client_reviews', 'client_voice',
   '\yclient +(reviews?|feedback|ratings?)\y|\ypatient +reviews?\y|\y(reviewed|rated|recommended) +by +(my|our|former|past|hundreds +of|[0-9]+) *(clients?|patients?)\y',
   null, 'block', 12),

  ('star_rating', 'client_voice',
   '\yfive[- ]star\y|\y[0-9](\.[0-9])? *(/ *5|out +of +5) *stars?\y|[★⭐]',
   null, 'block', 13),

  ('success_story', 'client_voice',
   '\y(success|client|patient) +stor(y|ies)\y', null, 'block', 14),

  ('best_therapist', 'scarcity',
   '(\y(best|top|leading|premier|foremost|most +trusted|top-?rated|number +one)|# *1) +(\w+ +){0,2}(therapist|therapists|counselor|counselors|counsellor|psychologist|psychologists|clinician|clinicians|clinic|provider|providers|coach|therapy)\y',
   null, 'block', 15),

  ('award_winning', 'credential',
   '\y(award-?winning|nationally +recognized|world-?class|world-?renowned|renowned)\y',
   null, 'warn', 16),

  ('weekend_certification', 'credential',
   '\y(weekend|two-?day|one-?day|[0-9]+-?(day|hour)) +(certification|certificate|certified|intensive)\y|\ycertified\y[^.!?]{0,40}\y(weekend|workshop|webinar|ce +course|short +course)\y',
   null, 'block', 17),

  ('you_have_condition', 'diagnosis',
   '\yyou +(have|clearly +have|probably +have|likely +have|are +suffering +from|suffer +from) +(\w+ +){0,2}\y(anxiety|anxieties|depression|trauma|traumas|ptsd|panic +attacks?|panic|ocd|grief|addiction|addictions|burnout|stress|insomnia|adhd|phobias?|shame|codependency|overwhelm)\y',
   null, 'block', 18),

  -- ⚠ `limited spots` MANQUAIT DES DEUX CÔTÉS, et c'est ce fichier qui l'a
  -- trouvé. `ethics_rules.scarcity.example_forbidden` vaut « Limited spots
  -- available. » — l'exemple que le produit MONTRE à la praticienne pour lui
  -- dire ce qui est interdit — et ni le motif TypeScript ni sa traduction ne
  -- l'attrapaient : les deux exigeaient « only N spots left » ou « limited-TIME
  -- offer ». Le produit affichait une règle qu'il ne faisait pas respecter.
  -- Corrigé ici ET dans `lib/ethics/rules.ts`, ensemble.
  ('scarcity_urgency', 'scarcity',
   '\yonly +[0-9]+ +(spots?|slots?|places?|openings?) +(left|remaining|available)\y|\ylimited +(spots?|slots?|places?|openings?|availability|space)\y|\y(spots?|slots?|places?|openings?) +(are +)?(limited|filling +up)\y|\ylimited[- ]time +offer\y|\yact +now\y|\ydon''?t +wait\y|\ylast +chance\y|\ybook +(now +)?before +(prices|rates|spots)\y',
   null, 'block', 19)
on conflict (id) do update set
  rule_id = excluded.rule_id, pattern = excluded.pattern,
  exception_pattern = excluded.exception_pattern,
  severity = excluded.severity, sort_order = excluded.sort_order;

-- <<< ETHICS PATTERN DATA <<<

-- ── 2. Le scan ──────────────────────────────────────────────────────────────

/*
 * ⚠ PAS `SECURITY DEFINER`, ET C'EST L'ÉNUMÉRATION QUI L'A EXIGÉ. Elle a
 * rougi : « SECURITY DEFINER functions callable by anon/PUBLIC with no in-body
 * authority check ».
 *
 * La bonne réponse n'était pas d'ajouter un contrôle d'autorité, c'était de
 * retirer l'élévation : cette fonction n'en a aucun besoin. Elle lit
 * `ethics_patterns`, dont la policy de lecture est ouverte à tout le monde —
 * volontairement, parce qu'une praticienne a le droit de lire la règle qu'elle
 * a enfreinte — et elle ne touche à rien d'autre. Elle ne regarde qu'un texte
 * que l'appelante vient de lui donner.
 *
 * Une élévation dont on n'a pas besoin est une élévation qu'on finira par
 * exploiter.
 */
create or replace function public.ethics_scan(p_text text)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'rule_id',  ep.rule_id,
      'severity', ep.severity,
      /*
       * L'extrait fautif, cité. `lib/ethics/guard.ts` a établi pourquoi :
       * « évite les promesses » ne fait rien atterrir, l'extrait si.
       *
       * ⚠ `(?i)` EN TÊTE, ET SON ABSENCE A ÉTÉ TROUVÉE PAR L'AUTO-CONTRÔLE
       * DE CE FICHIER, À LA PREMIÈRE EXÉCUTION. `~*` est insensible à la
       * casse ; `substring(… from …)` ne l'est PAS. Sur « Heal your anxiety
       * in 12 weeks », le WHERE trouvait la violation et `substring` rendait
       * NULL — parce que « Heal » avec une majuscule ne correspond pas à
       * `heal`. La violation était détectée et son extrait disparaissait.
       *
       * C'est littéralement le défaut que le README de ce dépôt appelle
       * « une valeur qui disparaît sans erreur », écrit par moi, dans le lot
       * dont c'est le sujet.
       *
       * ⚠ ET LE MOTIF EST ENTOURÉ D'UNE PARENTHÈSE, pour la même famille de
       * raison. `substring(chaîne from motif)` rend le PREMIER GROUPE DE
       * CAPTURE quand le motif en contient un. Sur `\yguarantee(s|d|ing)?\y`,
       * le groupe 1 est `(s|d|ing)?` : l'extrait montré à la praticienne était
       * « d ». Envelopper le motif entier fait du groupe 1 la correspondance
       * complète. Trouvé par le test qui exige que l'extrait cite les mots
       * fautifs — sans lui, la garde refusait correctement en citant une
       * lettre.
       */
      'excerpt',  coalesce(substring(p_text from '(?i)(' || ep.pattern || ')'), '(match)')
    ) order by ep.sort_order),
    '[]'::jsonb)
    from public.ethics_patterns ep
   where ep.active
     and p_text is not null
     and p_text ~* ep.pattern
     -- ⚠ L'EXCEPTION, quand il y en a une. `coalesce` sur le test lui-même :
     -- `not (x ~* null)` vaut NULL, et un WHERE qui rend NULL écarte la ligne
     -- — ici ça aurait laissé passer le motif au lieu de le signaler.
     and not coalesce(p_text ~* ep.exception_pattern, false)
$$;

comment on function public.ethics_scan(text) is
  'The deterministic advertising-ethics scan, in the database, so that text written straight through a RPC is covered too. Returns every match with its rule and the offending excerpt. Does NOT rewrite: enforceEthics in the application asks the model to fix the field, a write constraint can only refuse - which is the right split, since the practitioner corrects her own words herself.';

revoke all on function public.ethics_scan(text) from public;
grant execute on function public.ethics_scan(text) to anon, authenticated, service_role;

create or replace function public.ethics_blocks(p_text text)
returns text
language sql
stable
set search_path to ''
as $$
  /*
   * ⚠ LA NULLITÉ DE L'EXTRAIT NE VEUT PAS DIRE « pas de violation », et
   * c'est ce qui a fait passer la première version. Cette fonction rendait
   * `v ->> 'excerpt'` tel quel : un extrait nul se lisait comme un texte
   * propre, et le trigger laissait passer une promesse de résultat.
   *
   * La violation est décidée par `severity`, qui est NOT NULL. L'extrait est
   * une CITATION, et une citation manquante ne doit jamais valoir un
   * acquittement — d'où le `coalesce` sur le libellé de la règle, qui dit au
   * moins laquelle est tombée.
   */
  select coalesce(nullif(v ->> 'excerpt', ''), v ->> 'rule_id', 'blocked')
    from jsonb_array_elements(public.ethics_scan(p_text)) as e(v)
   where v ->> 'severity' = 'block'
   limit 1
$$;

comment on function public.ethics_blocks(text) is
  'The first blocking excerpt in a piece of text, or NULL. Separate from ethics_scan so a trigger reads one value: a WARN is logged by the application, a BLOCK refuses a write.';

revoke all on function public.ethics_blocks(text) from public;
grant execute on function public.ethics_blocks(text) to anon, authenticated, service_role;

-- ── 3. Le scan entre dans l'écriture ────────────────────────────────────────

create or replace function public.site_specs_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block text;
  v_text  text;
begin
  /*
   * ⚠ TOUTE LA COPY, pas seulement les pages. `site_spec_copy_blocks` rend les
   * champs de section ; `about_excerpt` et le hero vivent à côté, et
   * `extra_instructions` part telle quelle dans le prompt du constructeur.
   *
   * ⚠ ET CHAQUE MORCEAU EST SCANNÉ SÉPARÉMENT, pas concaténé. Coller deux
   * champs bout à bout fabrique des motifs qui n'existent dans aucun des deux
   * — la fin de l'un plus le début de l'autre — et c'est un faux positif dont
   * personne ne comprendrait la cause.
   */
  /*
   * ⚠ ON PARCOURT `pages` DIRECTEMENT, PAS `site_spec_copy_blocks`. Cette
   * dernière rend un TABLEAU (vérifié, pas supposé : `jsonb_typeof` dit
   * `array`), et la première version l'a passée à `jsonb_each_text`, qui a
   * levé « cannot call jsonb_each_text on a non-object » — dans un TRIGGER,
   * c'est-à-dire en refusant toute écriture de spec, y compris les propres.
   *
   * Parcourir la structure ici la rend indépendante de la forme de sortie
   * d'une fonction de rendu, qui peut changer sans que ce garde le sache.
   * Les feuilles de `fields` sont soit des chaînes, soit des listes de
   * chaînes ; les deux sont scannées.
   *
   * ⚠ ET CHAQUE MORCEAU EST SCANNÉ SÉPARÉMENT, jamais concaténé. Coller deux
   * champs bout à bout fabrique des motifs qui n'existent dans aucun des deux
   * — la fin de l'un plus le début de l'autre — et c'est un faux positif dont
   * personne ne comprendrait la cause.
   */
  for v_text in
    select expanded.leaf #>> '{}'
      from jsonb_array_elements(coalesce(new.pages, '[]'::jsonb))          as page,
           jsonb_array_elements(coalesce(page.value -> 'sections', '[]'::jsonb)) as section,
           jsonb_each(coalesce(section.value -> 'fields', '{}'::jsonb))    as field(fkey, fvalue),
           -- ⚠ PAS DE `case` AUTOUR D'UNE FONCTION À ENSEMBLE : PostgreSQL le
           -- refuse (« set-returning functions are not allowed in CASE »).
           -- Un champ est soit une chaîne, soit une liste de chaînes ; on
           -- enveloppe donc la chaîne dans un tableau d'un élément et on
           -- déplie une seule forme.
           jsonb_array_elements(
             case when jsonb_typeof(field.fvalue) = 'array'
                  then field.fvalue
                  else jsonb_build_array(field.fvalue)
             end
           ) as expanded(leaf)
     where jsonb_typeof(expanded.leaf) = 'string'
    union all
    select value from jsonb_each_text(coalesce(new.hero, '{}'::jsonb))
    union all
    select new.about_excerpt
    union all
    select new.extra_instructions
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception
        'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;
  end loop;

  return new;
end
$$;

revoke all on function public.site_specs_ethics_gate() from public, anon, authenticated;

drop trigger if exists site_specs_ethics_gate on public.site_specs;
create trigger site_specs_ethics_gate
  before insert or update on public.site_specs
  for each row execute function public.site_specs_ethics_gate();

create or replace function public.content_items_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block text;
  v_text  text;
begin
  foreach v_text in array array[new.title, new.caption, new.on_image_text, new.alt_text]
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception
        'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;
  end loop;

  return new;
end
$$;

revoke all on function public.content_items_ethics_gate() from public, anon, authenticated;

drop trigger if exists content_items_ethics_gate on public.content_items;
create trigger content_items_ethics_gate
  before insert or update on public.content_items
  for each row execute function public.content_items_ethics_gate();

-- ── 4. Les sorties d'annuaire passent aussi par les trente clichés ──────────
--
-- ⚠ `banned_phrases` A ÉTÉ ÉCRITE POUR PSYCHOLOGY TODAY. Vingt de ses trente
-- entrées sont catégorisées `directory_cliche` — « safe space »,
-- « judgment-free », « meet you where you are ». Elles ne servaient jusqu'ici
-- QUE la phrase de positionnement. Un profil d'annuaire est précisément le
-- texte pour lequel elles ont été rassemblées.

create or replace function public.directory_profiles_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block text;
  v_cliches text[];
  v_text  text;
begin
  foreach v_text in array array[new.first_paragraph, new.body]
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception 'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;

    v_cliches := public.usp_banned_phrases_check(v_text);
    if coalesce(array_length(v_cliches, 1), 0) > 0 then
      raise exception
        'Directory cliche: %', array_to_string(v_cliches, ', ')
        using errcode = 'check_violation',
              hint = 'Every profile in the state says this. Say what she actually does instead.';
    end if;
  end loop;

  return new;
end
$$;

revoke all on function public.directory_profiles_ethics_gate() from public, anon, authenticated;

drop trigger if exists directory_profiles_ethics_gate on public.directory_profiles;
create trigger directory_profiles_ethics_gate
  before insert or update on public.directory_profiles
  for each row execute function public.directory_profiles_ethics_gate();

-- ── 5. `anon` n'écrit pas ───────────────────────────────────────────────────
--
-- ⚠ CE N'EST PAS UNE PRÉCAUTION, C'EST UNE RÉVOCATION. GAP_AUDIT.md §H.2 les a
-- énumérées : quatre RPC exécutables par `anon`, dont trois en écriture. Toute
-- fonction naît avec EXECUTE accordé à PUBLIC — quatrième défaut permissif du
-- README — et `20260902090000_revoke_internal_function_surface.sql` ne
-- couvrait pas celles-ci.
--
-- Les corps vérifient l'accès, donc l'effet pratique était probablement nul.
-- Mais des RPC d'ÉCRITURE étaient dans la surface OpenAPI anonyme, et ce dépôt
-- a déjà payé ce motif une fois.

-- ⚠ `from public, anon`, ET PAS `from anon` SEUL. C'est le défaut lui-même :
-- toute fonction naît avec EXECUTE accordé à PUBLIC, et `anon` est membre de
-- PUBLIC. Révoquer sur `anon` seul retire un droit qu'il n'avait pas
-- nommément et lui laisse celui qu'il tenait de PUBLIC — la révocation réussit,
-- ne change rien, et on croit avoir fermé la porte.
--
-- L'auto-contrôle en bas de ce fichier l'a montré à la première exécution :
-- « une RPC d'écriture est encore atteignable par anon », après cinq REVOKE
-- qui avaient tous réussi.
--
-- Et les droits légitimes sont RE-ACCORDÉS nommément juste après : retirer à
-- PUBLIC retire aussi à `authenticated` et à `service_role` quand ils n'ont
-- pas de grant explicite.
revoke execute on function public.create_content_item(uuid, text, date) from public, anon;
revoke execute on function public.update_content_item(uuid, jsonb)      from public, anon;
revoke execute on function public.delete_content_item(uuid)             from public, anon;
revoke execute on function public.site_spec_patch(uuid, jsonb)          from public, anon;
revoke execute on function public.get_publishing_log(uuid, integer)     from public, anon;

grant execute on function public.create_content_item(uuid, text, date) to authenticated, service_role;
grant execute on function public.update_content_item(uuid, jsonb)      to authenticated, service_role;
grant execute on function public.delete_content_item(uuid)             to authenticated, service_role;
grant execute on function public.site_spec_patch(uuid, jsonb)          to authenticated, service_role;
grant execute on function public.get_publishing_log(uuid, integer)     to authenticated, service_role;

-- ── Auto-contrôle ──────────────────────────────────────────────────────────

do $$
declare
  v_rule    record;
  v_user    uuid := gen_random_uuid();
  v_org     uuid;
  v_proj    uuid := gen_random_uuid();
  v_kit     uuid := gen_random_uuid();
  v_broke   boolean;
  v_rows    integer;
begin
  -- ⚠ LE CORPUS PARTAGÉ. Chacune des six règles porte, dans `ethics_rules`,
  -- l'exemple de ce qu'elle interdit. Le scanner SQL doit bloquer les six —
  -- et le scanner TypeScript aussi, ce que `lib/ethics/__tests__/` épingle
  -- sur les mêmes phrases. C'est ce qui tient les deux implémentations
  -- ensemble tant qu'elles n'ont pas fusionné.
  for v_rule in select id, example_forbidden from public.ethics_rules where active loop
    if public.ethics_blocks(v_rule.example_forbidden) is null then
      raise exception
        'le scan SQL ne bloque pas l''exemple de la règle "%": %',
        v_rule.id, v_rule.example_forbidden;
    end if;
  end loop;

  -- L'exception de `therapy_that_works` est parcourue dans les deux sens.
  if public.ethics_blocks('A method that works, every time.') is null then
    raise exception 'le motif "that works" ne bloque plus rien';
  end if;
  if public.ethics_blocks('We will find an approach that works best for you.') is not null then
    raise exception
      'l''exception de "that works" est perdue : une phrase correcte est refusée';
  end if;

  -- Une phrase ordinaire passe. Sans ça, la garde prouverait un refus universel.
  if public.ethics_blocks(
       'A space to look at the patterns that keep repeating, at your own pace.') is not null then
    raise exception 'une phrase correcte est bloquée';
  end if;
  if public.ethics_blocks(null) is not null then
    raise exception 'un texte nul est traité comme une violation';
  end if;

  -- ── LE CRITÈRE D'ACCEPTATION, PARCOURU ────────────────────────────────
  insert into auth.users (id, email) values (v_user, 'guard@example.invalid');
  select m.organization_id into v_org from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Guard');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  /*
   * ⚠ LA SPEC EST ÉCRITE À LA MAIN, PAS SEMÉE. La première version de cette
   * sonde appelait `seed_site_spec(v_kit)` — qui rend 0 sur un kit sans
   * direction choisie. L'UPDATE qui suivait touchait alors ZÉRO ligne, aucun
   * trigger ne se déclenchait, et la sonde concluait « la promesse est
   * passée » sur une écriture qui n'avait jamais eu lieu.
   *
   * C'est mot pour mot le défaut de `20260910144421` que ce chantier cite
   * depuis le premier lot : un garde-fou qui dépend de données de seed asserte
   * le seed, pas la contrainte. Il m'a eu aussi, et c'est la sonde elle-même
   * qui l'a montré — en échouant d'abord.
   */
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, heading_font, body_font,
     google_fonts_url, hero, pages, paper_hex, primary_text_hex,
     secondary_text_hex, accent_text_hex, cta_ink_hex)
  values
    (v_kit, v_user, '#3B2C3A', '#4A5361', '#7A6A55', '#F3EDE4', '#241B23',
     'Cormorant Garamond', 'Source Sans 3',
     'https://fonts.googleapis.com/css2?family=Cormorant+Garamond&display=swap',
     jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
     public.site_spec_default_pages(array[]::text[], array[]::text[]),
     '#FAF7F2', '#3B2C3A', '#4A5361', '#7A6A55', '#FFFFFF');

  begin
    update public.site_specs
       set about_excerpt = 'A clinically proven method that resolves trauma for good.'
     where brand_kit_id = v_kit;
    -- ⚠ ET ON EXIGE QUE L'ÉCRITURE AIT EU LIEU. Sans cette ligne, zéro ligne
    -- touchée se lit comme un succès, ce qui est exactement le piège du
    -- dessus.
    get diagnostics v_rows = row_count;
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception
      'une promesse de résultat a pu être écrite dans une spec de site (% ligne(s) touchée(s))',
      v_rows;
  end if;

  -- Et la même écriture, correcte, passe — et touche bien une ligne.
  update public.site_specs
     set about_excerpt = 'A space to look at what keeps repeating, at your own pace.'
   where brand_kit_id = v_kit;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'la sonde n''a pas de spec à écrire : elle ne prouve rien';
  end if;

  -- Un item de contenu, même chose.
  begin
    insert into public.content_items (brand_kit_id, archetype, caption)
    values (v_kit, 'google_post', 'Guaranteed relief in 6 weeks.');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'une garantie a pu être écrite dans une légende';
  end if;

  -- Un profil d'annuaire : la déontologie ET les clichés.
  begin
    perform public.save_directory_profile(
      v_kit, 'psychology_today', 'A safe space where you can be yourself.', 'body',
      '{}'::jsonb, null);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un cliché d''annuaire a pu entrer dans un profil rédigé';
  end if;

  perform public.save_directory_profile(
    v_kit, 'psychology_today',
    'For people whose bodies keep score long after the thing itself is over.',
    'The rest of it, written plainly.', '{}'::jsonb, null);

  -- Et `anon` n'écrit plus.
  if has_function_privilege('anon', 'public.site_spec_patch(uuid, jsonb)', 'EXECUTE')
  or has_function_privilege('anon', 'public.update_content_item(uuid, jsonb)', 'EXECUTE')
  or has_function_privilege('anon', 'public.create_content_item(uuid, text, date)', 'EXECUTE')
  or has_function_privilege('anon', 'public.delete_content_item(uuid)', 'EXECUTE')
  or has_function_privilege('anon', 'public.get_publishing_log(uuid, integer)', 'EXECUTE') then
    raise exception 'une RPC d''écriture est encore atteignable par anon';
  end if;

  -- ⚠ ET LES APPELANTES LÉGITIMES ONT GARDÉ LE LEUR. Révoquer sur PUBLIC
  -- retire à tout le monde ; sans ce contrôle, on fermerait la porte à
  -- l'utilisatrice connectée en croyant ne la fermer qu'à l'anonyme, et le
  -- produit tomberait pour tout le monde sauf pour celles qu'on visait.
  if not has_function_privilege('authenticated', 'public.site_spec_patch(uuid, jsonb)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.update_content_item(uuid, jsonb)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.create_content_item(uuid, text, date)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.delete_content_item(uuid)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.get_publishing_log(uuid, integer)', 'EXECUTE') then
    raise exception
      'la révocation sur PUBLIC a emporté le droit de l''utilisatrice connectée';
  end if;

  delete from public.projects where id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;
