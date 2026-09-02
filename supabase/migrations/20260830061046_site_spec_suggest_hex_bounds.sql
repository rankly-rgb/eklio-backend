-- ============================================================================
-- Eklio — the contrast fix stops walking to black and white
-- ============================================================================
-- Follows `20260829110000_site_output_templates.sql`.
--
-- WHAT IT DID, MEASURED — AND THE CHANGE IS NARROWER THAN IT SOUNDS
-- -----------------------------------------------------------------
-- `site_spec_suggest_hex` walked lightness across the full 0.00–1.00 range and
-- returned whichever passing value was closest to hers. Almost always that is a
-- real correction and nothing here touches it: a terracotta on a mid grey still
-- comes back #331D15, the ochre on its own page background still comes back
-- #8F672E.
--
-- The failure is at the ends. When no lightness of her hue reaches the target,
-- the walk kept going until it hit one, and at lightness 0 and 1
-- `site_spec_hsl_to_hex` returns black and white for every hue. Measured, on a
-- hue-30 colour at 0.5 saturation against a `#767676` background:
--
--     unbounded  ->  #040301        (black, whatever her colour was)
--     bounded    ->  NULL
--
-- #040301 passes 4.5:1 and is not her colour. The "keep the hue and chroma,
-- move only the lightness" promise is kept in form and broken in fact, and a
-- one-click Fix button that turns a terracotta into black is worse than no
-- button, because she has to notice it and undo it.
--
-- THE CHANGE
-- ----------
-- The walk is bounded to lightness 0.05–0.95. That excludes only the band where
-- the hue is gone; every correction that was already a correction is unchanged
-- — verified against the unbounded walk before and after.
--
-- ⚠ THIS MAKES `null` A REACHABLE ANSWER AT 4.5:1, WHICH IT WAS NOT BEFORE, and
-- that is the point rather than a side effect. A hue-30 color at 0.5 saturation
-- tops out at 4.25:1 against a `#767676` background across the whole bounded
-- range — there is no correction, and saying so is the honest answer. The
-- earlier note in `20260829102000_site_spec_preview_and_contrast.sql` claiming
-- a fix always exists at 4.5:1 was true only because the walk was allowed to
-- reach the ends; it is no longer true and the test that asserted it is updated
-- with it.
--
-- The loop is bounded by construction and always was: `generate_series` over
-- two integer literals, ninety-one candidates, no iteration and no recursion.
-- Nothing here can fail to terminate.
-- ============================================================================

create or replace function public.site_spec_suggest_hex(
  p_move_hex  text,
  p_fixed_hex text,
  p_target    numeric default 4.5
)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  with base as (select public.site_spec_hex_to_hsl(p_move_hex) as hsl),
  candidates as (
    -- ⚠ 5..95, NOT 0..100. At 0 and 100 `site_spec_hsl_to_hex` returns black
    -- and white for every hue, so those candidates discard the colour instead
    -- of correcting it. Ninety-one candidates, fixed literals: the search is
    -- bounded by construction.
    select public.site_spec_hsl_to_hex((select hsl[1] from base),
                                       (select hsl[2] from base),
                                       g.i::numeric / 100) as hex,
           abs(g.i::numeric / 100 - (select hsl[3] from base)) as distance,
           g.i as steps
      from generate_series(5, 95) as g(i)
  )
  select c.hex
    from candidates c
   where public.site_spec_contrast_ratio(c.hex, p_fixed_hex) >= p_target
   -- closest to her colour first; on a tie the darker one, so the answer is
   -- the same on every call
   order by c.distance, c.steps
   limit 1
$$;

comment on function public.site_spec_suggest_hex(text, text, numeric) is
  'The hex closest to p_move_hex in lightness that reaches p_target against p_fixed_hex, keeping hue and saturation. Bounded to lightness 0.05-0.95: outside that the result is black or white whatever the hue, which is a replacement rather than a correction. NULL when no candidate in range reaches the target.';


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  h    text;
  fix  text;
  hues numeric[] := array[0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330];
  deg  numeric;
  n    int := 0;
begin
  -- ---- it no longer walks into the band where the hue is gone -------------
  foreach h in array array['#808080', '#7F7F7F', '#6E6E6E', '#949494', '#C08A3E', '#3B2C3A'] loop
    fix := public.site_spec_suggest_hex(h, '#808080');
    if fix is not null
       and ((public.site_spec_hex_to_hsl(fix))[3] < 0.05
            or (public.site_spec_hex_to_hsl(fix))[3] > 0.95) then
      raise exception 'site_spec_suggest_hex: % corrected outside the bounded range.', h;
    end if;
  end loop;

  -- and the corrections that were already good are untouched
  if public.site_spec_suggest_hex('#C08A3E', '#F6F2EA') <> '#8F672E' then
    raise exception 'site_spec_suggest_hex: bounding the walk changed a correction that was already right.';
  end if;
  if public.site_spec_suggest_hex('#B4674A', '#8A8A8A') <> '#331D15' then
    raise exception 'site_spec_suggest_hex: bounding the walk changed a correction that was already right.';
  end if;

  -- ---- every correction it does offer actually works ----------------------
  -- Twelve hues around the circle, against the page background of a palette
  -- this product ships.
  foreach deg in array hues loop
    h := public.site_spec_hsl_to_hex(deg, 0.55, 0.62);   -- too light to read on #F3EDE4
    fix := public.site_spec_suggest_hex(h, '#F3EDE4');
    if fix is null then
      raise exception 'site_spec_suggest_hex: hue % got no correction on a light background.', deg;
    end if;
    if public.site_spec_contrast_ratio(fix, '#F3EDE4') < 4.5 then
      raise exception 'site_spec_suggest_hex: the correction for hue % reaches only %:1.',
        deg, public.site_spec_contrast_ratio(fix, '#F3EDE4');
    end if;
    -- ⚠ hue preserved: the fix must not turn a terracotta into a brown-grey
    if abs(((public.site_spec_hex_to_hsl(fix))[1] - deg + 540)::numeric % 360 - 180) > 1 then
      raise exception 'site_spec_suggest_hex: hue % came back as %.',
        deg, (public.site_spec_hex_to_hsl(fix))[1];
    end if;
    n := n + 1;
  end loop;
  if n <> 12 then
    raise exception 'site_spec_suggest_hex: only % hues were exercised.', n;
  end if;

  -- ---- and null is now a real answer at 4.5:1 -----------------------------
  if public.site_spec_suggest_hex(public.site_spec_hsl_to_hex(30, 0.5, 0.5), '#767676') is not null then
    raise exception
      'site_spec_suggest_hex: a pair that cannot reach 4.5:1 inside the bounded range returned a correction anyway.';
  end if;

  -- ---- deterministic ------------------------------------------------------
  if public.site_spec_suggest_hex('#C08A3E', '#F6F2EA')
     is distinct from public.site_spec_suggest_hex('#C08A3E', '#F6F2EA') then
    raise exception 'site_spec_suggest_hex: the correction is not deterministic.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restores the 0..100 walk, which corrects to black and white:
--   create or replace function public.site_spec_suggest_hex(
--     p_move_hex text, p_fixed_hex text, p_target numeric default 4.5)
--   returns text language sql immutable set search_path = '' set jit = 'off' as $fn$
--     with base as (select public.site_spec_hex_to_hsl(p_move_hex) as hsl),
--     candidates as (
--       select public.site_spec_hsl_to_hex((select hsl[1] from base),
--                                          (select hsl[2] from base),
--                                          g.i::numeric / 100) as hex,
--              abs(g.i::numeric / 100 - (select hsl[3] from base)) as distance,
--              g.i as steps
--         from generate_series(0, 100) as g(i))
--     select c.hex from candidates c
--      where public.site_spec_contrast_ratio(c.hex, p_fixed_hex) >= p_target
--      order by c.distance, c.steps limit 1
--   $fn$;
