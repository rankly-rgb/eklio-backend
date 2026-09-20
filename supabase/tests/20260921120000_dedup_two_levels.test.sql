-- ============================================================================
-- Tests — LA DÉDUPLICATION A DEUX ÉTAGES, ET CE SONT DEUX CHOSES DIFFÉRENTES
-- ============================================================================
-- On les confond facilement parce qu'elles disent toutes les deux « on ne
-- refait pas ». Elles ne protègent pas la même dépense :
--
--   ÉTAGE 1 — LE RENDU. Clef : (brand_kit_id, content_hash). Ce qu'elle
--   économise, c'est du CPU et une écriture de stockage. Rien n'est facturé à
--   personne. Deux rendus du même contenu produisent le même SVG à l'octet
--   près — c'est la suite de déterminisme qui le tient — donc un seul objet
--   doit exister dans le seau.
--
--   ÉTAGE 2 — LE PROMPT D'IMAGE. Clef : (brand_kit_id, prompt_hash). Ce
--   qu'elle économise, c'est un APPEL À OPENAI et un CRÉDIT. Un cache qui
--   éviterait l'appel et dépenserait quand même le crédit tiendrait la moitié
--   de la promesse, et c'est la moitié qui coûte de l'argent.
--
-- ⚠ ET LEURS GRAINS DIFFÈRENT. Le prompt est dédupliqué PAR KIT ; le crédit
-- est décompté PAR UTILISATRICE. Pour une praticienne à un seul kit les deux
-- coïncident, et le jour où elle en a deux, le même prompt sur le second kit
-- est un second appel et un second crédit. C'est voulu : un visuel appartient
-- à une marque, un crédit appartient à une personne.
-- ============================================================================
begin;

create temporary table p (k text primary key, v uuid) on commit drop;

do $seed$
declare
  v_mod text; v_per text; v_spec text;
  v_u uuid := gen_random_uuid();
  v_pr uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_item uuid;
begin
  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;
  select id into v_spec from public.specialties where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u, 'dedup@example.invalid');
  insert into public.projects (id, user_id, name) values (v_pr, v_u, 'D');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, specialty_ids, state)
  values (v_pr, array[v_mod], array[v_per], array[v_spec], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k, v_pr);
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_u, 'dedup test', 'supabase/tests', now() + interval '1 day');

  insert into public.content_items (brand_kit_id, archetype, status, title)
  values (v_k, 'statement', 'draft', 'The one with a visual')
  returning id into v_item;

  -- ⚠ AUCUN QUOTA N'EST POSÉ ICI. `credit_quotas` est par PLAN
  -- (`standard`/`trial`), pas par utilisatrice : `custom_visual` y vaut déjà
  -- 4 par mois pour le plan standard. En insérer un ici prouverait que le
  -- test sait écrire dans une table, pas que la dédup marche sur le quota réel.

  insert into p values ('u', v_u), ('k', v_k), ('item', v_item);
end
$seed$;


-- ---------------------------------------------------------------------------
-- ÉTAGE 1 — le même payload rendu deux fois : UN enregistrement, UN chemin
-- ---------------------------------------------------------------------------
do $t1$
declare
  v_k uuid := (select v from p where k = 'k');
  v_hash text := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  v_first jsonb; v_second jsonb;
  v_rows integer;
begin
  v_first := public.record_rendered_asset(
    v_k, v_hash, 'cycle', 'sage', v_k::text || '/cards/' || v_hash || '.png',
    1080, 1350, 204_800, 412
  );
  assert (v_first ->> 'ok')::boolean, format('le premier rendu a échoué: %s', v_first);
  assert v_first ->> 'reason' = 'rendered',
    format('le premier rendu se dit déjà en cache: %s', v_first);

  /*
   * ⚠ LE SECOND APPEL PROPOSE UN AUTRE CHEMIN, EXPRÈS. Un pipeline qui
   * rerend écrit dans un chemin horodaté ; si la fonction acceptait la
   * proposition, deux objets existeraient dans le seau pour un seul contenu et
   * le cache ne serait qu'une table.
   */
  v_second := public.record_rendered_asset(
    v_k, v_hash, 'cycle', 'sage', v_k::text || '/cards/' || v_hash || '-again.png',
    1080, 1350, 204_800, 398
  );
  assert (v_second ->> 'ok')::boolean, format('le second rendu a échoué: %s', v_second);
  assert v_second ->> 'reason' = 'cached',
    format('le second rendu ne s''est pas reconnu: %s', v_second);
  assert v_second ->> 'storage_path' = v_first ->> 'storage_path',
    format('le second rendu a rendu un autre chemin: %s vs %s',
           v_second ->> 'storage_path', v_first ->> 'storage_path');

  select count(*) into v_rows from public.rendered_assets
   where brand_kit_id = v_k and content_hash = v_hash;
  assert v_rows = 1, format('%s enregistrements pour un seul contenu', v_rows);
end
$t1$;


-- ---------------------------------------------------------------------------
-- ÉTAGE 1 bis — un AUTRE kit, le même hash : un enregistrement chacun
-- ---------------------------------------------------------------------------
-- ⚠ PARCE QUE LE SEAU EST RANGÉ PAR KIT. Le même diagramme dans les couleurs
-- d'une autre praticienne est une autre image, et la clef unique est bien la
-- paire. Sans ce cas, un cache global passerait le test ci-dessus en servant à
-- la seconde l'image de la première.
do $t1b$
declare
  v_hash text := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  v_u2 uuid := gen_random_uuid(); v_pr2 uuid := gen_random_uuid(); v_k2 uuid := gen_random_uuid();
  v_mod text; v_per text;
  v_res jsonb; v_rows integer;
begin
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u2, 'dedup-two@example.invalid');
  insert into public.projects (id, user_id, name) values (v_pr2, v_u2, 'D2');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_pr2, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k2, v_pr2);

  v_res := public.record_rendered_asset(
    v_k2, v_hash, 'cycle', 'slate', v_k2::text || '/cards/' || v_hash || '.png',
    1080, 1350, 199_000, 401
  );
  assert v_res ->> 'reason' = 'rendered',
    format('le kit d''une autre a hérité du cache: %s', v_res);

  select count(*) into v_rows from public.rendered_assets where content_hash = v_hash;
  assert v_rows = 2, format('%s enregistrements pour deux kits', v_rows);
end
$t1b$;


-- ---------------------------------------------------------------------------
-- ÉTAGE 2 — le même prompt deux fois : UN appel, UN crédit
-- ---------------------------------------------------------------------------
do $t2$
declare
  v_u uuid := (select v from p where k = 'u');
  v_k uuid := (select v from p where k = 'k');
  v_item uuid := (select v from p where k = 'item');
  v_month date := date_trunc('month', now())::date;
  v_prompt text := 'a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1';
  v_res1 jsonb; v_res2 jsonb;
  v_rec1 jsonb; v_rec2 jsonb;
  v_consumed integer; v_rows integer;
begin
  -- ── Première génération : réservation, appel, règlement ───────────────
  v_res1 := public.reserve_credit(
    p_user => v_u, p_kind => 'custom_visual', p_reason => 'first pass',
    p_ref_type => 'content_item', p_ref_id => v_item,
    p_estimated_cost_usd => 0.0468, p_month => v_month
  );
  assert (v_res1 ->> 'ok')::boolean, format('la première réservation a échoué: %s', v_res1);

  v_rec1 := public.record_custom_visual(
    v_k, v_prompt, v_item, 'gpt-image-2.5-flare', 'low', '1024x1536',
    v_k::text || '/custom/' || v_prompt || '.png', 0.0468,
    (v_res1 ->> 'reservation_id')::uuid
  );
  assert v_rec1 ->> 'reason' = 'generated',
    format('la première génération se dit déjà en cache: %s', v_rec1);

  select consumed into v_consumed from public.credit_balances
   where user_id = v_u and kind = 'custom_visual' and month = v_month;
  assert v_consumed = 1, format('après une génération, %s crédit(s) consommé(s)', v_consumed);

  -- ── Deuxième tentative, MÊME prompt ───────────────────────────────────
  -- Le chemin de production réserve AVANT de savoir si c'est un doublon : il
  -- ne peut pas savoir sans regarder, et regarder puis réserver laisserait
  -- deux appels concurrents passer tous les deux.
  v_res2 := public.reserve_credit(
    p_user => v_u, p_kind => 'custom_visual', p_reason => 'second pass',
    p_ref_type => 'content_item', p_ref_id => v_item,
    p_estimated_cost_usd => 0.0468, p_month => v_month
  );
  assert (v_res2 ->> 'ok')::boolean, format('la seconde réservation a échoué: %s', v_res2);

  v_rec2 := public.record_custom_visual(
    v_k, v_prompt, v_item, 'gpt-image-2.5-flare', 'low', '1024x1536',
    v_k::text || '/custom/' || v_prompt || '-again.png', 0.0468,
    (v_res2 ->> 'reservation_id')::uuid
  );
  assert v_rec2 ->> 'reason' = 'cached',
    format('le doublon ne s''est pas reconnu: %s', v_rec2);
  assert v_rec2 ->> 'storage_path' = v_rec1 ->> 'storage_path',
    'le doublon a rendu un autre chemin';

  -- ⚠ ET LE CRÉDIT EST REVENU. C'est la moitié qui coûte de l'argent.
  select consumed into v_consumed from public.credit_balances
   where user_id = v_u and kind = 'custom_visual' and month = v_month;
  assert v_consumed = 1,
    format('après un doublon, %s crédit(s) consommé(s) au lieu de 1', v_consumed);

  select count(*) into v_rows from public.custom_visual_generations
   where brand_kit_id = v_k and prompt_hash = v_prompt;
  assert v_rows = 1, format('%s génération(s) enregistrée(s) pour un seul prompt', v_rows);

  /*
   * ⚠ LE JOURNAL, LUI, PORTE LES DEUX RÉSERVATIONS ET LEURS DEUX ISSUES.
   * C'est voulu : le journal est append-only, et « on a réservé puis relâché »
   * est un fait qui s'est produit. Ce qui doit être à 1 est le SOLDE, pas le
   * nombre de lignes — un test qui compterait les lignes prouverait le
   * contraire de ce qu'il croit.
   */
  select count(*) into v_rows from public.credit_ledger
   where user_id = v_u and kind = 'custom_visual' and entry_type = 'reservation';
  assert v_rows = 2, format('%s réservation(s) au journal, attendu 2', v_rows);

  select count(*) into v_rows from public.credit_ledger
   where user_id = v_u and kind = 'custom_visual' and entry_type = 'release';
  assert v_rows = 1, format('%s relâche(s) au journal, attendu 1', v_rows);
end
$t2$;


-- ---------------------------------------------------------------------------
-- ÉTAGE 2 bis — les deux étages ne se déduisent pas l'un de l'autre
-- ---------------------------------------------------------------------------
-- ⚠ UN CONTENU DÉJÀ RENDU N'IMPLIQUE PAS UN PROMPT DÉJÀ GÉNÉRÉ, et
-- réciproquement. Les deux tables sont distinctes, leurs clefs sont
-- distinctes, et un cache unique qui prétendrait couvrir les deux servirait un
-- jour une carte composée à la place d'une illustration.
do $t3$
declare
  v_k uuid := (select v from p where k = 'k');
  v_hash text := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  v_prompt text := 'a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1';
  v_a text; v_b text;
begin
  v_a := public.rendered_asset_path(v_k, v_hash);
  select storage_path into v_b from public.custom_visual_generations
   where brand_kit_id = v_k and prompt_hash = v_prompt;

  assert v_a is not null, 'l''étage 1 n''a rien retenu';
  assert v_b is not null, 'l''étage 2 n''a rien retenu';
  assert v_a <> v_b, 'les deux étages pointent le même objet';
  assert v_a like '%/cards/%', format('le rendu n''est pas rangé avec les cartes: %s', v_a);
  assert v_b like '%/custom/%', format('le visuel custom n''est pas rangé à part: %s', v_b);

  -- Un hash de rendu inconnu ne trouve rien, même sur un kit qui a des visuels.
  assert public.rendered_asset_path(v_k, repeat('f', 64)) is null,
    'un contenu jamais rendu a trouvé un chemin';
end
$t3$;

rollback;
