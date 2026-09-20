-- ============================================================================
-- Eklio — un label de diagramme est du texte publié, comme la caption
-- ============================================================================
-- ⚠ LE TROU QUE `DIAGNOSTIC.md` §3.2 A MESURÉ, ET IL EST RÉEL.
--
-- `20260914084054_the_guard_moves_into_the_write` a posé la garde
-- déontologique DANS l'écriture, par trigger, sur `site_specs`,
-- `content_items` et `directory_profiles`. Son commentaire de table dit
-- pourquoi : « a scan that runs only in the application does not cover text
-- written straight through a RPC ».
--
-- Le chantier Content introduit une quatrième surface de texte publié —
-- `content_topics.payload`, qui porte les labels et les gloses imprimés DANS
-- le diagramme — et aucun de ces trois triggers ne la couvre. Un label
-- « Guaranteed relief » écrit dans un payload atteindrait le rendu, le PNG,
-- et le feed d'une praticienne sans passer sous aucune garde.
--
-- Ce n'est pas hypothétique au sens où il faudrait imaginer un chemin : le
-- pipeline de rédaction écrit ces payloads, et c'est un modèle qui les écrit.
--
-- ── POURQUOI LE PAYLOAD DEMANDE UNE FONCTION ────────────────────────────
--
-- `ethics_blocks(text)` prend du texte. Un payload est un objet dont la forme
-- dépend de l'archétype : `statement` ici, `items[].label` là, `cards[].
-- payload.nodes[].gloss` deux niveaux plus bas. Écrire onze extractions, une
-- par archétype, donnerait onze occasions d'en oublier une — et celle qu'on
-- oublie est exactement celle qui passe.
--
-- `content_topic_text` aplatit donc TOUTE chaîne de caractères du jsonb,
-- récursivement, sans rien savoir des archétypes. Un douzième archétype ajouté
-- demain est couvert le jour où il est ajouté, sans que personne y pense.
-- ============================================================================


-- ============================================================================
-- 1. content_topic_text — toute chaîne du payload, aplatie
-- ============================================================================
create or replace function public.content_topic_text(p jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  -- ⚠ RÉCURSIF ET AVEUGLE À LA FORME. Il ne connaît ni les onze archétypes ni
  -- leurs clefs : il descend dans tout objet et tout tableau, et rend chaque
  -- feuille de type `string`. Une extraction par archétype serait onze
  -- occasions d'en oublier une, et celle qu'on oublie est celle qui passe.
  with recursive leaves(value) as (
    select coalesce(p, 'null'::jsonb)
    union all
    select child.value
      from leaves l
     cross join lateral (
       /*
        * ⚠ LE `case` EST DANS L'ARGUMENT, PAS DANS UN `where`.
        *
        * `jsonb_each` sur un tableau LÈVE, et `jsonb_array_elements` sur un
        * objet aussi. Une fonction qui rend un ensemble est évaluée AVANT le
        * filtre qui devait l'éviter — la première version l'apprenait à
        * l'exécution, avec « cannot extract elements from an object ».
        *
        * Passer un objet vide ou un tableau vide à la branche qui ne
        * s'applique pas rend l'appel toujours légal et l'ensemble vide.
        */
       select value from jsonb_each(
                case when jsonb_typeof(l.value) = 'object' then l.value else '{}'::jsonb end)
       union all
       select value from jsonb_array_elements(
                case when jsonb_typeof(l.value) = 'array' then l.value else '[]'::jsonb end)
     ) as child(value)
  )
  select coalesce(string_agg(value #>> '{}', E'\n'), '')
    from leaves
   where jsonb_typeof(value) = 'string'
$$;

comment on function public.content_topic_text(jsonb) is
  'Every string leaf of a topic payload, newline-joined, for the ethics scanners. Recursive and shape-blind on purpose: it knows nothing about the eleven archetypes, so a twelfth is covered the day it is added rather than the day somebody remembers to extend this.';

revoke all on function public.content_topic_text(jsonb) from public, anon;
grant execute on function public.content_topic_text(jsonb) to authenticated, service_role;


-- ============================================================================
-- 2. Le trigger — la même forme que les trois autres
-- ============================================================================
create or replace function public.content_topics_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_block text;
  v_text  text;
begin
  -- ⚠ `ethics_blocks` REND LE PASSAGE FAUTIF, PAS UN BOOLÉEN. Lu comme un
  -- booléen il lève « invalid input syntax for type boolean: "Heal your
  -- anxiety" » — ce qui refuse bien la ligne, mais pour la mauvaise raison et
  -- avec un message que personne ne peut agir. La forme ci-dessous est celle
  -- de `content_items_ethics_gate`, reprise telle quelle.
  --
  -- ⚠ ET LE PAYLOAD EST SCANNÉ AUTANT QUE LA CAPTION. Le titre et le hook sont
  -- internes, mais ils nourrissent la rédaction : une promesse de résultat
  -- dans un titre finit dans la caption qu'on en tire.
  foreach v_text in array array[
    new.title,
    new.hook,
    new.caption_seed,
    new.rationale_template,
    public.content_topic_text(new.payload)
  ]
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception 'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;
  end loop;

  return new;
end
$$;

comment on function public.content_topics_ethics_gate() is
  'The fourth published-text surface, joining site_specs, content_items and directory_profiles. Scans the caption seed AND every string inside the payload -- a diagram label is published text in exactly the way a caption is, and until this trigger nothing checked one.';

revoke all on function public.content_topics_ethics_gate() from public, anon, authenticated;

drop trigger if exists content_topics_ethics_gate on public.content_topics;
create trigger content_topics_ethics_gate
  before insert or update on public.content_topics
  for each row execute function public.content_topics_ethics_gate();


-- ============================================================================
-- 3. banned_phrases sur la même surface
-- ============================================================================
-- `ethics_blocks` couvre les motifs déontologiques (`ethics_patterns`). Les
-- trente-deux formulations littérales de `banned_phrases` sont une AUTRE
-- liste, et `usp_banned_phrases_check` est l'oracle qui la lit sans la fuiter.
--
-- ⚠ ON NE RECOPIE PAS LA LISTE. Elle a bougé deux fois cette semaine
-- (DIAGNOSTIC.md §0.1), et une copie TypeScript en aurait trente là où la
-- production en a trente-deux.

create or replace function public.content_topics_banned_phrases_gate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_text text;
  v_hits text[];
begin
  v_text := concat_ws(E'\n',
    new.caption_seed,
    public.content_topic_text(new.payload)
  );

  -- ⚠ L'ORACLE REND UN `text[]` DES PHRASES TROUVÉES. Il ne rend pas la liste
  -- complète, et c'est pour ça qu'il existe : `banned_phrases` est
  -- service_role only précisément pour que la liste ne fuite jamais.
  v_hits := public.usp_banned_phrases_check(v_text);

  if coalesce(array_length(v_hits, 1), 0) > 0 then
    raise exception 'Banned phrasing: %', v_hits[1]
      using errcode = 'check_violation',
            hint = 'That formulation is on the banned list. Say what the work is instead.';
  end if;

  return new;
end
$$;

comment on function public.content_topics_banned_phrases_gate() is
  'The thirty-odd literal formulations, checked on the caption seed and on every diagram label. Calls usp_banned_phrases_check rather than reading banned_phrases: the table is service_role only precisely so the list is never copied, and it gained two entries this week.';

revoke all on function public.content_topics_banned_phrases_gate() from public, anon, authenticated;

drop trigger if exists content_topics_banned_phrases_gate on public.content_topics;
create trigger content_topics_banned_phrases_gate
  before insert or update on public.content_topics
  for each row execute function public.content_topics_banned_phrases_gate();


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_seg  uuid;
  v_mod  text;
  v_per  text;
  v_rule record;
  v_n    integer;
begin
  -- ---- l'aplatissement voit tout, y compris deux niveaux plus bas ---------
  if public.content_topic_text('{"a":"one","b":{"c":"two"},"d":[{"e":"three"}]}'::jsonb)
     not like '%one%' then
    raise exception 'content_topic_text a perdu une chaîne de premier niveau.';
  end if;
  if public.content_topic_text('{"a":"one","b":{"c":"two"},"d":[{"e":"three"}]}'::jsonb)
     not like '%two%' then
    raise exception 'content_topic_text a perdu une chaîne imbriquée.';
  end if;
  if public.content_topic_text('{"a":"one","b":{"c":"two"},"d":[{"e":"three"}]}'::jsonb)
     not like '%three%' then
    raise exception 'content_topic_text a perdu une chaîne dans un tableau d''objets.';
  end if;
  -- Un carrousel imbrique un payload dans un payload. C'est le cas le plus
  -- profond que le schéma autorise, et c'est celui qu'une extraction écrite à
  -- la main oublie.
  if public.content_topic_text(
       '{"cards":[{"archetype_key":"cycle","payload":{"nodes":[{"label":"deep","gloss":"g"}]}}]}'::jsonb
     ) not like '%deep%' then
    raise exception 'content_topic_text ne descend pas dans un carrousel.';
  end if;
  if public.content_topic_text(null) <> '' then
    raise exception 'content_topic_text(null) ne rend pas une chaîne vide.';
  end if;

  -- ---- ⚠ LA GARDE MORD SUR UN LABEL, PAS SEULEMENT SUR UNE CAPTION -------
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;
  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;

  -- Chacune des six règles porte, dans `ethics_rules`, l'exemple de ce qu'elle
  -- interdit. On les pose une à une DANS UN LABEL — la surface qui n'était
  -- gardée par rien.
  for v_rule in
    select example_forbidden from public.ethics_rules
     where active and example_forbidden is not null
  loop
    begin
      insert into public.content_topics
        (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
         rationale_template)
      values (v_seg, 'single_statement', 'educate', 'A title', 'A hook',
              jsonb_build_object('statement', v_rule.example_forbidden),
              'A caption', 'Because.');
      raise exception 'la garde déontologique a laissé passer « % » dans un payload.',
        left(v_rule.example_forbidden, 60);
    exception when check_violation then null;
    end;
  end loop;

  -- ---- et elle laisse passer ce qui est acceptable ------------------------
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template)
  values (v_seg, 'single_statement', 'normalise', 'Rest is not earned', 'A hook',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'Rest is not a reward.', 'Because it keeps coming up.');

  select count(*) into v_n from public.content_topics where segment_id = v_seg;
  if v_n <> 1 then
    raise exception 'un sujet acceptable a été refusé (% écrits)', v_n;
  end if;

  -- ---- teardown ----------------------------------------------------------
  delete from public.content_segments where id = v_seg;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger  if exists content_topics_banned_phrases_gate on public.content_topics;
--   drop function if exists public.content_topics_banned_phrases_gate();
--   drop trigger  if exists content_topics_ethics_gate on public.content_topics;
--   drop function if exists public.content_topics_ethics_gate();
--   drop function if exists public.content_topic_text(jsonb);
