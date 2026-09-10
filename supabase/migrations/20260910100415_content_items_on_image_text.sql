-- ============================================================================
-- Eklio — a post has TWO texts, written separately
-- ============================================================================
-- ⚠ NEVER ONE SLICED INTO TWO. Cutting the opening off a caption to fill the
-- image gives a sentence fragment on the picture and a duplicated first line
-- underneath it — the reader sees the same words twice, once broken.
--
--   on_image_text   what she reads IN THE GRID, in her own typeface. Carries
--                   the register. Six to forty words.
--   caption         the longer thought underneath, up to Instagram's 2200.
--
-- ── THE CAP, AND WHY IT IS 480 AND NOT 144 ───────────────────────────────
--
-- The measured floors differ per layout (statement 144, question 168,
-- signature 195, story 431, notes 472 — see
-- scripts/content/measure-archetype-capacity.ts in the frontend repo). A single
-- column cannot carry five different caps, so this one is sized to the LARGEST
-- floor with a little air: 480.
--
-- The per-archetype floor is enforced by the GENERATOR, which knows which
-- layout it chose. Putting 144 here instead would forbid a perfectly legal
-- `notes` line; putting no cap would let an unbounded string into a prompt and
-- into a satori box that silently overflows.
--
-- ⚠ FLOOR, NOT HER OWN PAIRING'S CAPACITY. The generator writes to the
-- smallest capacity across all six typefaces, never to the one she happens to
-- use today. A few characters cheaper, and changing her typeface later can
-- never overflow a post that already exists.
--
-- Null for every item she wrote herself: this is a generated field, and an
-- empty one is "she has not been given a line", not "the line is blank".
-- ============================================================================

alter table public.content_items
  add column if not exists on_image_text text;

alter table public.content_items
  drop constraint if exists content_items_on_image_text_check;
alter table public.content_items
  add constraint content_items_on_image_text_check
  check (on_image_text is null or char_length(on_image_text) <= 480);

comment on column public.content_items.on_image_text is
  'The line rendered ON the image, in her typeface, carrying the register. NOT a slice of caption -- the two are written separately. Capped at 480 (the largest archetype floor); the per-archetype floor is enforced by the generator, which knows which layout it chose.';


-- ============================================================================
-- The alt-text gate learns about it
-- ============================================================================
-- `update_content_item` refuses `ready` without alt text. It must also accept
-- the new field, or the editor's save would come back `unknown_field` the
-- first time she touches a generated line.
--
-- ⚠ THE BODY BELOW WAS RETYPED FROM MEMORY AND LOST ITS COMMENTS; the very
-- next migration (20260910100758) restores them, along with three real
-- regressions the same retyping introduced into `content_item_json`. Read that
-- one before trusting anything in this section. Left standing rather than
-- rewritten, because this file is the record of what the database was actually
-- asked to do.

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
                     'on_image_text');
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

  update public.content_items ci set
    archetype     = case when p_patch ? 'archetype'  then p_patch ->> 'archetype'  else ci.archetype end,
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


-- ============================================================================
-- And so does the item's json, or the editor cannot render what it saved
-- ============================================================================
-- ⚠ SUPERSEDED BY 20260910100758. The version below dropped `stable`, replaced
-- the lateral join with three subqueries, and let a `posted_at` survive an
-- unpublish. Do not copy it.
create or replace function public.content_item_json(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select jsonb_build_object(
    'id',            ci.id,
    'brand_kit_id',  ci.brand_kit_id,
    'archetype',     ci.archetype,
    'register',      ci.register,
    'month_id',      ci.month_id,
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
    'posted',        coalesce((
                       select cp.action = 'published'
                         from public.content_publications cp
                        where cp.content_item_id = ci.id
                        order by cp.occurred_at desc, cp.id desc
                        limit 1), false),
    'posted_at',     (select cp.occurred_at from public.content_publications cp
                       where cp.content_item_id = ci.id and cp.action = 'published'
                       order by cp.occurred_at desc, cp.id desc limit 1),
    'channel',       (select cp.channel from public.content_publications cp
                       where cp.content_item_id = ci.id
                       order by cp.occurred_at desc, cp.id desc limit 1)
  )
  from public.content_items ci
  where ci.id = p_id;
$function$;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_def text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='content_items'
       and column_name='on_image_text'
  ) then
    raise exception 'on_image_text: the column is missing';
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='update_content_item';
  if v_def not like '%on_image_text%' then
    raise exception 'on_image_text: update_content_item would refuse it as unknown_field';
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='content_item_json';
  if v_def not like '%on_image_text%' then
    raise exception 'on_image_text: the editor could never read back what it saved';
  end if;

  if v_def not like '%register%' then
    raise exception 'on_image_text: content_item_json lost the register';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Restore content_item_json and update_content_item from 20260910084320,
--   then: alter table public.content_items drop column on_image_text;
