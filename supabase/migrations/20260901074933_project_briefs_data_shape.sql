-- ============================================================================
-- Eklio — a typed shape for project_briefs.data, open variant
-- ============================================================================
-- `project_briefs.data jsonb not null default '{}'` (20260823000000) is the
-- free-form bucket for whatever doesn't have a dedicated column yet — eight
-- keys from earlier lots (`stage`, `problem_text`, `gain_text`,
-- `builder_target`, `existing_url`, `practitioner_name`, `practitioner_line`,
-- `suggestion_notice_seen`), plus three from this one
-- (`selected_tone_card_id`, `usp_regenerate_count`,
-- `usp_options_inputs_hash` — see FRONTEND_CONTRACT.md §9 for why each one
-- lives here instead of its own column). Eleven keys deep now, and the
-- column has never had a shape of its own: the frontend's own Zod schema is
-- the only thing that has ever enforced what's inside it.
--
-- OPEN, not closed: unknown keys are TOLERATED. A twelfth gap-fill key can
-- land without a migration, which is the entire reason these keys live in a
-- jsonb bucket instead of real columns in the first place — closing the
-- shape would put a migration back in the way of exactly the friction this
-- bucket exists to avoid. What this constraint buys instead: the eleven
-- KNOWN keys, when present, must carry the right `jsonb_typeof` — a
-- backstop against whatever bypasses the frontend's Zod layer (a future
-- bug, a different service, a manual `psql` edit) that would otherwise
-- write silently-wrong data `parseBriefData` (eklio-frontend) would quietly
-- discard on next read — falling back to `{}` — rather than ever surfacing.
--
-- NAIVE FIRST PASS, PROBED AND DISCARDED: every key is optional, so the
-- naive instinct is "no top-level object gate needed — an absent key's
-- clause just passes vacuously." True for a JSON OBJECT missing a key, but
-- `?` (does this top-level key/element exist) also accepts a JSON ARRAY and
-- tests array MEMBERSHIP instead of erroring or returning NULL — so a
-- non-object `data` value vacuously satisfies every "not present OR
-- correctly typed" clause AT ONCE, with none of them ever going NULL.
-- Probed directly: a naive version built from the eleven
-- `(not (p ? 'key') or jsonb_typeof(p->'key') = 'type')` clauses AND'd
-- together, with no leading `jsonb_typeof(p) = 'object'` gate, returned
-- TRUE for `'[1,2,3]'::jsonb`, `'"just a string"'::jsonb` and
-- `'42'::jsonb` — a bare JSON array, string or number would all have been
-- accepted as valid `project_briefs.data`. The wrong-type-when-PRESENT case
-- was never actually the hole: a present key's `jsonb_typeof(p->'key')`
-- returns its real, non-null type name, so comparing it to the expected
-- type is an ordinary two-non-null-operand `=` with no NULL hazard either
-- way — `FALSE` from that one clause dominates the whole `AND` regardless
-- of how many other (optional, absent) keys evaluate to NULL. The single
-- missing `jsonb_typeof(p) = 'object'` gate below is what closes it.
-- ============================================================================

create or replace function public.project_briefs_data_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    p is not null
    and jsonb_typeof(p) = 'object'
    and (not (p ? 'stage') or jsonb_typeof(p->'stage') = 'string')
    and (not (p ? 'problem_text') or jsonb_typeof(p->'problem_text') = 'string')
    and (not (p ? 'gain_text') or jsonb_typeof(p->'gain_text') = 'string')
    and (not (p ? 'builder_target') or jsonb_typeof(p->'builder_target') = 'string')
    and (not (p ? 'existing_url') or jsonb_typeof(p->'existing_url') = 'string')
    and (not (p ? 'practitioner_name') or jsonb_typeof(p->'practitioner_name') = 'string')
    and (not (p ? 'practitioner_line') or jsonb_typeof(p->'practitioner_line') = 'string')
    and (not (p ? 'suggestion_notice_seen') or jsonb_typeof(p->'suggestion_notice_seen') = 'boolean')
    and (not (p ? 'selected_tone_card_id') or jsonb_typeof(p->'selected_tone_card_id') = 'string')
    and (not (p ? 'usp_regenerate_count') or jsonb_typeof(p->'usp_regenerate_count') = 'number')
    and (not (p ? 'usp_options_inputs_hash') or jsonb_typeof(p->'usp_options_inputs_hash') = 'string'),
  false)
$$;

comment on function public.project_briefs_data_valid(jsonb) is
  'project_briefs.data — the eleven known keys, type-checked with jsonb_typeof when present; unknown keys tolerated (open variant, by design — see the migration header). Never returns NULL: coalesced to false, so a CHECK constraint actually enforces this rather than silently accepting on NULL.';

-- ============================================================================
-- Re-validating what is already stored
-- ============================================================================
-- `create or replace function` does not re-check existing rows, and unlike
-- the how-you-work columns this lot otherwise adds, `data` has existed since
-- the very first schema migration — there may be rows from long before this
-- constraint existed. Count first, and add the constraint only if nothing
-- already stored would fail it; a migration that dies mid-`ALTER TABLE`
-- tells you something is wrong and nothing about what or how many.

do $$
declare
  n_bad   int;
  n_total int;
  r       record;
  detail  text := '';
begin
  select count(*) into n_total from public.project_briefs;

  create temporary table _data_shape_audit on commit drop as
  select pb.project_id,
         case
           when pb.data is null then 'data is SQL NULL (column is NOT NULL — should not happen)'
           when jsonb_typeof(pb.data) <> 'object' then 'data is not a JSON object'
           else 'a known key present with the wrong type: ' || (
             select string_agg(k, ', ') from (values
               ('stage', 'string'), ('problem_text', 'string'), ('gain_text', 'string'),
               ('builder_target', 'string'), ('existing_url', 'string'),
               ('practitioner_name', 'string'), ('practitioner_line', 'string'),
               ('suggestion_notice_seen', 'boolean'), ('selected_tone_card_id', 'string'),
               ('usp_regenerate_count', 'number'), ('usp_options_inputs_hash', 'string')
             ) as expect(k, t)
             where pb.data ? expect.k and jsonb_typeof(pb.data -> expect.k) <> expect.t
           )
         end as reason
    from public.project_briefs pb
   where not public.project_briefs_data_valid(pb.data);

  select count(*) into n_bad from _data_shape_audit;

  raise notice 'project_briefs.data audit: % row(s) total; % would fail the new shape check.', n_total, n_bad;

  if n_bad > 0 then
    for r in select reason, count(*) as n from _data_shape_audit group by reason order by 2 desc
    loop
      detail := detail || format(E'\n    %s row(s): %s', r.n, r.reason);
      raise notice '  % row(s): %', r.n, r.reason;
    end loop;

    raise exception
      E'project_briefs_data_shape: STOPPING. % row(s) already stored would fail the new check:%\n\n  Nothing has been changed. Decide whether to backfill these rows or gate the constraint, then re-run.',
      n_bad, detail;
  end if;

  alter table public.project_briefs drop constraint if exists project_briefs_data_shape_check;
  alter table public.project_briefs
    add constraint project_briefs_data_shape_check
    check (public.project_briefs_data_valid(data));

  raise notice 'project_briefs.data audit: 0 rows affected; project_briefs_data_shape_check added.';
end
$$;

-- No explicit grant/revoke here, matching `project_briefs_tone_cards_valid`
-- and `project_briefs_usp_options_valid` right above in
-- 20260831102000_project_briefs_how_you_work_columns.sql: a CHECK-backing
-- shape validator (unlike the locked-down trigger functions, or an RPC like
-- `usp_banned_phrases_check` that would leak a secret list if directly
-- callable) must stay executable by whoever writes the row, and reveals
-- nothing — Postgres's default `EXECUTE ... TO PUBLIC` on function creation
-- is the right grant, not an oversight to close.

-- ============================================================================
-- DOWN
-- ============================================================================
-- alter table public.project_briefs drop constraint if exists project_briefs_data_shape_check;
-- drop function if exists public.project_briefs_data_valid(jsonb);
