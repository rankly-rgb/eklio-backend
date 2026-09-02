-- ============================================================================
-- Eklio — the site spec hot path: turning JIT off where it only costs
-- ============================================================================
-- Follows `20260829106000_site_spec_actions.sql`.
--
-- WHAT WAS MEASURED, AND WHY IT IS NOT WHAT IT LOOKED LIKE
-- --------------------------------------------------------
-- The product spec holds `PATCH /brand-kits/:id/site-spec` to 150 ms. Measured
-- on a seeded spec, it took **530 ms**, and `GET` took 265 ms. None of it was
-- the SQL:
--
--   site_spec_preview_model    0.8 ms
--   site_spec_contrast         6.4 ms
--   site_spec_diff             0.6 ms
--   site_spec_copy_blocks    253   ms   <-- 1.4 ms with jit = off
--
-- `EXPLAIN ANALYZE` put the whole 300 ms inside the startup of a single
-- `Function Scan` node over eighteen rows. It was **JIT compilation**.
--
-- These queries walk jsonb: `jsonb_array_elements` nested three deep, a lateral
-- per section, a `CASE` per field. The planner costs that by counting
-- expression nodes, and the estimate sails past `jit_above_cost` (100000 by
-- default) — so Postgres compiles the expression tree with LLVM, spends three
-- to four hundred milliseconds doing it, and then executes sixty rows. The cost
-- model is not wrong about the shape of the query; it is wrong about the number
-- of rows the shape will ever see, and here that number is fixed by the product
-- at four pages and a couple of dozen sections.
--
-- JIT pays for itself over millions of rows. There is no version of this
-- feature that has millions of rows: one spec, four pages, eleven section
-- types. So it is turned off, per function, and never at the database level.
--
-- ⚠ WHY PER FUNCTION AND NOT IN THE SERVER CONFIG. `jit` and `jit_above_cost`
-- are cluster settings on a hosted project this repo does not own, and turning
-- JIT off everywhere would be this feature making a decision for every other
-- query in the database — including the analytical ones it might genuinely
-- help. A `SET` clause on a function is stored in the catalog, travels in this
-- migration, applies for the duration of that call including everything it
-- calls, and is restored on exit.
--
-- ⚠ SIDE EFFECT WORTH KNOWING: a SQL function carrying a `SET` clause can no
-- longer be inlined into its caller's query. Every function below already
-- carried `set search_path = ''`, so none of them was inlinable to begin with
-- and nothing changes. The small helpers called in tight loops —
-- `site_spec_render_field`, `site_spec_section_fields`,
-- `site_spec_relative_luminance` — are deliberately NOT touched: they are
-- cheap, they are called per field, and per-call GUC handling would cost more
-- than it saves.
-- ============================================================================


-- ============================================================================
-- 1. The entry points the frontend calls
-- ============================================================================
-- Setting it here covers everything each one calls beneath it, which is why
-- the list is short rather than exhaustive.

alter function public.site_spec_get(uuid)                  set jit = 'off';
alter function public.site_spec_patch(uuid, jsonb)         set jit = 'off';
alter function public.site_spec_reset(uuid, text)          set jit = 'off';
alter function public.site_spec_set_target(uuid, text)     set jit = 'off';
alter function public.site_spec_fix_contrast(uuid, text)   set jit = 'off';
alter function public.site_output_mark_copied(uuid)        set jit = 'off';
alter function public.site_output_get(uuid, text, text)    set jit = 'off';
alter function public.site_catalog()                       set jit = 'off';

-- The cache refresh runs inside every write, including the seeding that happens
-- in the AFTER trigger on direction selection — which is on the path of an
-- endpoint that already exists and must not get slower.
alter function public.refresh_brand_kit_site_prompt()      set jit = 'off';


-- ============================================================================
-- 2. The renderers, for callers that reach them directly
-- ============================================================================
-- The entry points above already cover the product's paths. These carry it in
-- their own right so that a direct call — a report, a correction run by hand
-- with `service_role`, a future endpoint — does not silently pay 300 ms.

alter function public.site_spec_output(jsonb, text)             set jit = 'off';
alter function public.site_spec_output_prompt(jsonb)            set jit = 'off';
alter function public.site_spec_output_setup_sheet(jsonb, text) set jit = 'off';
alter function public.site_spec_copy_blocks(jsonb)              set jit = 'off';
alter function public.site_spec_structure_lines(jsonb)          set jit = 'off';
alter function public.site_spec_envelope(jsonb)                 set jit = 'off';
alter function public.site_spec_preview_model(jsonb)            set jit = 'off';
alter function public.site_spec_contrast(jsonb)                 set jit = 'off';


-- ============================================================================
-- 3. Guard rails
-- ============================================================================
-- ⚠ These settings live in `pg_proc.proconfig`, which a later
-- `create or replace function` **silently discards** unless it repeats the SET
-- clause. That is the failure mode this assertion exists to catch: the symptom
-- is not an error, it is an autosave that quietly goes back to half a second.
-- Any migration that replaces one of these functions must carry
-- `set jit = 'off'` in its body, and this block will say so if it does not.

do $$
declare
  f     text;
  fns   text[] := array[
    'public.site_spec_get(uuid)',
    'public.site_spec_patch(uuid, jsonb)',
    'public.site_spec_reset(uuid, text)',
    'public.site_spec_set_target(uuid, text)',
    'public.site_spec_fix_contrast(uuid, text)',
    'public.site_output_mark_copied(uuid)',
    'public.site_output_get(uuid, text, text)',
    'public.site_catalog()',
    'public.refresh_brand_kit_site_prompt()',
    'public.site_spec_output(jsonb, text)',
    'public.site_spec_output_prompt(jsonb)',
    'public.site_spec_output_setup_sheet(jsonb, text)',
    'public.site_spec_copy_blocks(jsonb)',
    'public.site_spec_structure_lines(jsonb)',
    'public.site_spec_envelope(jsonb)',
    'public.site_spec_preview_model(jsonb)',
    'public.site_spec_contrast(jsonb)'
  ];
begin
  foreach f in array fns loop
    if not exists (
      select 1 from pg_proc p
       where p.oid = f::regprocedure
         and coalesce(p.proconfig, '{}') @> array['jit=off']
    ) then
      raise exception
        'site_spec_hot_path: % has lost its `set jit = off`. A create-or-replace drops proconfig unless it repeats the SET clause, and the symptom is a slow autosave, not an error.', f;
    end if;
  end loop;

  -- And the search_path hardening every function in this repo carries must
  -- have survived the ALTERs above, which rewrite proconfig as a whole.
  foreach f in array fns loop
    if not exists (
      select 1 from pg_proc p
       where p.oid = f::regprocedure
         and coalesce(p.proconfig, '{}') @> array['search_path=""']
    ) then
      raise exception 'site_spec_hot_path: % lost its empty search_path.', f;
    end if;
  end loop;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Reverting restores the 300 ms, so revert this only together with whatever
-- replaced the renderers.
--
--   alter function public.site_spec_contrast(jsonb)                 reset jit;
--   alter function public.site_spec_preview_model(jsonb)            reset jit;
--   alter function public.site_spec_envelope(jsonb)                 reset jit;
--   alter function public.site_spec_structure_lines(jsonb)          reset jit;
--   alter function public.site_spec_copy_blocks(jsonb)              reset jit;
--   alter function public.site_spec_output_setup_sheet(jsonb, text) reset jit;
--   alter function public.site_spec_output_prompt(jsonb)            reset jit;
--   alter function public.site_spec_output(jsonb, text)             reset jit;
--   alter function public.refresh_brand_kit_site_prompt()           reset jit;
--   alter function public.site_catalog()                            reset jit;
--   alter function public.site_output_get(uuid, text, text)         reset jit;
--   alter function public.site_output_mark_copied(uuid)             reset jit;
--   alter function public.site_spec_fix_contrast(uuid, text)        reset jit;
--   alter function public.site_spec_set_target(uuid, text)          reset jit;
--   alter function public.site_spec_reset(uuid, text)               reset jit;
--   alter function public.site_spec_patch(uuid, jsonb)              reset jit;
--   alter function public.site_spec_get(uuid)                       reset jit;
