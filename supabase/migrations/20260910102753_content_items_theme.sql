-- ============================================================================
-- Eklio — a post belongs to one of the month's three themes
-- ============================================================================
-- ⚠ AND NOT TO `category`. The plan screen's first draft grouped posts by
-- `content_items.category`, because it was there and it was free text. That is
-- the `min_tier` mistake again: two vocabularies that agree only because both
-- are currently permissive.
--
-- `category` is HERS. It is an editable 40-character field on the item editor,
-- and she may rename it to anything at any time. A post whose category she
-- renamed would silently leave its theme group on the review screen — no
-- error, no empty state, just a post that stopped being in the month.
--
-- So the theme is its own column, and it is validated against the month it
-- claims to belong to. An array cannot carry a foreign key, so the check is a
-- trigger — the same shape `content_preferences.accepted_registers` already
-- uses, for the same reason.
--
-- Null is legal and meaningful: every item she wrote herself has no theme, and
-- the review screen shows those separately rather than inventing one.
-- ============================================================================

alter table public.content_items
  add column if not exists theme text;

alter table public.content_items
  drop constraint if exists content_items_theme_check;
alter table public.content_items
  add constraint content_items_theme_check
  check (theme is null or char_length(theme) between 1 and 80);

comment on column public.content_items.theme is
  'Which of its month''s themes this post belongs to. NOT `category`, which is hers to rename. Null on anything she wrote herself. Validated against content_months.themes by trigger, because an array element cannot carry a foreign key.';


-- ---------------------------------------------------------------------------
-- The trigger
-- ---------------------------------------------------------------------------
create or replace function public.content_items_theme_belongs_to_month()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_themes text[];
begin
  if new.theme is null then
    return new;
  end if;

  -- A theme without a month has nothing to be checked against. Refused rather
  -- than allowed: it would render in no group on the review screen, which is
  -- the exact failure this trigger exists to prevent.
  if new.month_id is null then
    raise exception 'content_items.theme is set but month_id is null; a theme belongs to a month.'
      using errcode = 'check_violation';
  end if;

  select cm.themes into v_themes
    from public.content_months cm
   where cm.id = new.month_id;

  if not (new.theme = any(v_themes)) then
    raise exception 'content_items.theme % is not one of its month''s themes.', new.theme
      using errcode = 'check_violation';
  end if;

  return new;
end
$function$;

drop trigger if exists content_items_theme_check_trg on public.content_items;
create trigger content_items_theme_check_trg
  before insert or update of theme, month_id on public.content_items
  for each row execute function public.content_items_theme_belongs_to_month();


-- ---------------------------------------------------------------------------
-- The RPCs learn about it
-- ---------------------------------------------------------------------------
-- ⚠ `theme` IS NOT IN THE PATCH ALLOW-LIST. She does not move a post between
-- themes from the editor: the themes are the month's, the ground is drawn per
-- theme, and a post re-themed after its ground exists would compose on a
-- photograph about something else. It is written once, by the generator.
-- `category` remains hers, and remains free text.

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
-- Guard rails
-- ============================================================================
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='content_item_json';
  if v_def not like '%''theme''%' then
    raise exception 'theme: the review screen could never read it back';
  end if;

  -- The overload this migration exists to prevent must stay prevented.
  if v_def not like '%''category''%' then
    raise exception 'theme: category disappeared; it is hers and it is separate';
  end if;

  -- `theme` must NOT be patchable from the editor.
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='update_content_item';
  if v_def like '%''theme''%' then
    raise exception 'theme: update_content_item accepts it; a re-themed post composes on the wrong ground';
  end if;

  if not exists (
    select 1 from pg_trigger where tgname = 'content_items_theme_check_trg'
      and not tgisinternal
  ) then
    raise exception 'theme: the trigger is missing, so an unknown theme would render in no group';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger content_items_theme_check_trg on public.content_items;
--   drop function public.content_items_theme_belongs_to_month();
--   alter table public.content_items drop column theme;
--   restore content_item_json from 20260910100758.
