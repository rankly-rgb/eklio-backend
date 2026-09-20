-- ============================================================================
-- Eklio — écrire un rendu une seule fois, et savoir ce qu'un mois a coûté
-- ============================================================================
-- Deux RPC que le pipeline appelle, et une vue que la preuve de coût lit.
--
-- ⚠ LA DÉDUPLICATION EST DANS LE RPC, PAS DANS L'APPELANT. `rendered_assets`
-- porte déjà `unique (brand_kit_id, content_hash)` — mais une contrainte
-- d'unicité refuse un doublon en LEVANT, et un appelant qui reçoit une
-- exception a déjà dépensé la seconde de rendu qu'elle devait éviter.
--
-- Le RPC répond « voici le chemin » dans les deux cas. C'est la différence
-- entre « on ne stocke pas deux fois » et « on ne REND pas deux fois », et
-- seule la seconde est ce que le chantier demande.
-- ============================================================================


-- ============================================================================
-- 1. rendered_asset_path — la question posée AVANT de rendre
-- ============================================================================
create or replace function public.rendered_asset_path(
  p_brand_kit_id uuid,
  p_content_hash text
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select ra.storage_path
    from public.rendered_assets ra
   where ra.brand_kit_id = p_brand_kit_id
     and ra.content_hash = p_content_hash
$$;

comment on function public.rendered_asset_path(uuid, text) is
  'The stored path for this (kit, content hash), or NULL. THE call the pipeline makes before rendering anything: a hit means the second of Satori and resvg is never spent. NULL means render.';

revoke all on function public.rendered_asset_path(uuid, text) from public, anon, authenticated;
grant execute on function public.rendered_asset_path(uuid, text) to service_role;


-- ============================================================================
-- 2. record_rendered_asset — idempotent, et il rend le chemin qui gagne
-- ============================================================================
create or replace function public.record_rendered_asset(
  p_brand_kit_id  uuid,
  p_content_hash  text,
  p_archetype_key text,
  p_palette_key   text,
  p_storage_path  text,
  p_width         integer,
  p_height        integer,
  p_bytes         integer,
  p_render_ms     integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing text;
begin
  v_existing := public.rendered_asset_path(p_brand_kit_id, p_content_hash);
  if v_existing is not null then
    -- ⚠ LE CHEMIN EXISTANT, PAS CELUI QU'ON PROPOSAIT. Deux rendus du même
    -- contenu produisent le même SVG à l'octet près (c'est la suite de
    -- déterminisme qui le tient), donc les deux chemins sont interchangeables
    -- — mais un seul objet existe dans le bucket, et c'est celui-là.
    return jsonb_build_object('ok', true, 'reason', 'cached', 'storage_path', v_existing);
  end if;

  insert into public.rendered_assets
    (brand_kit_id, content_hash, archetype_key, palette_key, storage_path,
     width, height, bytes, render_ms)
  values (p_brand_kit_id, p_content_hash, p_archetype_key, p_palette_key, p_storage_path,
          p_width, p_height, p_bytes, p_render_ms)
  on conflict (brand_kit_id, content_hash) do nothing;

  -- Une course perdue rend le chemin du gagnant. `on conflict do nothing`
  -- plutôt que `do update` : le premier rendu est aussi bon que le second et
  -- il est déjà dans le bucket.
  return jsonb_build_object(
    'ok', true,
    'reason', case when found then 'rendered' else 'cached' end,
    'storage_path', public.rendered_asset_path(p_brand_kit_id, p_content_hash)
  );
end
$$;

comment on function public.record_rendered_asset(uuid, text, text, text, text, integer, integer, integer, integer) is
  'Records a render, or reports the one already there. Idempotent by answer rather than by exception: a unique violation would arrive after the second the render already cost. Returns {ok, reason: rendered|cached, storage_path}.';

revoke all on function public.record_rendered_asset(uuid, text, text, text, text, integer, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.record_rendered_asset(uuid, text, text, text, text, integer, integer, integer, integer)
  to service_role;


-- ============================================================================
-- 3. record_custom_visual — le seul chemin qui dépense, et il paie une fois
-- ============================================================================
create or replace function public.record_custom_visual(
  p_brand_kit_id    uuid,
  p_prompt_hash     text,
  p_content_item_id uuid,
  p_model           text,
  p_quality         text,
  p_size            text,
  p_storage_path    text,
  p_cost_usd        numeric,
  p_reservation_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing text;
begin
  select storage_path into v_existing
    from public.custom_visual_generations
   where brand_kit_id = p_brand_kit_id and prompt_hash = p_prompt_hash;

  if v_existing is not null then
    -- ⚠ ET LA RÉSERVATION EST RELÂCHÉE. Un prompt déjà généré ne coûte rien,
    -- donc le crédit qui avait été réservé pour lui revient. Sans cette ligne,
    -- la déduplication économiserait l'appel d'API et dépenserait quand même
    -- le crédit — ce qui est la moitié de la promesse.
    perform public.settle_credit(p_reservation_id, null, false);
    return jsonb_build_object('ok', true, 'reason', 'cached', 'storage_path', v_existing);
  end if;

  insert into public.custom_visual_generations
    (brand_kit_id, prompt_hash, content_item_id, model, quality, size,
     storage_path, cost_usd, reservation_id)
  values (p_brand_kit_id, p_prompt_hash, p_content_item_id, p_model, p_quality, p_size,
          p_storage_path, p_cost_usd, p_reservation_id)
  on conflict (brand_kit_id, prompt_hash) do nothing;

  if not found then
    perform public.settle_credit(p_reservation_id, null, false);
    select storage_path into v_existing
      from public.custom_visual_generations
     where brand_kit_id = p_brand_kit_id and prompt_hash = p_prompt_hash;
    return jsonb_build_object('ok', true, 'reason', 'cached', 'storage_path', v_existing);
  end if;

  perform public.settle_credit(p_reservation_id, p_cost_usd, true);
  return jsonb_build_object('ok', true, 'reason', 'generated', 'storage_path', p_storage_path);
end
$$;

comment on function public.record_custom_visual(uuid, text, uuid, text, text, text, text, numeric, uuid) is
  'Records a paid image and settles its credit, or reports the one already there AND RELEASES the credit. Without that release, dedup would save the API call and spend the credit anyway -- half a promise.';

revoke all on function public.record_custom_visual(uuid, text, uuid, text, text, text, text, numeric, uuid)
  from public, anon, authenticated;
grant execute on function public.record_custom_visual(uuid, text, uuid, text, text, text, text, numeric, uuid)
  to service_role;


-- ============================================================================
-- 4. content_month_cost — la preuve de coût, ventilée par poste
-- ============================================================================
-- ⚠ LIT `credit_ledger`, PAS UNE ESTIMATION. Le ledger porte l'estimé et le
-- réel dans deux colonnes distinctes précisément pour que l'écart entre ce
-- qu'on croyait dépenser et ce qu'on a dépensé soit un nombre qu'on peut
-- regarder, plutôt qu'une question à laquelle personne ne peut répondre.

create or replace function public.content_month_cost(p_user uuid, p_month date)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_object_agg(
      kind,
      jsonb_build_object(
        'reservations',  reservations,
        'settlements',   settlements,
        'releases',      releases,
        'consumed',      consumed,
        'estimated_usd', estimated_usd,
        'actual_usd',    actual_usd
      )
    ),
    '{}'::jsonb
  )
  from (
    select l.kind,
           count(*) filter (where l.entry_type = 'reservation') as reservations,
           count(*) filter (where l.entry_type = 'settlement')  as settlements,
           count(*) filter (where l.entry_type = 'release')     as releases,
           -sum(l.delta)                                        as consumed,
           coalesce(sum(l.estimated_cost_usd), 0)               as estimated_usd,
           coalesce(sum(l.actual_cost_usd), 0)                  as actual_usd
      from public.credit_ledger l
     where l.user_id = p_user
       and l.month = date_trunc('month', p_month)::date
     group by l.kind
  ) per_kind
$$;

comment on function public.content_month_cost(uuid, date) is
  'What one month actually cost this user, per kind, read from credit_ledger. Estimated and actual are separate numbers on purpose: the gap between what we expected to spend and what we spent is the only way to tell a pricing assumption from a measurement.';

revoke all on function public.content_month_cost(uuid, date) from public, anon, authenticated;
grant execute on function public.content_month_cost(uuid, date) to service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_user uuid := gen_random_uuid();
  v_proj uuid := gen_random_uuid();
  v_kit  uuid := gen_random_uuid();
  v_hash text := repeat('e', 64);
  v_res  jsonb;
  v_r1   jsonb;
  v_r2   jsonb;
  v_n    integer;
  v_mod  text;
  v_per  text;
  fn     text;
begin
  foreach fn in array array[
    'rendered_asset_path(uuid,text)',
    'record_rendered_asset(uuid,text,text,text,text,integer,integer,integer,integer)',
    'record_custom_visual(uuid,text,uuid,text,text,text,text,numeric,uuid)',
    'content_month_cost(uuid,date)'
  ] loop
    if has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated peut exécuter %', fn;
    end if;
  end loop;

  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_user, 'dedup@example.invalid');
  insert into public.projects (id, user_id, name) values (v_proj, v_user, 'D');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_proj, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_user, 'dedup guard rail', 'migration 20260920160100', now() + interval '1 day');

  -- ---- ⚠ PREUVE DE DÉDUPLICATION : deux rendus, UN enregistrement --------
  v_r1 := public.record_rendered_asset(v_kit, v_hash, 'single_statement', 'sage',
                                       v_kit::text || '/first.png', 1080, 1350, 40000, 900);
  v_r2 := public.record_rendered_asset(v_kit, v_hash, 'single_statement', 'sage',
                                       v_kit::text || '/second.png', 1080, 1350, 40000, 12);

  if (v_r1 ->> 'reason') <> 'rendered' then
    raise exception 'le premier rendu n''a pas été enregistré: %', v_r1;
  end if;
  if (v_r2 ->> 'reason') <> 'cached' then
    raise exception 'le second rendu du même contenu a été enregistré à nouveau: %', v_r2;
  end if;
  if (v_r2 ->> 'storage_path') <> (v_r1 ->> 'storage_path') then
    raise exception 'le second appel a rendu un chemin différent du premier.';
  end if;

  select count(*) into v_n from public.rendered_assets where brand_kit_id = v_kit;
  if v_n <> 1 then
    raise exception 'deux rendus du même contenu ont produit % enregistrements', v_n;
  end if;

  -- Un contenu DIFFÉRENT produit bien un second asset: la déduplication
  -- n'écrase pas, elle distingue.
  v_r1 := public.record_rendered_asset(v_kit, repeat('f', 64), 'single_statement', 'sage',
                                       v_kit::text || '/third.png', 1080, 1350, 40000, 900);
  if (v_r1 ->> 'reason') <> 'rendered' then
    raise exception 'un contenu différent a été pris pour un doublon.';
  end if;

  -- ---- ⚠ ET UN PROMPT DÉJÀ GÉNÉRÉ REND SON CRÉDIT -----------------------
  v_res := public.reserve_credit(v_user, 'custom_visual', 'first image');
  v_r1 := public.record_custom_visual(v_kit, repeat('a', 64), null, 'gpt-image-2', 'low',
                                      '1024x1536', v_kit::text || '/v1.png', 0.02,
                                      (v_res ->> 'reservation_id')::uuid);
  if (v_r1 ->> 'reason') <> 'generated' then
    raise exception 'la première image n''a pas été générée: %', v_r1;
  end if;

  v_res := public.reserve_credit(v_user, 'custom_visual', 'the same image again');
  v_r2 := public.record_custom_visual(v_kit, repeat('a', 64), null, 'gpt-image-2', 'low',
                                      '1024x1536', v_kit::text || '/v2.png', 0.02,
                                      (v_res ->> 'reservation_id')::uuid);
  if (v_r2 ->> 'reason') <> 'cached' then
    raise exception 'le même prompt a été regénéré: %', v_r2;
  end if;

  -- Un seul crédit consommé sur les deux demandes.
  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'custom_visual'
     and month = date_trunc('month', now())::date;
  if v_n <> 1 then
    raise exception 'deux demandes du même prompt ont consommé % crédits, attendu 1', v_n;
  end if;

  -- ---- la preuve de coût lit bien le ledger ------------------------------
  if (public.content_month_cost(v_user, now()::date) #>> '{custom_visual,actual_usd}')::numeric
     <> 0.02 then
    raise exception 'content_month_cost ne rapporte pas le coût réel: %',
      public.content_month_cost(v_user, now()::date);
  end if;

  delete from auth.users where id = v_user;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.content_month_cost(uuid, date);
--   drop function if exists public.record_custom_visual(uuid,text,uuid,text,text,text,text,numeric,uuid);
--   drop function if exists public.record_rendered_asset(uuid,text,text,text,text,integer,integer,integer,integer);
--   drop function if exists public.rendered_asset_path(uuid, text);
