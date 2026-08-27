-- ============================================================================
-- Eklio — rendering limits, enforced in the database
-- ============================================================================
-- The eight approved screens in `design/reference/` are not a style guide, they
-- are a set of hard limits. The reveal is a fixed three-column grid; every
-- small-caps label carries `white-space:nowrap`; the mockup inside each
-- direction card is a fixed 250px tall; the social tiles are fixed squares.
--
-- Copy that overflows those elements does not degrade gracefully. A rationale
-- one character too long wraps to a third line and the three cards stop
-- aligning; a nowrap label that does not fit pushes its card wider and breaks
-- the grid. The failure is visual, it happens after generation, and by then the
-- LLM call has already been paid for.
--
-- So the limits are CHECK constraints, not comments. An overflowing generation
-- is rejected at write time with a constraint violation the frontend can catch
-- and retry, before a user ever sees it. That is the whole reason this belongs
-- in the database rather than in the generator: the generator is the thing that
-- gets it wrong.
--
-- WHERE THE NUMBERS COME FROM
-- ---------------------------
-- Each one is measured off the mockup it constrains. The copy that ships in
-- `design/reference/` sits inside every limit with room to spare — the
-- migration would fail here if it did not, since adding a CHECK validates the
-- rows already in the table.
--
-- ⚠ ONE LIMIT FROM THIS SECTION IS NOT HERE. The calendar `title` <= 34 belongs
-- to the monthly content table, which does not exist yet; it is applied in
-- `20260827105000_monthly_content_calendar.sql`, on the column itself, where it
-- can be a plain CHECK instead of a jsonb probe.
--
-- These constraints sit ALONGSIDE the shape constraints from the previous
-- migration rather than replacing them, so a rejected write names the rule it
-- broke rather than a single catch-all validator.
-- ============================================================================


-- ============================================================================
-- 1. Directions — the three-column reveal
-- ============================================================================
create or replace function public.brand_kit_directions_rendering_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then true  -- shape constraint's job, not ours
    else not exists (
      select 1 from jsonb_array_elements(p) as d
      where
        -- Card title, 22px. Two words is the widest the column takes before
        -- the title wraps under the card's own padding.
        char_length(d.value->>'name') > 20
        or array_length(regexp_split_to_array(btrim(d.value->>'name'), '\s+'), 1) not between 1 and 2

        -- The card reserves exactly two lines for the rationale at 13px in a
        -- 1312px/3 column. 96 characters push it to three and the three cards
        -- stop aligning. The lower bound is editorial rather than geometric: a
        -- rationale under 60 characters is a label, and the card looks empty.
        or char_length(d.value->>'rationale') not between 60 and 95

        -- Rendered at 27px inside the 250px-tall browser mockup, over the
        -- subhead and a three-line paragraph block.
        or char_length(d.value->'hero'->>'headline') > 46
        or char_length(d.value->'hero'->>'subhead')  > 60

        -- Small-caps keyword line, white-space:nowrap, joined with ' · '.
        or exists (
          select 1 from jsonb_array_elements_text(d.value->'tone_keywords') as k
           where k.value !~ '^\S+$'
        )
        or char_length(
             (select string_agg(k.value, ' · ')
                from jsonb_array_elements_text(d.value->'tone_keywords') as k)
           ) > 32
    )
  end
$$;

-- The three directions have to be genuinely different, not three tints of one
-- idea. Typography is the one axis where sameness is unmistakable on screen and
-- checkable in SQL: three cards in the same heading face read as one direction
-- shown three times, and the reveal stops being a choice.
create or replace function public.brand_kit_directions_contrasted(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then true
    else (
      select count(distinct d.value->'typography'->>'heading_font')
        from jsonb_array_elements(p) d
    ) = jsonb_array_length(p)
  end
$$;

alter table public.brand_kits drop constraint if exists brand_kits_directions_rendering_check;
alter table public.brand_kits
  add constraint brand_kits_directions_rendering_check
  check (public.brand_kit_directions_rendering_valid(directions));

alter table public.brand_kits drop constraint if exists brand_kits_directions_contrast_check;
alter table public.brand_kits
  add constraint brand_kits_directions_contrast_check
  check (public.brand_kit_directions_contrasted(directions));


-- ============================================================================
-- 2. Social templates — fixed square tiles
-- ============================================================================
-- Positional, because the shape constraint already pins each slot to a layout:
-- index 0 statement, 1 question, 2 notes, 3 signature.
--
-- The statement and question tiles set their headline at 27-30px inside a
-- 220px square, bottom-aligned — 34 characters is three lines there, and a
-- fourth line collides with the top edge.
--
-- The notes tile is different: its headline is not body copy but the
-- small-caps label at the top ("NOTES ON BURNOUT"), at 13px with 0.14em
-- letter-spacing, above three body lines. 20 characters is the width of the
-- tile at that tracking.
--
-- The signature story has no limit here: it renders `practitioner_line`, not
-- the headline, and its own copy is a name.
create or replace function public.brand_kit_social_templates_rendering_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then true
    else coalesce(char_length(p->0->>'headline'), 0) <= 34
     and coalesce(char_length(p->1->>'headline'), 0) <= 34
     and coalesce(char_length(p->2->>'headline'), 0) <= 20
  end
$$;

alter table public.brand_kits drop constraint if exists brand_kits_social_templates_rendering_check;
alter table public.brand_kits
  add constraint brand_kits_social_templates_rendering_check
  check (public.brand_kit_social_templates_rendering_valid(social_templates));


-- ============================================================================
-- 3. Guard rail — the approved screens must satisfy their own limits
-- ============================================================================
-- If the copy that ships in `design/reference/` cannot pass these constraints,
-- the constraints are wrong, not the design. Checked against the exact strings
-- rendered on Screen 4 and Screen 6.

do $$
declare
  reveal jsonb := jsonb_build_array(
    jsonb_build_object(
      'id','quiet_confidence','name','Quiet Confidence',
      'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3','google_fonts_url','https://fonts.googleapis.com/css2?x&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','a','tone_keywords', jsonb_build_array('composed','credible','unhurried')),
    jsonb_build_object(
      'id','warm_welcome','name','Warm Welcome',
      'rationale','Warmth without softness. It says the first call will be easier than they think.',
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?x&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','a','tone_keywords', jsonb_build_array('steady','plainspoken','warm')),
    jsonb_build_object(
      'id','modern_calm','name','Modern Calm',
      'rationale','Structure signals a plan. For the client who needs to see how the work goes.',
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','https://fonts.googleapis.com/css2?x&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Therapy with a plan you can actually see.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','a','tone_keywords', jsonb_build_array('clear','structured','direct'))
  );
  tiles jsonb := jsonb_build_array(
    jsonb_build_object('id','1','type','post','layout','statement','headline','Rest is not a reward.','body',null,'palette_role','primary','typography_role','heading'),
    jsonb_build_object('id','2','type','post','layout','question','headline','What is your anxiety protecting?','body',null,'palette_role','light','typography_role','heading'),
    jsonb_build_object('id','3','type','post','layout','notes','headline','NOTES ON BURNOUT','body','...','palette_role','secondary','typography_role','body'),
    jsonb_build_object('id','4','type','story','layout','signature','headline','Elm & Ember','body',null,'palette_role','light','typography_role','heading')
  );
begin
  if not public.brand_kit_directions_shape_valid(reveal) then
    raise exception 'rendering_constraints: the approved Screen 4 reveal fails the shape constraint.';
  end if;
  if not public.brand_kit_directions_rendering_valid(reveal) then
    raise exception 'rendering_constraints: the approved Screen 4 copy fails its own length limits. The limits are wrong, not the design.';
  end if;
  if not public.brand_kit_directions_contrasted(reveal) then
    raise exception 'rendering_constraints: the approved Screen 4 reveal repeats a heading font.';
  end if;
  if not public.brand_kit_social_templates_shape_valid(tiles) then
    raise exception 'rendering_constraints: the approved Screen 6 tiles fail the shape constraint.';
  end if;
  if not public.brand_kit_social_templates_rendering_valid(tiles) then
    raise exception 'rendering_constraints: the approved Screen 6 copy fails its own length limits.';
  end if;

  -- and the limits have to actually bite
  if public.brand_kit_directions_rendering_valid(
       jsonb_set(reveal, '{0,name}', '"A Name That Is Far Too Long"'::jsonb)) then
    raise exception 'rendering_constraints: a 27-character direction name was accepted.';
  end if;
  if public.brand_kit_directions_contrasted(
       jsonb_set(reveal, '{2,typography,heading_font}', '"Fraunces"'::jsonb)) then
    raise exception 'rendering_constraints: a repeated heading font was accepted.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.brand_kits
--     drop constraint if exists brand_kits_social_templates_rendering_check,
--     drop constraint if exists brand_kits_directions_contrast_check,
--     drop constraint if exists brand_kits_directions_rendering_check;
--   drop function if exists public.brand_kit_social_templates_rendering_valid(jsonb);
--   drop function if exists public.brand_kit_directions_contrasted(jsonb);
--   drop function if exists public.brand_kit_directions_rendering_valid(jsonb);
