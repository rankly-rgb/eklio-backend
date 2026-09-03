-- ============================================================================
-- Eklio — tenancy layer, lot 1: assert_tenancy_invariants + push gate
-- ============================================================================
-- Runs at the end of this migration (the terminal `select` below) and fails
-- the push if any of the five invariants does not hold. service_role only —
-- not a client entry point, and not meant to be called outside a migration.
--
-- ⚠ THREE CAVEATS ON THE ALLOWLISTS BELOW, all flagged in the Phase 1
-- checkpoint report. Unlike the other two, invariant 1's allowlist WAS
-- verified — by actually applying every migration in this repo (including
-- this one) against a local Postgres and running the query by hand; see the
-- checkpoint report for how. Invariants 2 and 3 still need the human's
-- confirmation against the LIVE project (no supabase CLI in this session, so
-- those two lists are derived by grepping migration files, not by querying a
-- database that has this repo's full history — including the local one built
-- for this check, which starts from a stub `auth`/`storage` schema, not a
-- real Supabase project):
--
--   Invariant 1 (RLS-enabled table with no policy) — five pre-existing
--   tables (app_settings, banned_phrases, comp_grants, stripe_events,
--   usp_stopwords) are RLS-enabled with zero policies AND have `revoke all
--   ... from anon, authenticated` — confirmed, not assumed, by the query
--   above returning exactly these five against the fully-applied schema.
--   This is the repo's own deliberate "service_role only" pattern, not a gap.
--
--   Invariant 2 (anon table SELECT) — the brief's "expected: catalog tables
--   only" does not match the schema. Only 5 tables in the whole repo have an
--   explicit `revoke ... from anon` on SELECT (stripe_events, banned_phrases,
--   usp_stopwords, app_settings, comp_grants); every other table — every
--   application table this lot rewrote included — still carries the raw
--   default-privilege SELECT grant Postgres/Supabase hands out at CREATE
--   TABLE time, safe only because RLS is the actual gate (see
--   20260901190000_codify_rls_auto_enable.sql's own note: "RLS is the only
--   gate"). The allowlist below is today's REAL baseline (18 reference
--   catalogs + 17 application tables not explicitly revoked), not a
--   "catalogs only" list. Revoking the stale default privilege repo-wide
--   would be a real hardening pass, but it touches ~17 tables this chantier
--   was not asked to touch — out of scope here, flagged for a follow-up lot.
--
--   Invariant 3 (anon function EXECUTE) — 104 pre-existing functions are
--   still anon-executable (every function ever created in public, minus the
--   28 explicitly revoked across 20260830062227, 20260830062241,
--   20260901182419, and 20260902090000). Spot-checked one
--   (site_spec_patch): SECURITY DEFINER but internally checks
--   `auth.uid() is null` before writing, so it is callable-but-inert for
--   anon — the same "published but harmless" class as the 13 trigger
--   functions the September 2 audit already named. The rest were NOT
--   individually audited. Several read as write RPCs by name
--   (direction_assets_claim/mark_ready/mark_failed, grant_plan_allowance,
--   record_purchase_status_event, ensure_month_skeleton,
--   usp_fingerprint_confirm, site_spec_reset/set_target/fix_contrast,
--   site_output_mark_copied) and are exactly the surface the September 2
--   migration named and deliberately left ("closing the rest is a separate
--   lot, not one line more here") — restated here, not closed here.
-- ============================================================================

create or replace function public.assert_tenancy_invariants()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad_table       text;
  v_bad_grant_table text;
  v_bad_func        text;
  v_null_org        bigint;
  v_bad_owner_count bigint;
begin
  -- 1. Every RLS-enabled table in public has at least one policy — the
  -- table-enumeration test. A table with RLS on and zero policies returns
  -- zero rows, no error, to every role but the owner and service_role.
  --
  -- ⚠ Five pre-existing tables are a DELIBERATE exception, confirmed by
  -- actually running this exact query against the applied schema (see the
  -- checkpoint report): app_settings, banned_phrases, comp_grants,
  -- stripe_events, usp_stopwords. Each is RLS-enabled with zero policies AND
  -- has `revoke all ... from anon, authenticated` — the repo's own
  -- "belt-and-suspenders, service_role only" pattern (see stripe_events in
  -- 20260825160000_lot4_billing.sql). This is the correct, intended state
  -- for those five, not a violation — allowlisted, not fixed.
  select c.relname into v_bad_table
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relrowsecurity
     and c.relname not in ('app_settings', 'banned_phrases', 'comp_grants', 'stripe_events', 'usp_stopwords')
     and not exists (
       select 1 from pg_policies pol
        where pol.schemaname = 'public' and pol.tablename = c.relname
     )
   limit 1;

  if v_bad_table is not null then
    raise exception 'assert_tenancy_invariants: table % has RLS enabled and no policy', v_bad_table;
  end if;

  -- 2. No table grants SELECT to anon outside the explicit allowlist (today's
  -- real baseline — see the caveat above, not "catalogs only").
  select c.relname into v_bad_grant_table
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and has_table_privilege('anon', c.oid, 'select')
     and c.relname not in (
       -- 18 reference catalogs
       'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
       'problem_cards', 'gain_cards', 'ethics_rules', 'license_types', 'specialties',
       'site_goals', 'primary_actions', 'section_types', 'builder_targets',
       'site_output_templates', 'session_style_cards', 'not_a_fit_cards',
       'modality_cards', 'modality_prominence_options',
       -- 17 application tables not explicitly revoked from anon (RLS-gated)
       'profiles', 'projects', 'project_briefs', 'directions', 'generation_credits',
       'brand_kits', 'subscriptions', 'purchases', 'monthly_presence_content',
       'site_specs', 'launch_checklist_items', 'direction_assets',
       'direction_asset_daily_spend', 'plan_grants', 'plans',
       'purchase_status_events', 'usp_fingerprints'
     )
   limit 1;

  if v_bad_grant_table is not null then
    raise exception 'assert_tenancy_invariants: table % grants SELECT to anon outside the allowlist', v_bad_grant_table;
  end if;

  -- 3. No function grants EXECUTE to anon outside the explicit allowlist —
  -- today's real baseline (see the caveat above) plus preview_org_invite,
  -- the one new function this lot opens to anon.
  --
  -- ⚠ Extension-owned functions (pg_trgm's, pgcrypto's, citext's — whichever
  -- schema they actually install into on this project) are excluded via the
  -- pg_depend check below, NOT by name. Found by actually applying this
  -- migration against a local Postgres: pgcrypto/citext/pg_trgm installed
  -- into `public` there (a plain `create extension` with no schema clause,
  -- same as every `create extension` in this repo), which put ~90 extension
  -- support functions (digest, gen_random_bytes, citext_eq, gin_trgm_*, …) in
  -- `public.pg_proc`, anon-executable by Postgres's own extension-install
  -- default — none of them authored in any migration file, so the earlier,
  -- purely grep-derived function list could not have caught them. A
  -- name-based allowlist would have needed ~90 more entries and would still
  -- have been wrong if this project's extensions live in a different schema
  -- (e.g. `extensions`, Supabase's usual default) — excluding by pg_depend
  -- is correct either way, because it asks "does this function belong to an
  -- extension" instead of guessing where that extension lives.
  select p.proname into v_bad_func
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid and d.deptype = 'e'
     )
     and p.proname not in (
       'preview_org_invite',
       -- can_access_project / can_access_brand_kit: MUST be anon-executable,
       -- not merely allowlisted — they are named directly in RLS policies on
       -- tables anon still has raw SELECT privilege on (the repo's RLS-only
       -- convention), and Postgres requires the querying role to hold
       -- EXECUTE on every function a policy calls or evaluating the policy
       -- itself raises `permission denied for function`, instead of
       -- silently filtering to zero rows. Found by actually running an anon
       -- query against `projects` — see the checkpoint report. Both return
       -- false on auth.uid() is null, so a direct RPC call learns nothing.
       'can_access_project', 'can_access_brand_kit',
       'brand_kit_direction_contrast', 'brand_kit_direction_palette_hash',
       'brand_kit_directions_contrasted', 'brand_kit_directions_rendering_valid',
       'brand_kit_directions_shape_valid', 'brand_kit_entitling_statuses',
       'brand_kit_ethics_check_valid', 'brand_kit_hero_valid', 'brand_kit_palette_valid',
       'brand_kit_selection_valid', 'brand_kit_social_templates_rendering_valid',
       'brand_kit_social_templates_shape_valid', 'brand_kit_voice_guide_valid',
       'brief_completed_steps_renumber_down', 'brief_completed_steps_renumber_up',
       'brief_preview', 'brief_progress_step_renumber_up', 'brief_step_renumber_down',
       'brief_step_renumber_up', 'calendar_summary', 'direction_assets_claim',
       'direction_assets_mark_failed', 'direction_assets_mark_ready', 'direction_limits',
       'ensure_month_skeleton', 'grant_plan_allowance', 'project_briefs_data_valid',
       'project_briefs_tone_cards_valid', 'project_briefs_usp_options_valid',
       'project_briefs_validate_how_you_work_refs', 'project_briefs_validate_selected_usp_id',
       'record_purchase_status_event', 'section_type_fields_valid', 'site_catalog',
       'site_output_catalog_version', 'site_output_fill', 'site_output_fragments',
       'site_output_get', 'site_output_mark_copied', 'site_output_step_title_count',
       'site_spec_accent_try', 'site_spec_clamp_note', 'site_spec_constraint_lines',
       'site_spec_contrast', 'site_spec_contrast_level', 'site_spec_contrast_ratio',
       'site_spec_copy_blocks', 'site_spec_credential_line', 'site_spec_cta_ink',
       'site_spec_cta_target_url_valid', 'site_spec_curated_accent', 'site_spec_default_pages',
       'site_spec_delta_e', 'site_spec_derive_accent', 'site_spec_diff', 'site_spec_envelope',
       'site_spec_error', 'site_spec_first_overlong_field', 'site_spec_fix_contrast',
       'site_spec_get', 'site_spec_hero_lengths_valid', 'site_spec_hero_valid',
       'site_spec_hex_to_hsl', 'site_spec_hsl_to_hex', 'site_spec_hue_tolerance',
       'site_spec_identity_lines', 'site_spec_lab', 'site_spec_limits', 'site_spec_output',
       'site_spec_output_prompt', 'site_spec_output_render', 'site_spec_output_setup_sheet',
       'site_spec_page_keys', 'site_spec_pages_copy', 'site_spec_pages_lengths_valid',
       'site_spec_pages_skeleton', 'site_spec_pages_valid', 'site_spec_palette_role',
       'site_spec_patch', 'site_spec_patchable_keys', 'site_spec_practice_detail_keys',
       'site_spec_practice_details_valid', 'site_spec_preview_model',
       'site_spec_relative_luminance', 'site_spec_render_field',
       'site_spec_render_field_or_null', 'site_spec_reset', 'site_spec_retired_clamp_keys',
       'site_spec_section_fields', 'site_spec_section_types', 'site_spec_seed_clamped_valid',
       'site_spec_set_target', 'site_spec_structure_lines', 'site_spec_suggest_hex',
       'site_spec_text_variant', 'site_spec_token_lines', 'site_spec_variant_of',
       'site_spec_voice_guide', 'site_spec_voice_lines', 'truncate_on_word_boundary',
       'usp_banned_phrases_check', 'usp_check_distinct', 'usp_fingerprint_confirm',
       'usp_normalize'
     )
   limit 1;

  if v_bad_func is not null then
    raise exception 'assert_tenancy_invariants: function % is executable by anon outside the allowlist', v_bad_func;
  end if;

  -- 4. Every project has an organization.
  select count(*) into v_null_org from public.projects where organization_id is null;
  if v_null_org > 0 then
    raise exception 'assert_tenancy_invariants: % project(s) have a null organization_id', v_null_org;
  end if;

  -- 5. Every organization has exactly one active owner.
  select count(*) into v_bad_owner_count
    from public.organizations o
   where (
     select count(*) from public.organization_members m
      where m.organization_id = o.id and m.role = 'owner' and m.status = 'active'
   ) <> 1;

  if v_bad_owner_count > 0 then
    raise exception 'assert_tenancy_invariants: % organization(s) do not have exactly one active owner', v_bad_owner_count;
  end if;
end;
$$;

comment on function public.assert_tenancy_invariants() is
  'Push-time gate: raises on the first violated tenancy invariant (RLS-enabled table with no policy, anon SELECT/EXECUTE outside the allowlist, a project with no organization, an organization without exactly one active owner). Run by the terminal select in this migration; not a client entry point.';

revoke execute on function public.assert_tenancy_invariants() from public, anon, authenticated;
grant  execute on function public.assert_tenancy_invariants() to service_role;

select public.assert_tenancy_invariants();
