-- ============================================================================
-- Eklio — un post sait de quel sujet il vient, et pourquoi celui-là
-- ============================================================================
-- L'écran de contenu doit porter deux choses que la base ne sait pas encore
-- dire : le LIBELLÉ D'ANGLE sous la vignette (« Myth, gently corrected »,
-- « Behind the practice ») et la ligne de justification (« Why this one: … »).
--
-- ⚠ LES DEUX VIENNENT DU SUJET, ET ELLES NE SONT PAS LA MÊME CHOSE.
--
-- L'angle est une propriété du SUJET, partagée par toutes les praticiennes à
-- qui il est servi : `content_topics.intent`. La justification est une
-- propriété de l'ITEM, parce qu'elle cite son brief à elle —
-- `rationale_template` porte des substitutions, et ce qui est rendu n'est vrai
-- que pour une personne. Les mettre au même endroit voudrait dire que l'un des
-- deux ment.
--
-- ── POURQUOI UN CATALOGUE D'INTENTIONS ET PAS UNE TRADUCTION EN TYPESCRIPT ─
--
-- Parce que le libellé est lu à un seul endroit — l'écran — et décidé à un
-- autre — la banque. Une table de correspondance `intent → phrase` côté client
-- serait une seconde source : le jour où une sixième intention est générée, le
-- sujet existe, il est servi, et sa vignette n'a pas de libellé. Un catalogue
-- avec une clef étrangère fait échouer l'écriture du sujet, ce qui est le bon
-- moment pour l'apprendre.
-- ============================================================================


-- ============================================================================
-- 1. content_intents — les cinq angles, avec leurs mots
-- ============================================================================
create table if not exists public.content_intents (
  id         text     primary key,
  -- La phrase que la praticienne lit sous sa vignette. Pas un nom technique.
  label      text     not null,
  sort_order smallint not null,

  constraint content_intents_label_check check (char_length(label) between 1 and 40)
);

comment on table public.content_intents is
  'The five editorial angles a topic can take, with the words the practitioner reads under her thumbnail. A catalogue rather than a TypeScript lookup: the label is read on one screen and decided in the topic bank, and a second copy would mean a sixth angle ships with a blank label instead of failing at the write.';

insert into public.content_intents (id, label, sort_order) values
  ('correct_a_myth',      'Myth, gently corrected', 1),
  ('behind_the_practice', 'Behind the practice',    2),
  ('invite',              'A soft invitation',      3),
  ('normalise',           'You are not the only one', 4),
  ('educate',             'How the work works',     5)
on conflict (id) do update
  set label = excluded.label, sort_order = excluded.sort_order;

alter table public.content_intents enable row level security;

drop policy if exists "content_intents_select_all"    on public.content_intents;
drop policy if exists "content_intents_insert_denied" on public.content_intents;
drop policy if exists "content_intents_update_denied" on public.content_intents;
drop policy if exists "content_intents_delete_denied" on public.content_intents;

create policy "content_intents_select_all" on public.content_intents
  for select to authenticated using (true);
create policy "content_intents_insert_denied" on public.content_intents
  for insert with check (false);
create policy "content_intents_update_denied" on public.content_intents
  for update using (false);
create policy "content_intents_delete_denied" on public.content_intents
  for delete using (false);


-- ============================================================================
-- 2. content_topics.intent devient une clef étrangère
-- ============================================================================
-- ⚠ LE CHECK EST REMPLACÉ, PAS DOUBLÉ. Garder les deux donnerait deux listes
-- de cinq chaînes à tenir d'accord — exactement la dérive que
-- `content_registers` et `content_archetypes` sont des tables pour éviter.
alter table public.content_topics drop constraint if exists content_topics_intent_check;
alter table public.content_topics
  drop constraint if exists content_topics_intent_fkey;
alter table public.content_topics
  add constraint content_topics_intent_fkey
  foreign key (intent) references public.content_intents (id);


-- ============================================================================
-- 3. content_items gagne son sujet et sa justification
-- ============================================================================
alter table public.content_items
  add column if not exists topic_id uuid references public.content_topics (id) on delete set null;

alter table public.content_items
  add column if not exists rationale text;

alter table public.content_items drop constraint if exists content_items_rationale_check;
alter table public.content_items
  add constraint content_items_rationale_check
  check (rationale is null or char_length(rationale) <= 200);

comment on column public.content_items.topic_id is
  'The bank topic this post came from. ON DELETE SET NULL: retiring a topic must not delete posts already written from it, and a post that outlives its topic simply stops showing an angle.';
comment on column public.content_items.rationale is
  'The rendered "Why this one: ..." line. Rendered rather than templated because it cites HER brief -- content_topics.rationale_template carries the substitutions, and what comes out is only true for one person.';

create index if not exists content_items_topic_idx
  on public.content_items (topic_id)
  where topic_id is not null;


-- ============================================================================
-- 4. content_item_json porte les deux
-- ============================================================================
-- ⚠ ÉTENDRE `content_item_json` SUFFIT. `get_content_month` l'appelle pour
-- chaque ligne, et `get_content_item` aussi : les deux écrans gagnent l'angle
-- et la justification en même temps, sans qu'aucune des deux fonctions change.
-- C'est pour ça que cette forme existe.

create or replace function public.content_item_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select jsonb_build_object(
    'id',            ci.id,
    'brand_kit_id',  ci.brand_kit_id,
    'archetype',     ci.archetype,
    'register',      ci.register,
    'month_id',      ci.month_id,
    -- ⚠ `theme` A ÉTÉ PERDU UNE FOIS EN ÉCRIVANT CETTE FONCTION, parce que le
    -- corps a été repris de `20260910100758` alors que `20260910102753` l'avait
    -- ajouté ensuite. `create or replace` remplace le corps EN ENTIER : une
    -- clef oubliée disparaît de tous les écrans en silence. Le garde-fou en
    -- bas de ce fichier vérifie désormais le jeu de clefs, plutôt que de faire
    -- confiance à la relecture.
    'theme',         ci.theme,
    'status',        ci.status,
    'title',         ci.title,
    'caption',       ci.caption,
    'on_image_text', ci.on_image_text,
    'alt_text',      ci.alt_text,
    'tags',          to_jsonb(ci.tags),
    'category',      ci.category,
    'image_slot',    ci.image_slot,
    'scheduled_for', ci.scheduled_for,
    'created_at',    ci.created_at,
    'updated_at',    ci.updated_at,
    'posted',        coalesce(last_pub.action = 'published', false),
    'posted_at',     case when last_pub.action = 'published' then last_pub.occurred_at end,
    'channel',       case when last_pub.action = 'published' then last_pub.channel end,
    -- La ligne « Why this one: … », rendue pour ELLE.
    'rationale',     ci.rationale,
    /*
     * Le sujet dont ce post vient, ou `null`.
     *
     * ⚠ `null` EST UN ÉTAT NORMAL, PAS UNE ERREUR. Un post qu'elle a créé
     * elle-même ne vient d'aucun sujet ; un post dont le sujet a été retiré
     * de la banque non plus. L'écran n'affiche alors pas de libellé d'angle,
     * ce qui est correct — et il n'invente pas « Uncategorised ».
     */
    'topic',         case when t.id is null then null else jsonb_build_object(
                       'id',          t.id,
                       'angle',       t.intent,
                       'angle_label', ci_intent.label,
                       'archetype_key', t.archetype_key,
                       'timely',      t.timely
                     ) end
  )
  from public.content_items ci
  left join public.content_topics  t         on t.id = ci.topic_id
  left join public.content_intents ci_intent on ci_intent.id = t.intent
  left join lateral (
    select cp.action, cp.occurred_at, cp.channel
      from public.content_publications cp
     where cp.content_item_id = ci.id
     order by cp.occurred_at desc, cp.id desc
     limit 1
  ) last_pub on true
  where ci.id = p_id
$function$;

comment on function public.content_item_json(uuid) is
  'One content item as the screens read it. Carries `rationale` (the rendered "Why this one" line, hers) and `topic` (the bank topic''s angle and its label, shared). `topic` is null for a post she wrote herself or whose topic was retired -- a normal state, and the screen shows no angle rather than inventing one.';


-- ============================================================================
-- 5. set_content_item_topic — le pipeline attache le sujet et sa justification
-- ============================================================================
create or replace function public.set_content_item_topic(
  p_id        uuid,
  p_topic_id  uuid,
  p_rationale text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit uuid;
begin
  select brand_kit_id into v_kit from public.content_items where id = p_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  -- ⚠ LE SUJET DOIT AVOIR ÉTÉ ATTRIBUÉ À CE KIT. Sans cette vérification, un
  -- appelant pourrait épingler sur un post le sujet d'une consœur, et la
  -- policy de `content_topics` le rendrait alors lisible — ce qui contourne
  -- exactement ce qu'elle garde.
  if p_topic_id is not null and not exists (
    select 1 from public.topic_assignments ta
     where ta.brand_kit_id = v_kit and ta.topic_id = p_topic_id
  ) then
    return public.content_error('forbidden');
  end if;

  update public.content_items
     set topic_id   = p_topic_id,
         rationale  = left(nullif(btrim(coalesce(p_rationale, '')), ''), 200),
         updated_at = now()
   where id = p_id;

  return public.content_item_json(p_id);
end
$$;

comment on function public.set_content_item_topic(uuid, uuid, text) is
  'Attaches a bank topic and its rendered rationale to a post. Refuses a topic that was never assigned to this kit -- otherwise a caller could pin a colleague''s topic on a post and make it readable through content_topics'' own policy.';

revoke all on function public.set_content_item_topic(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.set_content_item_topic(uuid, uuid, text) to service_role;


-- ============================================================================
-- 6. custom_visual_path — la question posée AVANT de dépenser
-- ============================================================================
-- Le pendant de `rendered_asset_path`, pour le chemin payant. Interroger
-- d'abord évite l'appel, la réservation ET la ligne de journal ;
-- `record_custom_visual` sait rattraper le cas, mais ce rattrapage existe pour
-- la course entre deux demandes simultanées, pas pour le cas courant.
create or replace function public.custom_visual_path(
  p_brand_kit_id uuid,
  p_prompt_hash  text
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select cv.storage_path
    from public.custom_visual_generations cv
   where cv.brand_kit_id = p_brand_kit_id
     and cv.prompt_hash  = p_prompt_hash
$$;

comment on function public.custom_visual_path(uuid, text) is
  'The stored path for this (kit, prompt hash), or NULL. THE call the custom-visual path makes before reserving a credit: a hit means no API call, no reservation and no ledger row at all.';

revoke all on function public.custom_visual_path(uuid, text) from public, anon, authenticated;
grant execute on function public.custom_visual_path(uuid, text) to service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
-- ⚠ LE JEU DE CLEFS, AVANT TOUT LE RESTE.
--
-- `create or replace function` remplace le corps EN ENTIER. Reprendre ce corps
-- d'une migration antérieure à la dernière fait disparaître, sans erreur, tout
-- ce que les migrations intermédiaires y avaient ajouté — et la perte se voit
-- sur un écran, des jours plus tard. C'est arrivé ici avec `theme`.
--
-- Ce bloc épingle donc le contrat : toutes les clefs d'avant, plus les deux
-- nouvelles.
do $keys$
declare
  v_keys text[];
  v_expected text[] := array[
    'id', 'brand_kit_id', 'archetype', 'register', 'month_id', 'theme', 'status',
    'title', 'caption', 'on_image_text', 'alt_text', 'tags', 'category',
    'image_slot', 'scheduled_for', 'created_at', 'updated_at',
    'posted', 'posted_at', 'channel',
    'rationale', 'topic'
  ];
  v_missing text;
begin
  select array_agg(k order by k) into v_keys
    from jsonb_object_keys(
      public.content_item_json((select id from public.content_items limit 1))
    ) as k;

  -- Aucune ligne en base : le contrat se vérifie contre une ligne posée ici.
  if v_keys is null then
    raise notice 'content_item_json: aucune ligne pour éprouver le jeu de clefs; le test le fera.';
    return;
  end if;

  foreach v_missing in array v_expected loop
    if not (v_missing = any (v_keys)) then
      raise exception 'content_item_json a perdu la clef « % ». `create or replace` remplace le corps en entier.', v_missing;
    end if;
  end loop;
end
$keys$;


do $$
declare
  v_mod  text; v_per text;
  v_u    uuid := gen_random_uuid();
  v_p    uuid := gen_random_uuid();
  v_k    uuid := gen_random_uuid();
  v_seg  uuid; v_topic uuid; v_item uuid; v_json jsonb;
  v_n    integer;
begin
  select count(*) into v_n from public.content_intents;
  if v_n <> 5 then
    raise exception 'content_intents: % lignes, attendu 5', v_n;
  end if;

  -- ⚠ LES CINQ INTENTIONS DE LA BANQUE ONT TOUTES UN LIBELLÉ. C'est ce que la
  -- clef étrangère garantit maintenant, et ce bloc le prouve sur les données.
  if exists (
    select 1 from public.content_topics t
     where not exists (select 1 from public.content_intents i where i.id = t.intent)
  ) then
    raise exception 'un sujet porte une intention qui n''a pas de libellé.';
  end if;

  if has_function_privilege('authenticated', 'public.set_content_item_topic(uuid,uuid,text)'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated peut exécuter set_content_item_topic.';
  end if;
  if has_function_privilege('authenticated', 'public.custom_visual_path(uuid,text)'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated peut exécuter custom_visual_path.';
  end if;

  -- ---- l'angle et la justification arrivent bien sur l'item --------------
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u, 'why@example.invalid');
  insert into public.projects (id, user_id, name) values (v_p, v_u, 'W');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_p, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k, v_p);
  -- ⚠ `get_content_month` PASSE PAR `content_kit_access`, qui refuse un kit
  -- non payé. Sans ce droit, la sonde de la fin lirait un objet d'erreur et
  -- conclurait que `rationale` n'est pas porté — vrai, mais pour une raison
  -- qui n'a rien à voir. Un octroi comp plutôt qu'un achat fabriqué : c'est
  -- la table qui existe pour ça.
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_u, 'topic link guard rail', 'migration 20260921090000', now() + interval '1 day');

  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'correct_a_myth', 'A topic', 'A hook',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'seed', 'Because {{specialty}} keeps coming up.', now())
  returning id into v_topic;

  insert into public.content_items (brand_kit_id, archetype, status, title)
  values (v_k, 'statement', 'draft', 'A post')
  returning id into v_item;

  -- ⚠ UN SUJET NON ATTRIBUÉ EST REFUSÉ. Sinon on épinglerait le sujet d'une
  -- consœur et la policy de content_topics le rendrait lisible.
  -- ⚠ `content_error` IMBRIQUE : `{"error": {"code": …, "message": …}}`.
  -- Lu à plat (`->> 'error'`) il rend l'objet sérialisé, jamais le code, et
  -- l'assertion passe pour la mauvaise raison — ce qu'elle a fait ici.
  if (public.set_content_item_topic(v_item, v_topic, 'Because burnout keeps coming up.')
      #>> '{error,code}') is distinct from 'forbidden' then
    raise exception 'un sujet non attribué à ce kit a été épinglé sur un post.';
  end if;

  insert into public.topic_assignments (brand_kit_id, topic_id, month)
  values (v_k, v_topic, date_trunc('month', now())::date);

  v_json := public.set_content_item_topic(v_item, v_topic, 'Because burnout keeps coming up.');
  if v_json #>> '{topic,angle}' <> 'correct_a_myth' then
    raise exception 'l''angle n''est pas porté par content_item_json: %', v_json;
  end if;
  if v_json #>> '{topic,angle_label}' <> 'Myth, gently corrected' then
    raise exception 'le libellé d''angle n''est pas porté: %', v_json #>> '{topic,angle_label}';
  end if;
  if v_json ->> 'rationale' <> 'Because burnout keeps coming up.' then
    raise exception 'la justification n''est pas portée: %', v_json ->> 'rationale';
  end if;

  -- ---- un post sans sujet n'invente pas d'angle --------------------------
  v_json := public.set_content_item_topic(v_item, null, null);
  if v_json -> 'topic' <> 'null'::jsonb then
    raise exception 'un post sans sujet porte quand même un objet topic: %', v_json -> 'topic';
  end if;
  if v_json ->> 'rationale' is not null then
    raise exception 'un post sans sujet porte quand même une justification.';
  end if;

  -- ---- retirer le sujet n'emporte pas le post ----------------------------
  v_json := public.set_content_item_topic(v_item, v_topic, 'Because.');
  delete from public.topic_assignments where topic_id = v_topic;
  delete from public.content_topics where id = v_topic;
  select count(*) into v_n from public.content_items where id = v_item and topic_id is null;
  if v_n <> 1 then
    raise exception 'retirer un sujet de la banque a emporté le post qui en venait.';
  end if;

  /*
   * ⚠ `get_content_month` N'EST PAS ÉPROUVÉ ICI, ET C'EST UNE LIMITE DU LIEU.
   *
   * Il passe par `content_kit_access` → `kit_paid_access`, qui est scopée
   * ⚠ ET LE MOT « dollar-dollar » EST ÉCRIT EN TOUTES LETTRES CI-DESSOUS :
   * les deux caractères, dans un commentaire, referment le bloc qui les
   * contient. Le message d'erreur qui en sort pointe la ligne du commentaire
   * et parle de syntaxe, ce qui envoie chercher au mauvais endroit.
   *
   * `auth.uid()`. Dans un bloc « do dollar-dollar » de migration il n'y a pas
   * d'appelant :
   * `auth.uid()` est NULL et la fonction rend `not_found` — correctement, et
   * pour une raison qui n'a rien à voir avec ce qu'on voulait mesurer.
   *
   * L'assertion vit donc dans `supabase/tests/20260921090000_why_this_one.test.sql`,
   * qui pose un vrai claim JWT. C'est la même répartition que partout dans ce
   * dépôt : une sonde de migration prouve ce qui est vrai pour le
   * propriétaire, un fichier de test prouve ce qui est vrai pour une cliente.
   */

  delete from public.content_segments where id = v_seg;
  delete from auth.users where id = v_u;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.custom_visual_path(uuid, text);
--   drop function if exists public.set_content_item_topic(uuid, uuid, text);
--   -- restore content_item_json from 20260910102753 (drops rationale + topic);
--   alter table public.content_items drop column if exists rationale;
--   alter table public.content_items drop column if exists topic_id;
--   alter table public.content_topics drop constraint if exists content_topics_intent_fkey;
--   drop table if exists public.content_intents;
