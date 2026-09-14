-- ============================================================================
-- `brand_kit_entitling_statuses()` — la moitié ARRIÈRE de l'accord
-- ============================================================================
-- L'accord a deux moitiés et elles vivent dans deux dépôts :
--
--   ici            `brand_kit_entitling_statuses()` rend la liste ;
--   frontend       `ENTITLING_STATUSES` (lib/billing/entitlements.ts) la
--                  transcrit, et `resolveEntitledTier` / `countUnpaidProjects`
--                  la passent à `.in("status", …)`.
--
-- Elles ont divergé, et le sens de la divergence dit pourquoi ce fichier
-- existe : la base disait `{paid, partially_refunded}`, les deux lectures
-- TypeScript filtraient `status = 'paid'` en dur. Une acheteuse partiellement
-- remboursée avait donc son kit OUVERT (cette fonction le disait) et se voyait
-- refuser en 402 toutes les surfaces au-dessus de `starter`.
--
-- ⚠ IL N'Y AVAIT PAS D'ÉPINGLE DE VALEUR DE CE CÔTÉ. `schema_fingerprint.
-- production.txt` porte bien une empreinte du corps de cette fonction, mais une
-- empreinte dit « quelque chose a changé » — elle ne dit pas CE QUE la fonction
-- rend, donc elle ne peut pas être comparée à ce que le frontend croit. Ce
-- fichier écrit la valeur en toutes lettres, pour qu'un lecteur des deux dépôts
-- puisse la comparer sans exécuter quoi que ce soit.
--
-- Son jumeau : eklio-frontend/lib/billing/__tests__/entitlements-single-source.test.ts
-- ============================================================================

begin;

do $$
declare
  v_statuses text[];
begin
  -- ── La valeur, en toutes lettres ──────────────────────────────────────
  select public.brand_kit_entitling_statuses() into v_statuses;

  assert v_statuses = array['paid', 'partially_refunded'],
    format(
      'brand_kit_entitling_statuses() rend %L. Le frontend transcrit '
      '{paid, partially_refunded} dans ENTITLING_STATUSES : les deux doivent '
      'dire la même chose, et le changement doit se faire des deux côtés.',
      v_statuses
    );

  -- ⚠ Une liste vide serait pire qu'une liste fausse. Côté base elle fermerait
  -- tous les kits ; côté frontend `.in("status", [])` ne rend aucune ligne et
  -- retirerait son palier à tout le monde. Dans les deux cas, sans erreur.
  assert coalesce(array_length(v_statuses, 1), 0) > 0,
    'brand_kit_entitling_statuses() est vide : plus personne n''a de droit';

  -- ── Le complément, et il n'est pas décoratif ───────────────────────────
  -- `refunded` et `disputed` sont REVERSED_STATUSES côté frontend. Si l'un des
  -- deux entrait ici, l'argent serait reparti et le kit resterait ouvert.
  assert not ('refunded' = any(v_statuses)),
    'un achat remboursé donne droit au kit';
  assert not ('disputed' = any(v_statuses)),
    'un achat contesté donne droit au kit';

  -- `pending` et `failed` : l'argent n'est jamais arrivé.
  assert not ('pending' = any(v_statuses)), 'un achat en attente donne droit au kit';
  assert not ('failed' = any(v_statuses)),  'un achat échoué donne droit au kit';
end $$;

-- ============================================================================
-- Et le chemin est parcouru : la fonction n'est pas seulement lue, elle décide
-- ============================================================================
-- ⚠ Épingler la valeur ne suffirait pas. Ce dépôt a déjà eu une énumération
-- soignée qui n'avait jamais tourné, et un garde-fou qui assertait son propre
-- seed. Donc : on écrit un achat `partially_refunded`, et on demande à
-- `brand_kit_entitled` — la fonction que le produit interroge réellement — si
-- le kit est ouvert.
do $$
declare
  v_user uuid := 'aaaaaaaa-0000-0000-0000-00000000e001';
  v_org  uuid := 'dddddddd-0000-0000-0000-00000000e001';
  v_proj uuid := 'bbbbbbbb-0000-0000-0000-00000000e001';
  v_kit  uuid := 'cccccccc-0000-0000-0000-00000000e001';
begin
  insert into auth.users (id, email) values (v_user, 'partial@example.com');

  -- `projects_bind_organization` exige que la propriétaire ait une
  -- organisation ; `handle_new_user` en crée une, mais ce test n'a pas de
  -- trigger sur `auth.users` garanti dans tous les ordres de replay, donc on
  -- la pose explicitement plutôt que d'espérer.
  insert into public.organizations (id, name) values (v_org, 'Partial')
    on conflict (id) do nothing;
  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
    values (v_org, v_user, 'owner', 'active', now())
    on conflict do nothing;

  insert into public.projects (id, user_id, organization_id, name)
    values (v_proj, v_user, v_org, 'P');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  insert into public.purchases
    (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values
    (v_user, v_proj, 'practice', 'cs_test_partially_refunded', 14900,
     'partially_refunded', now());

  -- La question, posée comme le produit la pose : en tant qu'ELLE.
  set local role authenticated;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_user)::text, true);

  assert public.brand_kit_entitled(v_kit),
    'un achat partiellement remboursé ferme le kit alors que '
    'brand_kit_entitling_statuses() le compte comme entitlant';

  -- ⚠ `kit_paid_access` n'est PAS exécutable par `authenticated` — c'est un
  -- helper interne, révoqué par `20260902090000_revoke_internal_function_
  -- surface.sql`, appelé depuis le corps d'autres SECURITY DEFINER. On sort
  -- donc du rôle pour l'interroger, en gardant la même identité : la question
  -- posée reste « et pour ELLE ? », seul le droit d'appeler change.
  reset role;
  assert public.kit_paid_access(v_kit) is null,
    'kit_paid_access refuse un kit que brand_kit_entitled ouvre';
end $$;

rollback;
