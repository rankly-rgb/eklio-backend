-- ============================================================================
-- "Most recent first" that can return the oldest
-- ============================================================================
-- Both functions order by `created_at desc` alone. `created_at` defaults to
-- `now()`, which in PostgreSQL is the START OF THE TRANSACTION and does not
-- advance within it — so two versions of the same asset written in one
-- transaction carry the SAME timestamp and the sort has no basis on which to
-- separate them. Postgres is then free to return either first, and it does.
--
-- `get_brand_asset_versions` promises the current version at the head of the
-- list; `get_brand_asset_previous_inputs` promises the most recent OTHER
-- version's inputs, and takes `limit 1` of that undefined order. The second is
-- the worse of the two: it hands the regeneration path a previous palette that
-- may not be the previous palette, and nothing about the answer looks wrong.
--
-- In production two versions are minutes or days apart and the tie never
-- arises, which is why this has never been seen. It arises in any test, any
-- backfill and any batch import that writes twice in one transaction — and it
-- surfaced as exactly that: a test asserting "la plus récente vient en tête"
-- and receiving the older row, with both rows carrying an identical
-- `created_at`.
--
-- ⚠ THE TIEBREAKER IS SEMANTIC, NOT COSMETIC. `superseded_at desc nulls first`
-- means: the version nobody has replaced comes first, then the one replaced
-- most recently. `fingerprint` is the final key purely so that the order is
-- TOTAL — two rows that tie on everything else must still come back in the
-- same order twice, or the next test to look will flicker.
--
-- ── ONE THE SAME SHAPE THAT IS DELIBERATELY NOT TOUCHED HERE ───────────────
--
-- `grant_plan_allowance` carries `order by pu.created_at desc` over
-- `purchases`, where a double submit writes two rows in one transaction — the
-- same tie, in the money path. It is not changed here because the
-- post-purchase space is not this chantier's to touch. It is written down in
-- FINDINGS.md instead.
-- ============================================================================

create or replace function public.get_brand_asset_versions(p_brand_kit_id uuid, p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'fingerprint', a.fingerprint,
        'created_at', a.created_at,
        'superseded_at', a.superseded_at,
        'change_summary', a.change_summary,
        'byte_size', a.byte_size,
        'download_count', a.download_count,
        'current', a.superseded_at is null
      )
      order by a.superseded_at desc nulls first, a.created_at desc, a.fingerprint desc
    )
    from public.brand_assets a
    where a.brand_kit_id = p_brand_kit_id
      and a.key = p_key
      -- One entry per version, not one per width she happened to ask for:
      -- the variants of a version are the same rendering as its native row.
      and a.size = 0
      and a.format = ''
  ), '[]'::jsonb);
end;
$function$;

create or replace function public.get_brand_asset_previous_inputs(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_inputs jsonb;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select fingerprint_inputs into v_inputs
    from public.brand_assets
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint <> p_fingerprint
     and size = 0
     and format = ''
   order by created_at desc, superseded_at desc nulls first, fingerprint desc
   limit 1;

  return jsonb_build_object('inputs', coalesce(v_inputs, '{}'::jsonb));
end;
$function$;

-- ---------------------------------------------------------------------------
-- Guard rail — two versions in ONE transaction, which is the failing case
-- ---------------------------------------------------------------------------
do $$
declare
  v_order text;
begin
  select substring(pg_get_functiondef(p.oid) from 'order by[^\n]*')
    into v_order
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_brand_asset_versions';
  assert v_order like '%superseded_at desc nulls first%',
    format('get_brand_asset_versions is still ordered only by created_at: %s', v_order);

  select substring(pg_get_functiondef(p.oid) from 'order by[^\n]*')
    into v_order
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_brand_asset_previous_inputs';
  assert v_order like '%fingerprint desc%',
    format('get_brand_asset_previous_inputs has no total order: %s', v_order);
end
$$;
