-- ============================================================================
-- Eklio — the layout is hers to change, and it is not the column you think
-- ============================================================================
--
-- ⚠ THERE ARE TWO COLUMNS CALLED SOMETHING LIKE "ARCHETYPE", AND THEY ARE NOT
-- THE SAME VOCABULARY. This was found by the TypeScript compiler while wiring
-- the review screen, not by reading:
--
--   content_items.archetype        statement | question | notes | signature |
--                                  story | google_post
--                                  → the POST FORMAT. What kind of thing this
--                                    is on a feed. It predates this chantier.
--
--   content_archetypes.id          single_statement | quadrant_model | cycle |
--                                  surface_and_beneath | comparison_pair |
--                                  numbered_strategies | lettered_technique |
--                                  concentric_control | annotated_curve |
--                                  practitioner_card | carousel
--                                  → the CARD LAYOUT. How the composition
--                                    engine sets it. Added by this chantier.
--
-- The sets are disjoint, and the guard rail at the bottom of this file asserts
-- that they stay disjoint — because the day one word appears in both, every
-- screen reading either column starts being right by accident.
--
-- Until now an item's layout was reachable only THROUGH its topic
-- (`content_topics.archetype_key`), which is read-only from her side. So the
-- review screen could show two or three other layouts of the same content and
-- could not let her keep one. This column is what makes that choice stick.
--
-- ⚠ NULL IS THE NORMAL STATE AND IT MEANS "WHATEVER THE TOPIC SAYS". It is not
-- "unset, please backfill": a topic that gets a better default layout should
-- move every item that never overrode it, and only a null can follow.
-- ============================================================================

alter table public.content_items
  add column if not exists compose_archetype text;

alter table public.content_items
  drop constraint if exists content_items_compose_archetype_fkey;

alter table public.content_items
  add constraint content_items_compose_archetype_fkey
  foreign key (compose_archetype) references public.content_archetypes(id)
  on update cascade
  -- ⚠ RESTRICT, NOT SET NULL. Deleting a layout out from under the posts that
  -- chose it should be loud: eleven layouts are a contract the engine
  -- implements, and losing one silently turns her chosen card back into
  -- somebody else's default.
  on delete restrict;

comment on column public.content_items.compose_archetype is
  'The CARD LAYOUT she kept for this post, from content_archetypes.id. NOT content_items.archetype, which is the post format (statement/question/notes/...) and a different vocabulary entirely. Null means "use the topic''s layout", which is the normal state.';

create index if not exists content_items_compose_archetype_idx
  on public.content_items (compose_archetype)
  where compose_archetype is not null;


-- ============================================================================
-- The patch accepts it, and the foreign key is what refuses a bad one
-- ============================================================================
-- Everything else in this function is `20260914084054`'s body, unchanged. It
-- is repeated in full because `create or replace` replaces the whole body, and
-- a partial copy is how `theme` nearly disappeared once already.
create or replace function public.update_content_item(p_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_kit        uuid;
  v_error      text;
  v_bad        text;
  v_next_state text;
  v_next_alt   text;
begin
  select ci.brand_kit_id into v_kit
    from public.content_items ci
   where ci.id = p_id;

  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  select string_agg(key, ', ') into v_bad
    from jsonb_object_keys(p_patch) as key
   where key not in ('archetype','status','title','caption','alt_text',
                     'tags','category','image_slot','scheduled_for',
                     'on_image_text','compose_archetype');
  if v_bad is not null then
    return public.content_error('unknown_field');
  end if;

  select case when p_patch ? 'status'   then p_patch ->> 'status'   else ci.status end,
         case when p_patch ? 'alt_text' then p_patch ->> 'alt_text' else ci.alt_text end
    into v_next_state, v_next_alt
    from public.content_items ci
   where ci.id = p_id;

  if v_next_state = 'ready' and coalesce(btrim(v_next_alt), '') = '' then
    return public.content_error('alt_text_required');
  end if;

  /*
   * ⚠ LOOKED UP IN THE CATALOGUE, NOT LISTED AGAIN HERE. The foreign key is
   * still the guarantee; this read exists so that a bad layout comes back as a
   * refusal she can be shown, instead of a foreign-key violation that reaches
   * the browser as a 500. The twelfth layout added tomorrow is accepted by both
   * without either being edited.
   */
  if p_patch ? 'compose_archetype'
     and nullif(btrim(p_patch ->> 'compose_archetype'), '') is not null
     and not exists (
       select 1 from public.content_archetypes ca
        where ca.id = btrim(p_patch ->> 'compose_archetype') and ca.active
     )
  then
    return public.content_error('unknown_layout');
  end if;

  update public.content_items ci set
    archetype     = case when p_patch ? 'archetype'  then p_patch ->> 'archetype'  else ci.archetype end,
    -- ⚠ AN EMPTY STRING CLEARS IT, and clearing is a real choice: it is how she
    -- goes back to the layout the topic came with. Storing '' instead would
    -- break the foreign key and would mean nothing.
    compose_archetype = case when p_patch ? 'compose_archetype'
                             then nullif(btrim(p_patch ->> 'compose_archetype'), '')
                             else ci.compose_archetype end,
    status        = case when p_patch ? 'status'     then p_patch ->> 'status'     else ci.status end,
    title         = case when p_patch ? 'title'      then p_patch ->> 'title'      else ci.title end,
    caption       = case when p_patch ? 'caption'    then p_patch ->> 'caption'    else ci.caption end,
    alt_text      = case when p_patch ? 'alt_text'   then p_patch ->> 'alt_text'   else ci.alt_text end,
    category      = case when p_patch ? 'category'   then p_patch ->> 'category'   else ci.category end,
    image_slot    = case when p_patch ? 'image_slot' then p_patch ->> 'image_slot' else ci.image_slot end,
    on_image_text = case when p_patch ? 'on_image_text'
                         then nullif(btrim(p_patch ->> 'on_image_text'), '') else ci.on_image_text end,
    scheduled_for = case when p_patch ? 'scheduled_for'
                         then nullif(p_patch ->> 'scheduled_for', '')::date else ci.scheduled_for end,
    tags          = case when p_patch ? 'tags'
                         then public.content_normalize_tags(
                                array(select jsonb_array_elements_text(p_patch -> 'tags')))
                         else ci.tags end,
    updated_at    = now()
  where ci.id = p_id;

  return jsonb_build_object('id', p_id, 'saved_at', now());
end
$function$;

comment on function public.update_content_item(uuid, jsonb) is
  'Patch semantics: an absent key is left alone, a present null clears. The allow-list is the whole contract - `theme` is deliberately absent, because the month owns it. `compose_archetype` IS accepted: the layout is hers. An unknown value is refused twice over - once as `unknown_layout`, so she sees a refusal rather than a 500, and once by the foreign key, which is the guarantee. Neither lists the catalogue: both read it.';


-- ============================================================================
-- And the review screen can read back what it saved
-- ============================================================================
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
    'rationale',     ci.rationale,
    -- The layout she kept, or null for "whatever the topic says".
    'compose_archetype', ci.compose_archetype,
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


-- ============================================================================
-- A swap draws new content, so it drops the layout she kept for the old
-- ============================================================================
-- ⚠ NOT AN OVERSIGHT TO KEEP IT. `compose_archetype` is a layout she chose for
-- ONE piece of content: a cycle because that topic had three steps, a
-- comparison because that one had two sides. Swap replaces the content
-- entirely. Carrying her override across would apply a layout chosen for a
-- diagram that is no longer on the card, and the review screen would then show
-- her a refusal she never caused.
--
-- The body is `20260921100000`'s, repeated in full for the same reason as
-- above: `create or replace` replaces the whole body.
create or replace function public.swap_content_item(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_kit    uuid;
  v_user   uuid;
  v_month  date;
  v_topic  uuid;
  v_t      public.content_topics%rowtype;
  v_res    jsonb;
begin
  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = p_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  declare v_access text;
  begin
    v_access := public.content_kit_access(v_kit);
    if v_access is not null then
      return public.content_error(v_access);
    end if;
  end;

  select pr.user_id into v_user
    from public.brand_kits bk join public.projects pr on pr.id = bk.project_id
   where bk.id = v_kit;

  select coalesce(ci.scheduled_for, current_date) into v_month
    from public.content_items ci where ci.id = p_id;
  v_month := date_trunc('month', v_month)::date;

  v_topic := public.assign_topic_to_kit(v_kit, v_month);
  if v_topic is null then
    return public.content_error('bank_exhausted');
  end if;

  select * into v_t from public.content_topics where id = v_topic;

  update public.content_items ci
     set title         = left(v_t.title, 34),
         caption       = v_t.caption_seed,
         on_image_text = v_t.hook,
         topic_id      = v_t.id,
         rationale     = public.render_rationale(v_t.rationale_template, v_kit),
         -- The one line this redefinition exists for.
         compose_archetype = null,
         updated_at    = now()
   where ci.id = p_id;

  v_res := public.reserve_credit(
    v_user, 'swap', 'swapped ' || p_id::text, 'content_item', p_id,
    null, null, null, v_month
  );
  if (v_res ->> 'ok')::boolean then
    perform public.settle_credit((v_res ->> 'reservation_id')::uuid, null, true);
  end if;

  return public.content_item_json(p_id);
end
$function$;

revoke all on function public.swap_content_item(uuid) from public, anon;
grant execute on function public.swap_content_item(uuid) to authenticated, service_role;


-- ============================================================================
-- GUARD RAILS
-- ============================================================================
do $guard$
declare
  v_expected text[];
  v_overlap  text;
  v_key      text;
  v_def      text;
begin
  -- ── 1. The two vocabularies are disjoint, and must stay that way ─────────
  select string_agg(ca.id, ', ') into v_overlap
    from public.content_archetypes ca
   where ca.id in ('statement','question','notes','signature','story','google_post');
  if v_overlap is not null then
    raise exception
      'a layout key collides with a post format: %. Two columns named like "archetype" now share a word, and every screen reading either one is right by accident.',
      v_overlap;
  end if;

  -- ── 2. The patch accepts the layout and still refuses the theme ──────────
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'update_content_item';

  if v_def not like '%''compose_archetype''%' then
    raise exception 'update_content_item does not accept compose_archetype; the review screen could not keep a layout';
  end if;
  if v_def like '%''theme''%' then
    raise exception 'update_content_item accepts theme; a re-themed post composes on the wrong ground';
  end if;

  -- ── 3. A swap drops the layout she kept for the previous content ────────
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'swap_content_item';
  if v_def not like '%compose_archetype = null%' then
    raise exception
      'swap_content_item keeps compose_archetype; her layout for the old content would be applied to the new, and the screen would show a refusal she never caused';
  end if;

  -- ── 4. The json carries every key the screens read ───────────────────────
  -- ⚠ READ FROM THE FUNCTION SOURCE, NOT FROM A CALL. A call needs a row, and
  -- a row needs a kit, a user and an entitlement; a migration has none of them
  -- and `content_item_json` would return no row at all. The source text is
  -- what `create or replace` overwrote, so it is the thing worth pinning.
  v_expected := array[
    'alt_text','archetype','brand_kit_id','caption','category','channel',
    'compose_archetype','created_at','id','image_slot','month_id',
    'on_image_text','posted','posted_at','rationale','register','scheduled_for',
    'status','tags','theme','title','topic','updated_at'
  ];

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'content_item_json';

  foreach v_key in array v_expected
  loop
    if v_def not like '%''' || v_key || '''%' then
      raise exception
        'content_item_json lost the key %. `create or replace` replaces the whole body, and a key dropped by a copy-paste disappears from every screen in silence.',
        v_key;
    end if;
  end loop;
end
$guard$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop index public.content_items_compose_archetype_idx;
--   alter table public.content_items drop column compose_archetype;
--   -- then restore update_content_item and content_item_json from
--   -- 20260921090000_an_item_knows_why_it_was_chosen.sql
