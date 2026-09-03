-- ============================================================================
-- Eklio — the launch checklist becomes "Your first week" (Lot 6)
-- ============================================================================
-- POST_PURCHASE_BRIEF.md's Lot 6 asks for a NEW table `launch_steps`, RPCs
-- `get_launch_progress`/`set_launch_step`, and seven exact steps. That table
-- already exists — under a different name, `launch_checklist_items`
-- (20260827104000_launch_checklist_items.sql), fully RLS'd, idempotently
-- seeded, backfilled, and guard-railed. Building a second, parallel system
-- would have shipped two checklists nobody asked for; this migration EXTENDS
-- the real one in place instead, additively:
--
--   - two new keys the six-item version didn't have (`social_setup`,
--     `booking_link`) — the CHECK constraint is widened, never narrowed;
--   - the four keys that already map to one of the brief's seven steps
--     (`update_directory`, `google_profile`, `email_signature`,
--     `first_post`) get their `label`/`description` UPDATEd to the brief's
--     wording — `done_at` (and now `skipped_at`) are untouched, so nobody's
--     progress moves;
--   - `paste_site_prompt` is RENAMED to `site_setup` (the row itself,
--     `done_at` included, is UPDATEd, not deleted and recreated) — the
--     concept it tracked ("get your brand onto your actual site") is
--     exactly the brief's step 1, the old KEY just described a since-
--     replaced flow (Lot 1 replaced "paste your site prompt" with the site
--     editor — brand-kit-view.tsx's own header comment says so);
--   - `choose_direction` is left completely alone — it is a real, already-
--     shipped step from BEFORE this chantier's post-purchase space even
--     begins, and every kit reaching this checklist has it auto-completed
--     already (`complete_choose_direction`, fired at direction selection).
--     It stays in the table (so the existing auto-completion trigger keeps
--     something to write to) but the new RPCs below exclude it from "Your
--     first week"'s 7-item view — a legacy row, not a legacy DELETE.
--
-- A new nullable `skipped_at` column adds the tri-state status the brief
-- asks for ("Mark done" / "Skip for now") without touching the existing
-- `done_at`-only column grant the six-item version already has tested RLS
-- for — every WRITE to `skipped_at` goes through `set_launch_step` below
-- (SECURITY DEFINER, its own ownership check), never a direct client UPDATE.
--
-- Nothing here is a DROP or a DELETE. Every existing row keeps its `id`,
-- `created_at`, and whatever `done_at` a real user has already earned.
-- ============================================================================


-- ============================================================================
-- 1. Schema: widen the key CHECK, add skipped_at
-- ============================================================================
alter table public.launch_checklist_items
  add column if not exists skipped_at timestamptz;

alter table public.launch_checklist_items
  drop constraint if exists launch_checklist_items_done_xor_skipped_check;
alter table public.launch_checklist_items
  add constraint launch_checklist_items_done_xor_skipped_check
  check (not (done_at is not null and skipped_at is not null));

alter table public.launch_checklist_items drop constraint if exists launch_checklist_items_key_check;
alter table public.launch_checklist_items
  add constraint launch_checklist_items_key_check check (
    key = any (array[
      'choose_direction'::text, 'paste_site_prompt'::text, 'update_directory'::text,
      'first_post'::text, 'email_signature'::text, 'google_profile'::text,
      'site_setup'::text, 'social_setup'::text, 'booking_link'::text
    ])
  );

comment on column public.launch_checklist_items.skipped_at is
  'Set only by set_launch_step(status => ''skipped''), never by a direct client UPDATE — there is no column grant for it, unlike done_at. Mutually exclusive with done_at (see the xor check above).';


-- ============================================================================
-- 2. Relabel the four steps that already map onto one of the brief's seven,
--    and rename paste_site_prompt -> site_setup (same row, done_at kept)
-- ============================================================================
update public.launch_checklist_items
   set key = 'site_setup',
       label = 'Put your brand on your site',
       description = 'Edit your pages in the site editor, then follow the instructions for your builder.',
       sort_order = 1
 where key = 'paste_site_prompt';

update public.launch_checklist_items
   set label = 'Update your Psychology Today profile',
       description = 'Your board-safe personal statement and your avatar — the same words, the same photo, everywhere.',
       sort_order = 2
 where key = 'update_directory';

update public.launch_checklist_items
   set label = 'Claim or update your Google Business Profile',
       description = 'The description and the photos, so search results match your site.',
       sort_order = 3
 where key = 'google_profile';

update public.launch_checklist_items
   set label = 'Install your email signature',
       description = 'Copy it from your brand kit and paste it into Gmail or Outlook.',
       sort_order = 5
 where key = 'email_signature';

update public.launch_checklist_items
   set label = 'Publish your first post',
       description = 'Use the signature template from your brand kit. One post is enough to start.',
       sort_order = 7
 where key = 'first_post';


-- ============================================================================
-- 3. Re-seed: add the two new steps to every kit that doesn't have them yet
-- ============================================================================
-- `seed_launch_checklist` is replaced below with the full seven-plus-legacy
-- shape, for kits created from here on; existing kits get the two new rows
-- via the same idempotent ON CONFLICT DO NOTHING, called once for every kit
-- that already exists (same backfill pattern the original migration used).

create or replace function public.seed_launch_checklist(p_brand_kit_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_count   int;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null then
    raise exception
      'seed_launch_checklist: brand kit % does not exist, or its project has no owner.', p_brand_kit_id;
  end if;

  insert into public.launch_checklist_items (user_id, brand_kit_id, key, label, description, sort_order)
  values
    (v_user_id, p_brand_kit_id, 'choose_direction',
     'Choose your creative direction',
     'Pick the one of the three that sounds like you. You can change it later.', 0),
    (v_user_id, p_brand_kit_id, 'site_setup',
     'Put your brand on your site',
     'Edit your pages in the site editor, then follow the instructions for your builder.', 1),
    (v_user_id, p_brand_kit_id, 'update_directory',
     'Update your Psychology Today profile',
     'Your board-safe personal statement and your avatar — the same words, the same photo, everywhere.', 2),
    (v_user_id, p_brand_kit_id, 'google_profile',
     'Claim or update your Google Business Profile',
     'The description and the photos, so search results match your site.', 3),
    (v_user_id, p_brand_kit_id, 'social_setup',
     'Set up Instagram and Facebook',
     'Your avatar, your cover image, and a bio under 150 characters — all in your brand kit.', 4),
    (v_user_id, p_brand_kit_id, 'email_signature',
     'Install your email signature',
     'Copy it from your brand kit and paste it into Gmail or Outlook.', 5),
    (v_user_id, p_brand_kit_id, 'booking_link',
     'Put your booking link everywhere',
     'Your site, your email signature, your profiles — one link, everywhere someone might look.', 6),
    (v_user_id, p_brand_kit_id, 'first_post',
     'Publish your first post',
     'Use the signature template from your brand kit. One post is enough to start.', 7)
  -- The idempotence itself. A kit regenerated in place — or already
  -- migrated to the four relabeled keys above — keeps the items and
  -- done_at values it already has; only genuinely missing keys are added.
  on conflict (brand_kit_id, key) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

comment on function public.seed_launch_checklist(uuid) is
  'Insert this kit''s launch checklist items (choose_direction, a legacy step this trigger still auto-completes, plus the seven "Your first week" steps). Idempotent: returns the number of rows actually inserted, 0 on re-run — existing rows (including their done_at/skipped_at) are never touched.';

-- CREATE OR REPLACE preserves an existing function's ACL in real Postgres,
-- but the revoke-surface guard rail two migrations back exists precisely
-- because this codebase does not want to rely on that going unverified —
-- re-issuing the same revoke this function already had is cheap insurance,
-- checked again at the bottom of this migration.
revoke execute on function public.seed_launch_checklist(uuid) from public, anon, authenticated;

do $$
declare
  k record;
begin
  for k in select id from public.brand_kits loop
    perform public.seed_launch_checklist(k.id);
  end loop;
end
$$;


-- ============================================================================
-- 4. get_launch_progress / set_launch_step
-- ============================================================================
-- "Your first week" is the seven steps only — choose_direction is excluded
-- from both the item list and the counts, everywhere in this section.

create or replace function public.get_launch_progress(p_brand_kit_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null or v_user_id <> (select auth.uid()) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such brand kit.'
    ));
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'key', i.key,
          'label', i.label,
          'description', i.description,
          'status', case
            when i.done_at is not null then 'done'
            when i.skipped_at is not null then 'skipped'
            else 'todo'
          end
        )
        order by i.sort_order
      )
      from public.launch_checklist_items i
      where i.brand_kit_id = p_brand_kit_id
        and i.key <> 'choose_direction'
    ), '[]'::jsonb),
    'resolved_count', (
      select count(*) from public.launch_checklist_items i
       where i.brand_kit_id = p_brand_kit_id
         and i.key <> 'choose_direction'
         and (i.done_at is not null or i.skipped_at is not null)
    ),
    'total', (
      select count(*) from public.launch_checklist_items i
       where i.brand_kit_id = p_brand_kit_id
         and i.key <> 'choose_direction'
    )
  );
end;
$$;

comment on function public.get_launch_progress(uuid) is
  '"Your first week", read: the seven steps (choose_direction excluded — it is a legacy, already-auto-completed step from before this checklist''s current shape), each with its status (done/skipped/todo), plus resolved_count (done+skipped) and total for the progress ring.';

revoke execute on function public.get_launch_progress(uuid) from public, anon;
grant execute on function public.get_launch_progress(uuid) to authenticated, service_role;

create or replace function public.set_launch_step(
  p_brand_kit_id uuid,
  p_key text,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if p_status not in ('done', 'todo', 'skipped') then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_format',
      'message', 'status must be one of done, todo, skipped.',
      'field', 'status'
    ));
  end if;

  if p_key = 'choose_direction' then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such launch step.',
      'field', 'key'
    ));
  end if;

  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null or v_user_id <> (select auth.uid()) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such brand kit.'
    ));
  end if;

  -- `coalesce(done_at, now())` / `coalesce(skipped_at, now())`: re-marking
  -- an already-done or already-skipped step does not move its timestamp —
  -- same rule complete_choose_direction already established for this table.
  update public.launch_checklist_items
     set done_at    = case when p_status = 'done'    then coalesce(done_at, now())    else null end,
         skipped_at = case when p_status = 'skipped' then coalesce(skipped_at, now()) else null end
   where brand_kit_id = p_brand_kit_id
     and key = p_key;

  if not found then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such launch step.',
      'field', 'key'
    ));
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.set_launch_step(uuid, text, text) is
  'Sets one "Your first week" step to done/todo/skipped, for the caller''s own kit. The only write path for skipped_at — there is no column grant for it, unlike done_at''s existing direct-UPDATE path (kept, for the home screen''s existing toggle). Refuses choose_direction (it is not one of the seven, and is written only by complete_choose_direction).';

revoke execute on function public.set_launch_step(uuid, text, text) from public, anon;
grant execute on function public.set_launch_step(uuid, text, text) to authenticated, service_role;


-- ============================================================================
-- 5. Guard rails
-- ============================================================================
do $$
declare
  n int;
  leaked text;
begin
  -- Every kit now has exactly eight items: choose_direction plus the seven
  -- "Your first week" steps.
  select count(*) into n
    from public.brand_kits bk
   where (select count(*) from public.launch_checklist_items i where i.brand_kit_id = bk.id) <> 8;
  if n > 0 then
    raise exception 'launch_checklist_items: % brand kit(s) do not have exactly 8 checklist items.', n;
  end if;

  -- No row was left behind under the old, now-invalid key.
  if exists (select 1 from public.launch_checklist_items where key = 'paste_site_prompt') then
    raise exception 'launch_checklist_items: a row still carries the retired key paste_site_prompt.';
  end if;

  -- Same check the revoke-surface migration runs, scoped to the two
  -- functions this migration touched.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into leaked
    from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public'
     and p.proname = 'seed_launch_checklist'
     and has_function_privilege('anon', p.oid, 'execute');
  if leaked is not null then
    raise exception 'launch_checklist_items: seed_launch_checklist is still executable by anon: %.', leaked;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   revoke execute on function public.set_launch_step(uuid, text, text) from authenticated, service_role;
--   drop function if exists public.set_launch_step(uuid, text, text);
--   revoke execute on function public.get_launch_progress(uuid) from authenticated, service_role;
--   drop function if exists public.get_launch_progress(uuid);
--   -- Re-seeding, relabeling, and the widened CHECK are not rolled back:
--   -- doing so would delete real done_at/skipped_at progress. Leave the
--   -- schema forward-compatible; a genuine rollback needs a hand-written
--   -- data migration, not this file.
-- ============================================================================
