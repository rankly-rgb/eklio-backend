-- ============================================================================
-- Eklio — la banque de sujets, et le tirage qui alimente Swap
-- ============================================================================
-- Swap doit être INSTANTANÉ, GRATUIT ET DÉTERMINISTE. Ces trois mots excluent
-- ensemble la seule implémentation évidente — demander un autre sujet à un
-- modèle — et imposent celle-ci : une banque pré-générée, et un tirage qui est
-- une requête.
--
-- ── ⚠ POURQUOI LES SUJETS NE SONT PAS CLEFÉS SUR UN KIT ─────────────────
--
-- Un sujet est du STOCK : « le cycle de la rumination pour une praticienne
-- EMDR qui reçoit des adultes en burnout » ne devient celui de personne en
-- étant écrit. Ce qui appartient à quelqu'un est l'ATTRIBUTION, et c'est
-- `topic_assignments` qui la porte.
--
-- La distinction n'est pas théorique : la contrainte anti-collision de la
-- PHASE 2.2 — un même sujet n'est pas servi à deux praticiennes partageant
-- (État, modalité) dans une fenêtre de 90 jours — ne peut PAS s'exprimer si
-- chaque kit a sa copie privée du sujet. Elle a besoin que « le même sujet »
-- soit une ligne, pas une ressemblance.
--
-- ── ⚠ ET L'ATTRIBUTION EST PAR KIT, PAS PAR PERSONNE ────────────────────
--
-- Contrairement aux crédits (`20260920140100`, qui suivent l'abonnement, donc
-- la personne). Une caption appartient à une MARQUE : deux kits d'une même
-- praticienne sont deux voix, et leur interdire un sujet commun n'aurait pas
-- de sens. La collision INTER-personnes, elle, se pose au niveau de la
-- personne, et le §4 la pose là en joignant `projects.user_id`.
-- ============================================================================


-- ============================================================================
-- 1. content_segments — structuré, jamais du texte libre
-- ============================================================================
-- Modalité × population × (optionnel) État. Les trois côtés pointent vers des
-- catalogues qui existent déjà — `modality_cards`, `client_persona_cards`,
-- `license_type_states` pour les codes d'État — plutôt que de recopier trois
-- vocabulaires.

create table if not exists public.content_segments (
  id           uuid     primary key default gen_random_uuid(),
  modality_id  text     not null references public.modality_cards (id),
  persona_id   text     not null references public.client_persona_cards (id),
  -- NULL = ce segment vaut pour tous les États. Ce n'est pas « inconnu » :
  -- c'est le cas général, et c'est le plus fréquent.
  state_code   char(2),
  created_at   timestamptz not null default now(),

  constraint content_segments_state_check
    check (state_code is null or state_code ~ '^[A-Z]{2}$')
);

comment on table public.content_segments is
  'Modality x population x (optional) state. Three foreign keys into the catalogues that already exist, never free text -- a segment described in prose can be neither counted, nor degraded towards a neighbour, nor used for the anti-collision window.';
comment on column public.content_segments.state_code is
  'NULL means every state. The general case, not an unknown: most topics do not depend on the jurisdiction, and the ones that do (telehealth, insurance) name it.';

-- ⚠ DEUX INDEX PARTIELS, PAS UN `unique nulls not distinct`. La clause existe
-- depuis PostgreSQL 15 et marcherait ici ; deux index partiels marchent aussi
-- sur une base plus ancienne, et surtout ils DISENT les deux cas — « ce
-- segment-là pour cet État » et « ce segment-là pour tous » — là où la clause
-- laisse la lectrice déduire que NULL a été rendu comparable.
create unique index if not exists content_segments_with_state_key
  on public.content_segments (modality_id, persona_id, state_code)
  where state_code is not null;
create unique index if not exists content_segments_any_state_key
  on public.content_segments (modality_id, persona_id)
  where state_code is null;

alter table public.content_segments enable row level security;

drop policy if exists "content_segments_select_all"    on public.content_segments;
drop policy if exists "content_segments_insert_denied" on public.content_segments;
drop policy if exists "content_segments_update_denied" on public.content_segments;
drop policy if exists "content_segments_delete_denied" on public.content_segments;

create policy "content_segments_select_all" on public.content_segments
  for select to authenticated using (true);
create policy "content_segments_insert_denied" on public.content_segments
  for insert with check (false);
create policy "content_segments_update_denied" on public.content_segments
  for update using (false);
create policy "content_segments_delete_denied" on public.content_segments
  for delete using (false);


-- ============================================================================
-- 2. content_topics — la banque
-- ============================================================================
create table if not exists public.content_topics (
  id                  uuid     primary key default gen_random_uuid(),
  segment_id          uuid     not null references public.content_segments (id) on delete cascade,
  archetype_key       text     not null references public.content_archetypes (id),
  intent              text     not null,
  title               text     not null,
  hook                text     not null,
  payload             jsonb    not null,
  caption_seed        text     not null,
  -- Alimente la ligne « Why this one: … » sous chaque carte. Un GABARIT, pas
  -- une phrase finie : il porte des substitutions que le pipeline remplit avec
  -- ce que le brief de la praticienne dit réellement.
  rationale_template  text     not null,
  -- NULL = pas encore relu. La garde déontologique passe UNE fois par sujet,
  -- ici, et non à chaque post : c'est ce qui rend trente publications
  -- mensuelles tenables.
  ethics_reviewed_at  timestamptz,
  timely              boolean  not null default false,
  expires_at          timestamptz,
  generation_batch_id uuid,
  created_at          timestamptz not null default now(),

  constraint content_topics_intent_check check
    (intent in ('educate', 'normalise', 'invite', 'correct_a_myth', 'behind_the_practice')),
  constraint content_topics_title_check   check (char_length(title) between 1 and 80),
  constraint content_topics_hook_check    check (char_length(hook) between 1 and 160),
  constraint content_topics_caption_check check (char_length(caption_seed) between 1 and 2200),
  constraint content_topics_rationale_check
    check (char_length(rationale_template) between 1 and 200),

  -- ⚠ LE PAYLOAD EST VALIDÉ PAR ARCHÉTYPE, DANS LA LIGNE.
  --
  -- Pas dans le pipeline seulement : un sujet mal formé écrit par un chemin
  -- qu'on n'a pas encore imaginé produirait un rendu cassé au 1er du mois, la
  -- nuit, pour tout le monde à la fois. La contrainte est ce qui fait que la
  -- seule façon d'obtenir un quadrant à trois cases est de ne pas en obtenir.
  constraint content_topics_payload_check
    check (public.content_topic_payload_valid(archetype_key, payload)),

  -- Un sujet daté a une date de péremption, et un sujet intemporel n'en a pas.
  -- Les deux moitiés, parce que l'une sans l'autre laisse passer la moitié des
  -- incohérences : un « awareness month » sans fin resterait proposé en juin.
  constraint content_topics_timely_expiry_check check (timely = (expires_at is not null))
);

comment on table public.content_topics is
  'The topic bank. STOCK, not anybody''s property: what belongs to a kit is the topic_assignments row. That distinction is what makes the cross-practitioner anti-collision window expressible at all -- it needs "the same topic" to be one row, not a resemblance.';
comment on column public.content_topics.payload is
  'The archetype''s structured fields, validated by content_topic_payload_valid IN THE ROW. A malformed topic written through some path nobody anticipated would break rendering on the 1st, overnight, for everybody at once.';
comment on column public.content_topics.ethics_reviewed_at is
  'When the ethics guard reviewed THIS TOPIC. Once per topic, never per post: that is what makes thirty monthly publications affordable. The generated TEXT still goes through banned_phrases on every write -- diagram labels included.';
comment on column public.content_topics.rationale_template is
  'The template for the "Why this one: ..." line. A template and not a finished sentence: the pipeline substitutes what her own brief says, so the justification is hers rather than generic copy.';

create index if not exists content_topics_segment_idx
  on public.content_topics (segment_id, archetype_key);
-- Le tirage ne considère QUE les sujets relus. Index partiel : les non relus
-- sont du stock en cours de fabrication et n'ont rien à faire dans le plan.
create index if not exists content_topics_reviewed_idx
  on public.content_topics (segment_id)
  where ethics_reviewed_at is not null;
create index if not exists content_topics_timely_idx
  on public.content_topics (expires_at)
  where timely;
create index if not exists content_topics_batch_idx
  on public.content_topics (generation_batch_id);

-- ⚠ LA POLICY DE `content_topics` EST PLUS BAS, APRÈS `topic_assignments`.
-- Elle lit cette table-là, et une policy est analysée à la création : écrite
-- ici, la migration échoue sur « relation topic_assignments does not exist ».
-- L'ordre des sections suit donc la dépendance, pas la lecture.

-- ============================================================================
-- 3. topic_assignments — ce qui appartient à un kit
-- ============================================================================
create table if not exists public.topic_assignments (
  brand_kit_id uuid not null references public.brand_kits (id) on delete cascade,
  topic_id     uuid not null references public.content_topics (id) on delete cascade,
  month        date not null,
  assigned_at  timestamptz not null default now(),

  -- ⚠ LA CLEF PRIMAIRE EST (kit, sujet) ET PAS (kit, sujet, mois). C'est elle
  -- qui dit « jamais deux fois le même sujet, à vie » : un sujet déjà attribué
  -- en mars ne peut pas l'être à nouveau en novembre, parce que la ligne
  -- existe déjà. Y ajouter le mois transformerait la règle en « jamais deux
  -- fois dans le même mois », ce qui n'est pas la même promesse.
  constraint topic_assignments_pkey primary key (brand_kit_id, topic_id),
  constraint topic_assignments_month_check check (month = date_trunc('month', month)::date)
);

comment on table public.topic_assignments is
  'Which topic was served to which kit, and for which month. The primary key is (kit, topic) WITHOUT the month: that is what holds "never the same topic twice, ever". With the month in it the promise would become "never twice in the same month".';

create index if not exists topic_assignments_topic_idx
  on public.topic_assignments (topic_id, assigned_at desc);
create index if not exists topic_assignments_kit_month_idx
  on public.topic_assignments (brand_kit_id, month desc);

alter table public.topic_assignments enable row level security;

drop policy if exists "topic_assignments_select_own"    on public.topic_assignments;
drop policy if exists "topic_assignments_insert_denied" on public.topic_assignments;
drop policy if exists "topic_assignments_update_denied" on public.topic_assignments;
drop policy if exists "topic_assignments_delete_denied" on public.topic_assignments;

create policy "topic_assignments_select_own" on public.topic_assignments
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = topic_assignments.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "topic_assignments_insert_denied" on public.topic_assignments
  for insert with check (false);
create policy "topic_assignments_update_denied" on public.topic_assignments
  for update using (false);
create policy "topic_assignments_delete_denied" on public.topic_assignments
  for delete using (false);


alter table public.content_topics enable row level security;

drop policy if exists "content_topics_select_assigned" on public.content_topics;
drop policy if exists "content_topics_insert_denied"   on public.content_topics;
drop policy if exists "content_topics_update_denied"   on public.content_topics;
drop policy if exists "content_topics_delete_denied"   on public.content_topics;

-- ⚠ ELLE NE VOIT QUE CE QUI LUI A ÉTÉ ATTRIBUÉ, et c'est un choix de produit
-- autant que de sécurité. La banque entière lisible, c'est le catalogue des
-- sujets du concurrent d'à côté, et c'est aussi la fin de l'effet « celui-ci a
-- été choisi pour vous ».
create policy "content_topics_select_assigned" on public.content_topics
  for select using (exists (
    select 1
      from public.topic_assignments ta
      join public.brand_kits bk on bk.id = ta.brand_kit_id
      join public.projects   pr on pr.id = bk.project_id
     where ta.topic_id = content_topics.id
       and pr.user_id = (select auth.uid())
  ));
create policy "content_topics_insert_denied" on public.content_topics
  for insert with check (false);
create policy "content_topics_update_denied" on public.content_topics
  for update using (false);
create policy "content_topics_delete_denied" on public.content_topics
  for delete using (false);


-- ============================================================================
-- 4. La fenêtre anti-collision, écrite une fois
-- ============================================================================
create or replace function public.topic_collision_window()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '90 days'
$$;

comment on function public.topic_collision_window() is
  'How long a topic served to one practitioner stays unavailable to another sharing (state, modality). THE one place the 90 days are written.';

revoke all on function public.topic_collision_window() from public;
grant execute on function public.topic_collision_window() to authenticated, service_role;


-- ============================================================================
-- 5. next_topic_for_kit — le tirage. Une requête, aucun modèle.
-- ============================================================================
-- ⚠ LA DÉGRADATION VERS LES SEGMENTS ADJACENTS N'EST PAS UNE CASCADE.
--
-- Écrite comme une échelle de replis — « essaie le segment exact ; s'il est
-- vide essaie la même modalité ; sinon la même population » — elle aurait
-- autant de comportements que de barreaux, et chacun serait un endroit où un
-- sujet moins bon peut battre un meilleur par accident d'ordre.
--
-- Elle est ici UN SEUL classement. Un segment exact marque plus haut qu'un
-- segment qui ne partage que la modalité, qui marque plus haut qu'un segment
-- qui ne partage que la population. Quand le segment principal est épuisé, ce
-- sont mécaniquement les voisins qui sortent en tête — sans qu'aucune ligne de
-- code ne s'appelle « repli ».
--
-- ⚠ ET LE CLASSEMENT EST TOTAL. `order by … , t.id` ferme le dernier
-- ex aequo : deux appels sur le même état de banque rendent le même sujet.
-- Sans ce dernier critère, « déterministe » serait faux dès deux sujets de
-- même score, et le test de la PHASE 6 qui rejoue un mois ne prouverait rien.

create or replace function public.next_topic_for_kit(
  p_brand_kit_id uuid,
  p_month        date,
  p_archetype    text default null
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with kit as (
    select coalesce(pb.modality_ids, '{}')       as modalities,
           coalesce(pb.client_persona_ids, '{}') as personas,
           upper(nullif(btrim(coalesce(pb.state, '')), '')) as state_code,
           pr.user_id                            as user_id
      from public.brand_kits bk
      join public.projects      pr on pr.id = bk.project_id
      left join public.project_briefs pb on pb.project_id = pr.id
     where bk.id = p_brand_kit_id
  )
  select t.id
    from public.content_topics t
    join public.content_segments s on s.id = t.segment_id
   cross join kit k
   where
     -- Un sujet non relu n'est pas du stock, c'est un brouillon.
     t.ethics_reviewed_at is not null
     -- Un sujet daté et périmé ne sort plus. `expires_at is null` couvre les
     -- intemporels, et le CHECK de la table garantit qu'ils ne sont pas
     -- `timely` -- les deux moitiés se tiennent.
     and (t.expires_at is null or t.expires_at > now())
     and (p_archetype is null or t.archetype_key = p_archetype)

     -- ── Jamais deux fois, à vie ────────────────────────────────────────
     and not exists (
       select 1 from public.topic_assignments ta
        where ta.brand_kit_id = p_brand_kit_id and ta.topic_id = t.id
     )

     -- ── Anti-collision inter-praticiennes ──────────────────────────────
     -- ⚠ ENTRE PERSONNES, PAS ENTRE KITS. Deux kits d'une même praticienne
     -- sont deux voix et n'ont aucune raison de s'exclure ; deux praticiennes
     -- du même État pratiquant la même modalité parlent, elles, au même
     -- public, et le même diagramme chez les deux se voit.
     and not exists (
       select 1
         from public.topic_assignments ta
         join public.brand_kits   obk on obk.id = ta.brand_kit_id
         join public.projects     opr on opr.id = obk.project_id
         left join public.project_briefs opb on opb.project_id = opr.id
        where ta.topic_id = t.id
          and ta.assigned_at > now() - public.topic_collision_window()
          and opr.user_id is distinct from k.user_id
          and k.state_code is not null
          and upper(nullif(btrim(coalesce(opb.state, '')), '')) = k.state_code
          and coalesce(opb.modality_ids, '{}') && k.modalities
     )

     -- Un segment qui ne partage NI la modalité NI la population n'est pas un
     -- voisin, c'est quelqu'un d'autre. Le classement ci-dessous ne pourrait
     -- pas l'exclure : il lui donnerait simplement le plus petit score, et il
     -- sortirait quand même une fois tout le reste épuisé.
     and (s.modality_id = any (k.modalities) or s.persona_id = any (k.personas))
     and (s.state_code is null or s.state_code = k.state_code)

   order by
     -- recouvrement modalité + population
     (case when s.modality_id = any (k.modalities) then 2 else 0 end)
     + (case when s.persona_id = any (k.personas) then 2 else 0 end)
     -- un segment qui NOMME son État est plus précis qu'un segment général
     + (case when s.state_code is not null then 1 else 0 end)
     -- bonus d'actualité
     + (case when t.timely then 3 else 0 end)
     desc,
     -- fraîcheur, à score égal
     t.created_at desc,
     -- ⚠ LE DERNIER EX AEQUO. Sans lui, « déterministe » est faux.
     t.id
   limit 1
$$;

comment on function public.next_topic_for_kit(uuid, date, text) is
  'The next topic for this kit, or NULL when the bank has nothing eligible left. A QUERY: no model call, therefore free and instant -- this is what Swap runs on. Degradation towards neighbouring segments is a single ranking rather than a ladder of fallbacks, and the sort ends on t.id so that two calls against the same bank state return the same topic.';

revoke all on function public.next_topic_for_kit(uuid, date, text) from public, anon, authenticated;
grant execute on function public.next_topic_for_kit(uuid, date, text) to service_role;


-- ============================================================================
-- 6. assign_topic_to_kit — le tirage ET l'attribution, atomiques
-- ============================================================================
-- ⚠ TIRER PUIS ÉCRIRE EN DEUX APPELS EST UNE COURSE. Deux Swap simultanés
-- liraient le même « prochain sujet » et l'un des deux écrirait une ligne déjà
-- écrite. `on conflict do nothing` + la boucle font que le perdant en tire un
-- autre au lieu d'échouer.

create or replace function public.assign_topic_to_kit(
  p_brand_kit_id uuid,
  p_month        date,
  p_archetype    text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, now()))::date;
  v_topic uuid;
  v_done  boolean;
  v_tries integer := 0;
begin
  if p_brand_kit_id is null then
    return null;
  end if;

  loop
    v_tries := v_tries + 1;
    -- Une banque dimensionnée pour ~500 sujets par segment ne produit pas dix
    -- collisions d'affilée ; dix tours est une borne contre une boucle
    -- infinie, pas un budget de réessais attendu.
    exit when v_tries > 10;

    v_topic := public.next_topic_for_kit(p_brand_kit_id, v_month, p_archetype);
    if v_topic is null then
      return null;
    end if;

    insert into public.topic_assignments (brand_kit_id, topic_id, month)
    values (p_brand_kit_id, v_topic, v_month)
    on conflict (brand_kit_id, topic_id) do nothing;

    get diagnostics v_done = row_count;
    if v_done then
      return v_topic;
    end if;
  end loop;

  return null;
end
$$;

comment on function public.assign_topic_to_kit(uuid, date, text) is
  'Draws the next topic AND assigns it, atomically. Two simultaneous swaps would otherwise read the same "next" and one would write a row that already exists: the loser of the on-conflict simply draws another. Returns NULL when the bank has nothing left -- a caller that gets NULL must SAY so, not retry.';

revoke all on function public.assign_topic_to_kit(uuid, date, text) from public, anon, authenticated;
grant execute on function public.assign_topic_to_kit(uuid, date, text) to service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_seg_a  uuid;
  v_seg_b  uuid;
  v_seg_c  uuid;
  v_mod    text;
  v_mod2   text;
  v_per    text;
  v_user_1 uuid := gen_random_uuid();
  v_user_2 uuid := gen_random_uuid();
  v_proj_1 uuid := gen_random_uuid();
  v_proj_2 uuid := gen_random_uuid();
  v_kit_1  uuid := gen_random_uuid();
  v_kit_2  uuid := gen_random_uuid();
  v_t      uuid;
  v_t2     uuid;
  v_month  date := date_trunc('month', now())::date;
  v_n      integer;
  t        text;
begin
  -- ---- RLS et surface ----------------------------------------------------
  foreach t in array array['content_segments', 'content_topics', 'topic_assignments'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'topic bank: RLS absente sur %', t;
    end if;
  end loop;
  foreach t in array array['next_topic_for_kit(uuid,date,text)',
                           'assign_topic_to_kit(uuid,date,text)'] loop
    if has_function_privilege('authenticated', ('public.' || t)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated peut exécuter %, qui sert un sujet à un kit arbitraire', t;
    end if;
  end loop;

  -- ---- Deux praticiennes, même État, même modalité -----------------------
  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_mod2 from public.modality_cards where active and id <> v_mod
   order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;
  if v_mod is null or v_mod2 is null or v_per is null then
    raise exception 'les catalogues de modalités/populations sont vides; ce garde-fou ne prouve rien.';
  end if;

  insert into auth.users (id, email) values
    (v_user_1, 'topics-1@example.invalid'), (v_user_2, 'topics-2@example.invalid');
  insert into public.projects (id, user_id, name) values
    (v_proj_1, v_user_1, 'P1'), (v_proj_2, v_user_2, 'P2');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state) values
    (v_proj_1, array[v_mod], array[v_per], 'CA'),
    (v_proj_2, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values
    (v_kit_1, v_proj_1), (v_kit_2, v_proj_2);

  insert into public.content_segments (modality_id, persona_id, state_code)
  values (v_mod, v_per, null) returning id into v_seg_a;

  -- Un sujet relu, intemporel.
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg_a, 'single_statement', 'normalise', 'Rest is not earned',
          'A sentence she can post as is',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'Rest is not a reward.', 'Because {{specialty}} keeps coming up.', now())
  returning id into v_t;

  -- ---- le tirage le trouve -----------------------------------------------
  if public.next_topic_for_kit(v_kit_1, v_month) is distinct from v_t then
    raise exception 'le tirage n''a pas trouvé le seul sujet éligible.';
  end if;

  -- ---- déterminisme : deux appels, même réponse --------------------------
  if public.next_topic_for_kit(v_kit_1, v_month)
     is distinct from public.next_topic_for_kit(v_kit_1, v_month) then
    raise exception 'deux tirages consécutifs ont rendu deux sujets différents.';
  end if;

  -- ---- l'attribution est atomique et consomme ----------------------------
  if public.assign_topic_to_kit(v_kit_1, v_month) is distinct from v_t then
    raise exception 'assign_topic_to_kit n''a pas attribué le sujet attendu.';
  end if;
  select count(*) into v_n from public.topic_assignments where brand_kit_id = v_kit_1;
  if v_n <> 1 then
    raise exception 'assign_topic_to_kit a écrit % ligne(s), attendu 1', v_n;
  end if;

  -- ---- ⚠ JAMAIS DEUX FOIS, À VIE ----------------------------------------
  if public.next_topic_for_kit(v_kit_1, v_month) is not null then
    raise exception 'un sujet déjà attribué a été reproposé au même kit.';
  end if;
  -- Y compris dans un autre mois : c'est la clef primaire sans le mois qui le
  -- tient, et c'est la moitié de la règle qu'un test par mois raterait.
  if public.next_topic_for_kit(v_kit_1, (v_month + interval '5 months')::date) is not null then
    raise exception 'un sujet attribué en mars a été reproposé en août au même kit.';
  end if;

  -- ---- ⚠ ANTI-COLLISION : même État, même modalité, 90 jours -------------
  if public.next_topic_for_kit(v_kit_2, v_month) is not null then
    raise exception 'le même sujet a été servi à deux praticiennes de CA pratiquant la même modalité.';
  end if;

  -- Une praticienne d'un AUTRE État n'est pas concernée par la fenêtre.
  update public.project_briefs set state = 'FL' where project_id = v_proj_2;
  if public.next_topic_for_kit(v_kit_2, v_month) is distinct from v_t then
    raise exception 'la fenêtre a bloqué une praticienne d''un autre État.';
  end if;

  -- Une praticienne du même État mais d'une AUTRE modalité non plus.
  update public.project_briefs set state = 'CA', modality_ids = array[v_mod2]
   where project_id = v_proj_2;
  if public.next_topic_for_kit(v_kit_2, v_month) is distinct from v_t then
    raise exception 'la fenêtre a bloqué une praticienne d''une autre modalité.';
  end if;

  -- ---- un sujet non relu n'est jamais servi ------------------------------
  update public.project_briefs set modality_ids = array[v_mod] where project_id = v_proj_2;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg_a, 'single_statement', 'invite', 'Not reviewed yet', 'A hook',
          '{"statement":"This one has not been through the ethics guard at all"}'::jsonb,
          'seed', 'Because.', null)
  returning id into v_t2;
  if public.next_topic_for_kit(v_kit_2, v_month) is not null then
    raise exception 'un sujet non relu par la garde déontologique a été servi.';
  end if;

  -- ---- un sujet daté et périmé ne sort plus ------------------------------
  update public.content_topics
     set ethics_reviewed_at = now(), timely = true, expires_at = now() - interval '1 day'
   where id = v_t2;
  if public.next_topic_for_kit(v_kit_2, v_month) is not null then
    raise exception 'un sujet daté et périmé a été servi.';
  end if;
  update public.content_topics set expires_at = now() + interval '30 days' where id = v_t2;
  if public.next_topic_for_kit(v_kit_2, v_month) is distinct from v_t2 then
    raise exception 'un sujet daté et valide n''est pas passé devant un intemporel (bonus timely).';
  end if;

  -- ---- le CHECK timely/expires_at tient les deux moitiés -----------------
  begin
    insert into public.content_topics
      (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
       rationale_template, timely, expires_at)
    values (v_seg_a, 'single_statement', 'invite', 'Timely forever', 'A hook',
            '{"statement":"A timely topic that somehow never expires at all"}'::jsonb,
            'seed', 'Because.', true, null);
    raise exception 'un sujet timely sans expires_at a été accepté.';
  exception when check_violation then null;
  end;
  begin
    insert into public.content_topics
      (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
       rationale_template, timely, expires_at)
    values (v_seg_a, 'single_statement', 'invite', 'Timeless but dated', 'A hook',
            '{"statement":"A timeless topic that somehow carries an expiry"}'::jsonb,
            'seed', 'Because.', false, now() + interval '1 day');
    raise exception 'un sujet non timely avec expires_at a été accepté.';
  exception when check_violation then null;
  end;

  -- ---- ⚠ LE PAYLOAD EST REFUSÉ PAR LA LIGNE -----------------------------
  begin
    insert into public.content_topics
      (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
       rationale_template)
    values (v_seg_a, 'quadrant_model', 'educate', 'Three is not four', 'A hook',
            '{"axis_x":"A","axis_y":"B","items":[{"label":"One","gloss":"a"}]}'::jsonb,
            'seed', 'Because.');
    raise exception 'un quadrant à un seul item a été écrit en base.';
  exception when check_violation then null;
  end;

  -- ---- un segment qui ne partage rien n'est pas un voisin ----------------
  insert into public.content_segments (modality_id, persona_id, state_code)
  values (v_mod2, (select id from public.client_persona_cards
                    where active and id <> v_per order by sort_order limit 1), null)
  returning id into v_seg_c;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg_c, 'single_statement', 'educate', 'Someone elses subject', 'A hook',
          '{"statement":"This belongs to a different modality and a different population"}'::jsonb,
          'seed', 'Because.', now());

  -- kit_1 a déjà pris v_t ; le seul autre sujet éligible pour lui serait v_t2,
  -- pas celui du segment étranger.
  if public.next_topic_for_kit(v_kit_1, v_month) is distinct from v_t2 then
    raise exception 'le tirage a servi un segment qui ne partage ni modalité ni population.';
  end if;

  -- ---- teardown ----------------------------------------------------------
  delete from public.content_segments where id in (v_seg_a, v_seg_c);
  delete from auth.users where id in (v_user_1, v_user_2);
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.assign_topic_to_kit(uuid, date, text);
--   drop function if exists public.next_topic_for_kit(uuid, date, text);
--   drop function if exists public.topic_collision_window();
--   drop table    if exists public.topic_assignments;
--   drop table    if exists public.content_topics;
--   drop table    if exists public.content_segments;
