-- ============================================================================
-- Eklio — une image générée UNE SEULE FOIS, à deux niveaux
-- ============================================================================
-- Deux chemins, deux coûts, une seule règle.
--
--   * le RENDU VECTORIEL est gratuit en argent et cher en temps : Satori plus
--     resvg, une seconde environ par carte, trente cartes par mois par
--     abonnée. Le redéposer à chaque affichage, c'est une seconde d'attente
--     pour rien et un objet de stockage de plus à chaque fois.
--   * le VISUEL CUSTOM appelle une API facturée à l'image. Le regénérer, c'est
--     payer deux fois le même pixel.
--
-- La règle est la même des deux côtés : AVANT DE RENDRE, ON REGARDE SI ÇA
-- EXISTE. Ce qui change est ce qu'on hache — un payload pour l'un, un prompt
-- pour l'autre.
--
-- ── ⚠ LE GRAIN : LE KIT, PAS LA PERSONNE ────────────────────────────────
--
-- Le brief du chantier écrit `user_id` sur ces tables. Elles portent
-- `brand_kit_id`, et pour une raison qui se voit dans le chemin de stockage :
-- `20260903090000` a posé `{brand_kit_id}/…` comme convention du bucket, et la
-- policy qui garde ces objets (`brand_kit_asset_path_owner`) lit ce premier
-- segment. Un asset clefé sur la personne aurait un chemin qui ne correspond à
-- rien, ou une seconde convention de chemin à côté de la première.
--
-- Et c'est aussi le bon grain : un rendu dépend de la PALETTE, qui appartient à
-- une marque. Deux kits d'une même praticienne ont deux palettes et ne
-- partagent donc jamais un rendu, même à payload identique — ce que le hash
-- dit déjà, puisque la palette est dedans.
--
-- Les CRÉDITS, eux, restent par personne (`20260920140100`) : ils suivent
-- l'abonnement. Le décompte et l'objet ne sont pas au même étage, et c'est
-- voulu.
-- ============================================================================


-- ============================================================================
-- 1. rendered_assets — le cache de rendu, déduit du hash
-- ============================================================================
create table if not exists public.rendered_assets (
  id            uuid     primary key default gen_random_uuid(),
  brand_kit_id  uuid     not null references public.brand_kits (id) on delete cascade,
  -- SHA-256 de (archetype_key + payload normalisé + palette + typographie +
  -- version du moteur), en hexadécimal minuscule. Le CHECK porte sur la FORME,
  -- pas sur le contenu : la base ne peut pas recalculer le hash, mais elle
  -- peut refuser ce qui n'est pas un SHA-256.
  content_hash  text     not null,
  archetype_key text     not null references public.content_archetypes (id),
  palette_key   text     not null,
  storage_path  text     not null,
  width         integer  not null,
  height        integer  not null,
  bytes         integer  not null,
  render_ms     integer  not null,
  created_at    timestamptz not null default now(),

  -- ⚠ LA CONTRAINTE QUI EST TOUT LE SUJET. Deux rendus du même contenu pour le
  -- même kit ne peuvent pas coexister ; le second appel trouve le premier.
  constraint rendered_assets_kit_hash_key unique (brand_kit_id, content_hash),

  constraint rendered_assets_hash_check check (content_hash ~ '^[0-9a-f]{64}$'),
  constraint rendered_assets_palette_check check (char_length(palette_key) between 1 and 64),
  constraint rendered_assets_path_check check (char_length(storage_path) between 1 and 512),
  constraint rendered_assets_dims_check check (width > 0 and height > 0),
  constraint rendered_assets_bytes_check check (bytes > 0),
  constraint rendered_assets_render_ms_check check (render_ms >= 0),
  -- ⚠ LE CHEMIN COMMENCE PAR LE KIT. C'est ce que la policy de storage.objects
  -- lit (`brand_kit_asset_path_owner`), donc un chemin qui ne respecte pas la
  -- convention produit un objet que personne ne peut lire -- visible seulement
  -- au moment où elle ouvre le post.
  constraint rendered_assets_path_prefix_check
    check (storage_path like (brand_kit_id::text || '/%'))
);

comment on table public.rendered_assets is
  'The render cache. UNIQUE (brand_kit_id, content_hash) is the whole point: rendering the same content twice for the same kit is impossible, the second call finds the first. Changing a word changes the hash and therefore produces a new asset; merely displaying the post produces none.';
comment on column public.rendered_assets.content_hash is
  'SHA-256 of (archetype_key + normalised payload + palette + typography + engine version), lowercase hex. The engine version is IN the hash on purpose: a change to the composition engine must invalidate every cached render, and a cache that survives its renderer serves last month''s bug forever.';
comment on column public.rendered_assets.storage_path is
  'Path inside the private content-assets bucket. Starts with the kit id because that is what the storage.objects policy reads; a path breaking the convention yields an object nobody can read, and it only shows up when she opens the post.';

create index if not exists rendered_assets_kit_idx on public.rendered_assets (brand_kit_id);

alter table public.rendered_assets enable row level security;

drop policy if exists "rendered_assets_select_own"    on public.rendered_assets;
drop policy if exists "rendered_assets_insert_denied" on public.rendered_assets;
drop policy if exists "rendered_assets_update_denied" on public.rendered_assets;
drop policy if exists "rendered_assets_delete_denied" on public.rendered_assets;

create policy "rendered_assets_select_own" on public.rendered_assets
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = rendered_assets.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "rendered_assets_insert_denied" on public.rendered_assets
  for insert with check (false);
create policy "rendered_assets_update_denied" on public.rendered_assets
  for update using (false);
create policy "rendered_assets_delete_denied" on public.rendered_assets
  for delete using (false);


-- ============================================================================
-- 2. custom_visual_generations — le seul chemin qui coûte de l'argent
-- ============================================================================
create table if not exists public.custom_visual_generations (
  id            uuid     primary key default gen_random_uuid(),
  brand_kit_id  uuid     not null references public.brand_kits (id) on delete cascade,
  -- Le post pour lequel elle a demandé l'image. ON DELETE SET NULL : supprimer
  -- un post ne doit pas effacer la trace d'une dépense.
  content_item_id uuid   references public.content_items (id) on delete set null,
  prompt_hash   text     not null,
  model         text     not null,
  quality       text     not null,
  size          text     not null,
  storage_path  text     not null,
  cost_usd      numeric(12, 6) not null,
  -- La ligne du ledger qui a payé. NOT NULL : une image produite sans
  -- réservation de crédit est exactement ce que cette table existe pour rendre
  -- impossible.
  --
  -- ⚠ `on delete cascade`, ET LE PREMIER JET DISAIT `restrict`. C'était le
  -- réflexe (« une image ne doit pas survivre à la preuve de son paiement »)
  -- et le garde-fou l'a attrapé : `credit_ledger.user_id` est lui-même
  -- `on delete cascade`, donc un RESTRICT ici rendait la suppression d'un
  -- compte impossible — la même classe de défaut que le trigger append-only
  -- de `20260920140100` avait produite, trouvée de la même façon.
  --
  -- Et le RESTRICT ne gardait rien de plus : ce qui interdit une image sans
  -- paiement est le NOT NULL, pas la règle de suppression. La règle de
  -- suppression ne gouverne que le jour où la ligne de ledger disparaît, ce
  -- qui n'arrive qu'à la suppression du compte — où tout part de toute façon.
  reservation_id uuid    not null references public.credit_ledger (id) on delete cascade,
  created_at    timestamptz not null default now(),

  constraint custom_visual_kit_prompt_key unique (brand_kit_id, prompt_hash),
  constraint custom_visual_hash_check check (prompt_hash ~ '^[0-9a-f]{64}$'),
  constraint custom_visual_quality_check check (quality in ('low', 'medium')),
  constraint custom_visual_size_check check (size ~ '^[0-9]{3,5}x[0-9]{3,5}$'),
  constraint custom_visual_model_check check (btrim(model) <> ''),
  constraint custom_visual_cost_check check (cost_usd >= 0),
  constraint custom_visual_path_check check (char_length(storage_path) between 1 and 512),
  constraint custom_visual_path_prefix_check
    check (storage_path like (brand_kit_id::text || '/%'))
);

comment on table public.custom_visual_generations is
  'Every paid image, once. UNIQUE (brand_kit_id, prompt_hash): a prompt already generated for this kit is served from storage and never regenerated, so the credit is spent on the FIRST generation only. reservation_id is NOT NULL -- an image produced without a credit reservation is exactly what this table exists to make impossible -- and ON DELETE CASCADE, because the NOT NULL is what holds that rule while a RESTRICT would only have made accounts undeletable.';
comment on column public.custom_visual_generations.quality is
  'low by default, medium at most. Both the model and this setting are driven by environment variables in the pipeline; the CHECK bounds what any of them may write, so a misconfigured variable cannot buy the expensive tier.';

create index if not exists custom_visual_kit_idx on public.custom_visual_generations (brand_kit_id);

alter table public.custom_visual_generations enable row level security;

drop policy if exists "custom_visual_select_own"    on public.custom_visual_generations;
drop policy if exists "custom_visual_insert_denied" on public.custom_visual_generations;
drop policy if exists "custom_visual_update_denied" on public.custom_visual_generations;
drop policy if exists "custom_visual_delete_denied" on public.custom_visual_generations;

create policy "custom_visual_select_own" on public.custom_visual_generations
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = custom_visual_generations.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "custom_visual_insert_denied" on public.custom_visual_generations
  for insert with check (false);
create policy "custom_visual_update_denied" on public.custom_visual_generations
  for update using (false);
create policy "custom_visual_delete_denied" on public.custom_visual_generations
  for delete using (false);


-- ============================================================================
-- 3. illustration_library — les objets monoline, versionnés
-- ============================================================================
create table if not exists public.illustration_library (
  id            uuid     primary key default gen_random_uuid(),
  slug          text     not null,
  version       smallint not null default 1,
  archetype_key text     references public.content_archetypes (id),
  -- Le SVG lui-même. En base et non dans le bucket : ce sont des objets
  -- monoline de quelques centaines d'octets que le moteur INLINE dans sa
  -- composition -- un aller-retour de stockage par carte pour 400 octets
  -- coûterait plus que le dessin.
  svg           text     not null,
  active        boolean  not null default true,
  created_at    timestamptz not null default now(),

  constraint illustration_library_slug_version_key unique (slug, version),
  constraint illustration_library_slug_check check (slug ~ '^[a-z0-9_]{2,48}$'),
  constraint illustration_library_version_check check (version >= 1),
  -- Une borne, pas une validation. Un SVG de 64 Ko n'est pas un objet
  -- monoline, c'est une illustration importée -- et il ferait exploser le
  -- temps de rasterisation de chaque carte qui le porte.
  constraint illustration_library_svg_check
    check (char_length(svg) between 20 and 8192 and svg like '<svg%')
);

comment on table public.illustration_library is
  'Monoline SVG objects, versioned and attributed per archetype. Held in the database rather than the bucket: these are a few hundred bytes each and the engine inlines them into its composition -- one storage round trip per card for 400 bytes would cost more than the drawing. Versioned because a redrawn object must not silently change last month''s rendered cards, whose hash was taken over the old one.';

create index if not exists illustration_library_archetype_idx
  on public.illustration_library (archetype_key, slug)
  where active;

alter table public.illustration_library enable row level security;

drop policy if exists "illustration_library_select_all"    on public.illustration_library;
drop policy if exists "illustration_library_insert_denied" on public.illustration_library;
drop policy if exists "illustration_library_update_denied" on public.illustration_library;
drop policy if exists "illustration_library_delete_denied" on public.illustration_library;

create policy "illustration_library_select_all" on public.illustration_library
  for select to authenticated using (true);
create policy "illustration_library_insert_denied" on public.illustration_library
  for insert with check (false);
create policy "illustration_library_update_denied" on public.illustration_library
  for update using (false);
create policy "illustration_library_delete_denied" on public.illustration_library
  for delete using (false);


-- ============================================================================
-- 4. background_library — les fonds, et leur fenêtre anti-collision
-- ============================================================================
create table if not exists public.background_library (
  id           uuid     primary key default gen_random_uuid(),
  slug         text     not null unique,
  storage_path text     not null,
  -- Le traitement : ce n'est pas une photographie de catalogue, c'est un fond
  -- neutre. Le champ existe pour que le moteur choisisse un fond dont le
  -- traitement s'accorde à la palette, pas pour décrire une scène.
  treatment    text     not null,
  active       boolean  not null default true,
  created_at   timestamptz not null default now(),

  constraint background_library_slug_check check (slug ~ '^[a-z0-9_]{2,48}$'),
  constraint background_library_treatment_check
    check (treatment in ('paper', 'linen', 'wash', 'grain', 'shadow'))
);

comment on table public.background_library is
  'Neutral photographic backgrounds. `treatment` describes the surface, never a scene: the engine picks a background whose treatment suits the palette, and a catalogue of scenes would be a second editorial axis nobody asked for.';

alter table public.background_library enable row level security;

drop policy if exists "background_library_select_all"    on public.background_library;
drop policy if exists "background_library_insert_denied" on public.background_library;
drop policy if exists "background_library_update_denied" on public.background_library;
drop policy if exists "background_library_delete_denied" on public.background_library;

create policy "background_library_select_all" on public.background_library
  for select to authenticated using (true);
create policy "background_library_insert_denied" on public.background_library
  for insert with check (false);
create policy "background_library_update_denied" on public.background_library
  for update using (false);
create policy "background_library_delete_denied" on public.background_library
  for delete using (false);


create table if not exists public.background_assignments (
  brand_kit_id uuid not null references public.brand_kits (id) on delete cascade,
  asset_id     uuid not null references public.background_library (id) on delete cascade,
  assigned_at  timestamptz not null default now(),

  -- La même forme que `topic_assignments`, et pour la même raison : c'est la
  -- clef primaire sans le mois qui tient « pas deux fois le même fond ».
  constraint background_assignments_pkey primary key (brand_kit_id, asset_id)
);

comment on table public.background_assignments is
  'Which background went to which kit. Same shape as topic_assignments and for the same reason: the primary key without a month is what holds "not the same background twice", and the 90-day (state, modality) window is applied by next_background_for_kit rather than restated here.';

create index if not exists background_assignments_asset_idx
  on public.background_assignments (asset_id, assigned_at desc);

alter table public.background_assignments enable row level security;

drop policy if exists "background_assignments_select_own"    on public.background_assignments;
drop policy if exists "background_assignments_insert_denied" on public.background_assignments;
drop policy if exists "background_assignments_update_denied" on public.background_assignments;
drop policy if exists "background_assignments_delete_denied" on public.background_assignments;

create policy "background_assignments_select_own" on public.background_assignments
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = background_assignments.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "background_assignments_insert_denied" on public.background_assignments
  for insert with check (false);
create policy "background_assignments_update_denied" on public.background_assignments
  for update using (false);
create policy "background_assignments_delete_denied" on public.background_assignments
  for delete using (false);


-- ============================================================================
-- 5. next_background_for_kit — la même fenêtre que les sujets
-- ============================================================================
-- ⚠ LA MÊME FONCTION `topic_collision_window()`, RÉUTILISÉE ENTIÈRE. Deux
-- fenêtres de 90 jours écrites séparément sont deux fenêtres qui finiront par
-- valoir 90 et 60.

create or replace function public.next_background_for_kit(p_brand_kit_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with kit as (
    select coalesce(pb.modality_ids, '{}') as modalities,
           upper(nullif(btrim(coalesce(pb.state, '')), '')) as state_code,
           pr.user_id as user_id
      from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
      left join public.project_briefs pb on pb.project_id = pr.id
     where bk.id = p_brand_kit_id
  )
  select b.id
    from public.background_library b
   cross join kit k
   where b.active
     and not exists (
       select 1 from public.background_assignments ba
        where ba.brand_kit_id = p_brand_kit_id and ba.asset_id = b.id
     )
     and not exists (
       select 1
         from public.background_assignments ba
         join public.brand_kits   obk on obk.id = ba.brand_kit_id
         join public.projects     opr on opr.id = obk.project_id
         left join public.project_briefs opb on opb.project_id = opr.id
        where ba.asset_id = b.id
          and ba.assigned_at > now() - public.topic_collision_window()
          and opr.user_id is distinct from k.user_id
          and k.state_code is not null
          and upper(nullif(btrim(coalesce(opb.state, '')), '')) = k.state_code
          and coalesce(opb.modality_ids, '{}') && k.modalities
     )
   order by b.slug
   limit 1
$$;

comment on function public.next_background_for_kit(uuid) is
  'The next unused background for this kit, honouring the same 90-day (state, modality) window as topics -- via topic_collision_window(), reused whole rather than restated, because two separately-written 90-day windows end up being 90 and 60. Ordered by slug, so it is deterministic. NULL when the library is exhausted.';

revoke all on function public.next_background_for_kit(uuid) from public, anon, authenticated;
grant execute on function public.next_background_for_kit(uuid) to service_role;


-- ============================================================================
-- 6. Le bucket privé, et qui peut y lire
-- ============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('content-assets', 'content-assets', false, 10485760,
        array['image/svg+xml', 'image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

-- ⚠ LECTURE SEULE POUR LE CLIENT, ET AUCUNE ÉCRITURE DU TOUT.
--
-- `brand-assets` accorde INSERT et UPDATE à `authenticated`, parce que le
-- navigateur y dépose via une URL d'upload signée. Rien de tel ici : chaque
-- octet de ce bucket est écrit par le pipeline, côté serveur, en service_role.
-- Donner au client une policy d'écriture ouvrirait un chemin qu'aucun code
-- n'emprunte — et un chemin que personne n'emprunte est un chemin que
-- personne ne surveille.
--
-- La lecture, elle, est nécessaire : `/app/content/[id]` signe l'URL avec le
-- client de session, et signer demande le droit de lire.
--
-- Le prédicat est `brand_kit_asset_path_owner` (20260903090000), réutilisé
-- tel quel : possédé ET payé, via brand_kit_entitled. Un kit dont l'achat a
-- été annulé cesse de servir ses images, sans une ligne de plus.
drop policy if exists "content_assets_storage_select_own_paid" on storage.objects;
create policy "content_assets_storage_select_own_paid"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'content-assets'
    and public.brand_kit_asset_path_owner(name)
  );


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_user uuid := gen_random_uuid();
  v_proj uuid := gen_random_uuid();
  v_kit  uuid := gen_random_uuid();
  v_kit2 uuid := gen_random_uuid();
  v_proj2 uuid := gen_random_uuid();
  v_user2 uuid := gen_random_uuid();
  v_res  jsonb;
  v_bg1  uuid;
  v_bg2  uuid;
  v_hash text := repeat('a', 64);
  v_mod  text;
  v_per  text;
  v_n    integer;
  t      text;
begin
  foreach t in array array['rendered_assets', 'custom_visual_generations',
                           'illustration_library', 'background_library',
                           'background_assignments'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'assets: RLS absente sur %', t;
    end if;
    if exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd in ('INSERT', 'UPDATE', 'DELETE')
         and coalesce(qual, with_check) is distinct from 'false'
    ) then
      raise exception 'assets: % porte une policy d''écriture qui n''est pas `false`', t;
    end if;
  end loop;

  if has_function_privilege('authenticated', 'public.next_background_for_kit(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated peut exécuter next_background_for_kit';
  end if;

  -- ---- le bucket est privé, et sans policy d'écriture pour le client -----
  if (select public from storage.buckets where id = 'content-assets') then
    raise exception 'le bucket content-assets est public.';
  end if;
  if exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'content_assets%' and cmd <> 'SELECT'
  ) then
    raise exception 'content-assets accorde une écriture au client; tout y est écrit côté serveur.';
  end if;

  -- ---- la déduplication mord ---------------------------------------------
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_user, 'assets@example.invalid');
  insert into public.projects (id, user_id, name) values (v_proj, v_user, 'A');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_proj, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  insert into public.rendered_assets
    (brand_kit_id, content_hash, archetype_key, palette_key, storage_path,
     width, height, bytes, render_ms)
  values (v_kit, v_hash, 'single_statement', 'sage', v_kit::text || '/a.png',
          1080, 1350, 40000, 900);

  begin
    insert into public.rendered_assets
      (brand_kit_id, content_hash, archetype_key, palette_key, storage_path,
       width, height, bytes, render_ms)
    values (v_kit, v_hash, 'single_statement', 'sage', v_kit::text || '/b.png',
            1080, 1350, 40000, 900);
    raise exception 'le même contenu a été rendu deux fois pour le même kit.';
  exception when unique_violation then null;
  end;

  -- ---- ⚠ UN CHEMIN QUI NE COMMENCE PAS PAR LE KIT EST REFUSÉ -------------
  -- La policy de storage.objects le lirait comme « pas à elle », et l'image
  -- serait invisible au moment où elle ouvre le post -- pas avant.
  begin
    insert into public.rendered_assets
      (brand_kit_id, content_hash, archetype_key, palette_key, storage_path,
       width, height, bytes, render_ms)
    values (v_kit, repeat('b', 64), 'single_statement', 'sage', 'ailleurs/c.png',
            1080, 1350, 40000, 900);
    raise exception 'un chemin de stockage hors convention a été accepté.';
  exception when check_violation then null;
  end;

  -- ---- un hash qui n'est pas un SHA-256 est refusé -----------------------
  begin
    insert into public.rendered_assets
      (brand_kit_id, content_hash, archetype_key, palette_key, storage_path,
       width, height, bytes, render_ms)
    values (v_kit, 'pas-un-hash', 'single_statement', 'sage', v_kit::text || '/d.png',
            1080, 1350, 40000, 900);
    raise exception 'un content_hash qui n''est pas un SHA-256 a été accepté.';
  exception when check_violation then null;
  end;

  -- ---- ⚠ AUCUNE IMAGE PAYANTE SANS RÉSERVATION DE CRÉDIT ----------------
  begin
    insert into public.custom_visual_generations
      (brand_kit_id, prompt_hash, model, quality, size, storage_path, cost_usd,
       reservation_id)
    values (v_kit, repeat('c', 64), 'gpt-image-2', 'low', '1024x1536',
            v_kit::text || '/v.png', 0.02, null);
    raise exception 'une image payante a été enregistrée sans réservation de crédit.';
  exception when not_null_violation then null;
  end;

  -- Avec une vraie réservation, elle passe -- et une seconde fois, non.
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_user, 'assets guard rail', 'migration 20260920150300', now() + interval '1 day');
  v_res := public.reserve_credit(v_user, 'custom_visual', 'guard rail');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'la réservation du garde-fou a été refusée: %', v_res;
  end if;

  insert into public.custom_visual_generations
    (brand_kit_id, prompt_hash, model, quality, size, storage_path, cost_usd, reservation_id)
  values (v_kit, repeat('c', 64), 'gpt-image-2', 'low', '1024x1536',
          v_kit::text || '/v.png', 0.02, (v_res ->> 'reservation_id')::uuid);

  begin
    insert into public.custom_visual_generations
      (brand_kit_id, prompt_hash, model, quality, size, storage_path, cost_usd, reservation_id)
    values (v_kit, repeat('c', 64), 'gpt-image-2', 'low', '1024x1536',
            v_kit::text || '/w.png', 0.02, (v_res ->> 'reservation_id')::uuid);
    raise exception 'le même prompt a été facturé deux fois pour le même kit.';
  exception when unique_violation then null;
  end;

  -- ---- la qualité est bornée par la ligne --------------------------------
  begin
    insert into public.custom_visual_generations
      (brand_kit_id, prompt_hash, model, quality, size, storage_path, cost_usd, reservation_id)
    values (v_kit, repeat('d', 64), 'gpt-image-2', 'high', '1024x1536',
            v_kit::text || '/x.png', 0.19, (v_res ->> 'reservation_id')::uuid);
    raise exception 'la qualité `high` a été acceptée; une variable mal réglée peut acheter le palier cher.';
  exception when check_violation then null;
  end;

  -- ---- ⚠ LA FENÊTRE DE FOND, LA MÊME QUE CELLE DES SUJETS ---------------
  insert into public.background_library (slug, storage_path, treatment)
  values ('probe_linen_01', 'library/probe_linen_01.jpg', 'linen') returning id into v_bg1;
  insert into public.background_library (slug, storage_path, treatment)
  values ('probe_wash_02', 'library/probe_wash_02.jpg', 'wash') returning id into v_bg2;

  insert into auth.users (id, email) values (v_user2, 'assets2@example.invalid');
  insert into public.projects (id, user_id, name) values (v_proj2, v_user2, 'B');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_proj2, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_kit2, v_proj2);

  if public.next_background_for_kit(v_kit) is null then
    raise exception 'aucun fond disponible alors que la bibliothèque en porte deux.';
  end if;

  insert into public.background_assignments (brand_kit_id, asset_id) values (v_kit, v_bg1);

  -- Elle ne le reçoit pas deux fois.
  if public.next_background_for_kit(v_kit) = v_bg1 then
    raise exception 'un fond déjà attribué a été reproposé au même kit.';
  end if;

  -- Et la consœur du même État, même modalité, ne le reçoit pas non plus.
  if public.next_background_for_kit(v_kit2) = v_bg1 then
    raise exception 'le même fond a été servi à deux praticiennes de CA pratiquant la même modalité.';
  end if;

  -- Mais elle reçoit bien l'autre : la fenêtre borne un asset, pas la
  -- bibliothèque.
  if public.next_background_for_kit(v_kit2) is distinct from v_bg2 then
    raise exception 'la fenêtre a fermé toute la bibliothèque au lieu d''un seul fond.';
  end if;

  -- ---- la bibliothèque d'illustrations refuse ce qui n'est pas monoline --
  begin
    insert into public.illustration_library (slug, svg)
    values ('probe_circle', '<svg>' || repeat('x', 9000) || '</svg>');
    raise exception 'un SVG de 9 Ko a été accepté comme objet monoline.';
  exception when check_violation then null;
  end;
  begin
    insert into public.illustration_library (slug, svg)
    values ('probe_circle', '<html>not an svg at all here</html>');
    raise exception 'un document qui n''est pas un SVG a été accepté.';
  exception when check_violation then null;
  end;

  -- ---- versionnage : deux versions d'un même slug coexistent -------------
  insert into public.illustration_library (slug, version, svg, archetype_key)
  values ('probe_circle', 1, '<svg viewBox="0 0 10 10"><circle r="4"/></svg>', 'cycle');
  insert into public.illustration_library (slug, version, svg, archetype_key)
  values ('probe_circle', 2, '<svg viewBox="0 0 10 10"><circle r="5"/></svg>', 'cycle');
  select count(*) into v_n from public.illustration_library where slug = 'probe_circle';
  if v_n <> 2 then
    raise exception 'deux versions d''un même objet ne coexistent pas (% ligne(s))', v_n;
  end if;

  -- ---- teardown ----------------------------------------------------------
  delete from public.illustration_library where slug = 'probe_circle';
  delete from public.background_library where id in (v_bg1, v_bg2);
  delete from auth.users where id in (v_user, v_user2);
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop policy   if exists "content_assets_storage_select_own_paid" on storage.objects;
--   delete from storage.buckets where id = 'content-assets';
--   drop function if exists public.next_background_for_kit(uuid);
--   drop table    if exists public.background_assignments;
--   drop table    if exists public.background_library;
--   drop table    if exists public.illustration_library;
--   drop table    if exists public.custom_visual_generations;
--   drop table    if exists public.rendered_assets;
