-- ============================================================================
-- Eklio — correcting 20260910100415
-- ============================================================================
-- ⚠ WHAT THIS FIXES, SAID PLAINLY. The previous migration added
-- `on_image_text` and `register` to `content_item_json` by REWRITING the
-- function rather than by editing the version that was there. Three things
-- were lost in the retyping, and all three are behaviour, not style:
--
--   1. `stable` was dropped, so the function became VOLATILE. `get_content_month`
--      is `stable` and calls it once per row in three separate places; a
--      volatile callee cannot be inlined and cannot be hoisted, which turns one
--      lateral lookup per item into several.
--   2. The single `left join lateral` became three correlated subqueries over
--      `content_publications` — the same fact fetched three times.
--   3. `posted_at` and `channel` stopped being gated on the LAST event being a
--      publication. The original reads the most recent row and reports its
--      timestamp only `when action = 'published'`; the rewrite hunted for the
--      most recent *published* row regardless of what came after it. So an item
--      published and then UNPUBLISHED would have reported `posted: false` with
--      a `posted_at` still filled in — a contradiction inside one object, and
--      the editor renders the date.
--
-- This restores the original shape verbatim and adds only the two new keys.
-- Kept as its own migration rather than by editing the last one, because that
-- one is already applied: the record of what the database did should not be
-- rewritten after the fact.
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
    -- The editorial shape the generator drew. NOT the archetype: that is the
    -- satori layout. The plan screen groups by this one.
    'register',      ci.register,
    'month_id',      ci.month_id,
    'status',        ci.status,
    'title',         ci.title,
    'caption',       ci.caption,
    -- The line rendered ON the image. Its own text, never a slice of caption.
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
    'channel',       case when last_pub.action = 'published' then last_pub.channel end
  )
  from public.content_items ci
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
-- update_content_item — the same restoration, for its prose
-- ============================================================================
-- The rewrite kept every branch but dropped the two comments that explain WHY
-- the unknown-key check and the gate are written the way they are. In this
-- repo that reasoning is the artefact; a future reader who cannot see why the
-- gate resolves against the POST-patch state is one commit away from breaking
-- the editor's combined save.

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

  -- An unknown key is a caller bug, and silently dropping it would let a
  -- renamed field autosave into nothing for a release before anyone noticed.
  select string_agg(key, ', ') into v_bad
    from jsonb_object_keys(p_patch) as key
   where key not in ('archetype','status','title','caption','alt_text',
                     'tags','category','image_slot','scheduled_for',
                     'on_image_text');
  if v_bad is not null then
    return public.content_error('unknown_field');
  end if;

  /*
   * The gate. Resolved against the state the row will be IN after this patch,
   * not the state it is in now: a single patch can set both `status` and
   * `alt_text`, and checking the stored value would refuse a save that fills
   * them together.
   */
  select case when p_patch ? 'status'   then p_patch ->> 'status'   else ci.status end,
         case when p_patch ? 'alt_text' then p_patch ->> 'alt_text' else ci.alt_text end
    into v_next_state, v_next_alt
    from public.content_items ci
   where ci.id = p_id;

  if v_next_state = 'ready' and coalesce(btrim(v_next_alt), '') = '' then
    return public.content_error('alt_text_required');
  end if;

  update public.content_items ci set
    archetype     = case when p_patch ? 'archetype'  then p_patch ->> 'archetype'  else ci.archetype end,
    status        = case when p_patch ? 'status'     then p_patch ->> 'status'     else ci.status end,
    title         = case when p_patch ? 'title'      then p_patch ->> 'title'      else ci.title end,
    caption       = case when p_patch ? 'caption'    then p_patch ->> 'caption'    else ci.caption end,
    alt_text      = case when p_patch ? 'alt_text'   then p_patch ->> 'alt_text'   else ci.alt_text end,
    category      = case when p_patch ? 'category'   then p_patch ->> 'category'   else ci.category end,
    image_slot    = case when p_patch ? 'image_slot' then p_patch ->> 'image_slot' else ci.image_slot end,
    -- Blanked on the image means "no line", not an empty string rendered as a
    -- zero-height box. `nullif` here so the editor cannot store one.
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


-- ============================================================================
-- Guard rails — each one is a thing that was actually wrong an hour ago
-- ============================================================================
do $$
declare v_def text; v_volatile "char";
begin
  select p.provolatile into v_volatile from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='content_item_json';
  if v_volatile <> 's' then
    raise exception 'content_item_json is not stable (provolatile=%)', v_volatile;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='content_item_json';

  if v_def not like '%left join lateral%' then
    raise exception 'content_item_json reads the publication log more than once';
  end if;

  -- The contradiction: a filled `posted_at` next to `posted: false`.
  if v_def not like '%case when last_pub.action = ''published'' then last_pub.occurred_at end%' then
    raise exception 'content_item_json can report a posted_at for an unpublished item';
  end if;

  if v_def not like '%on_image_text%' or v_def not like '%register%' then
    raise exception 'content_item_json lost a field it was written to carry';
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='update_content_item';
  if v_def not like '%on_image_text%' then
    raise exception 'update_content_item would refuse on_image_text as unknown_field';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   There is nothing to undo here that undoing 20260910100415 would not also
--   undo. Restore both functions from 20260906155600 and 20260910084320.
