-- ============================================================================
-- Les trois corrections que le seed défaisait
-- ============================================================================
-- `20260914091227`, `20260914091622` et `20260914134552` sont des migrations de
-- DONNÉES : elles corrigent trois lignes écrites par des blocs antérieurs
-- (`SITE PLATFORM DATA`, `OFFER SKU DATA`). Aucune des trois ne porte de bloc
-- marqué, parce qu'aucune n'a jamais été committée — elles ont été appliquées
-- par `apply_migration` et récupérées depuis `schema_migrations.statements`.
--
-- ⚠ CE FICHIER EXISTE PARCE QUE LE SEED REJOUAIT PAR-DESSUS ELLES.
--
-- `supabase/seed.sql` est rejoué APRÈS toutes les migrations. Il porte
-- désormais `SITE PLATFORM DATA`, dont l'`on conflict do update set status =
-- excluded.status` remettait Squarespace en « conditional » — alors que la
-- production dit « refused » depuis le 14 septembre. Même mécanique pour
-- `OFFER SKU DATA` et les colonnes `sellable` / `requires_publishable_platform`
-- : le bloc n'en parle pas, donc il ne les écrase pas, mais il réinsère les
-- lignes et rien ne garantissait ensuite leur valeur.
--
-- C'est exactement l'accident que `check_seed_mirrors.sh` raconte en tête de
-- fichier : « un bloc postérieur qui corrige une ligne qu'un bloc antérieur
-- écrit aussi doit être miroité APRÈS lui, sinon la copie antérieure gagne au
-- reset ». Trouvé cette fois par lecture, pas par un rendu qui ne correspondait
-- plus à son empreinte.
--
-- ── POURQUOI UNE MIGRATION DE PLUS, ET PAS UNE RETOUCHE DES TROIS ───────
--
-- Les onze fichiers du 14 septembre sont OCTET POUR OCTET ce que la production
-- a exécuté — c'est vérifiable, et `scripts/verify-recovered-migrations.sh` le
-- vérifie. Y ajouter ne serait-ce qu'une ligne de commentaire pour poser des
-- marqueurs casserait cette preuve, et le README interdit déjà de modifier une
-- migration appliquée : « la correction est une nouvelle migration ».
--
-- Celle-ci est donc un NO-OP en production — les trois valeurs y sont déjà —
-- et sa seule fonction est de faire exister les marqueurs, pour que le miroir
-- de seed soit vérifié mécaniquement à chaque exécution du script.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Squarespace : refusé, et pourquoi
-- ---------------------------------------------------------------------------
-- >>> SQUARESPACE ANSWER (mirrored verbatim in supabase/seed.sql) >>>

update public.site_platforms
   set status = 'refused',
       notice = 'We do not publish to Squarespace. Its API covers store orders and forms, not website pages, so there is no way for us to put anything on your site for you. Everything we write for you would still be yours to paste, but putting it in place is the part we could not do.'
 where id = 'squarespace';

-- <<< SQUARESPACE ANSWER <<<


-- ---------------------------------------------------------------------------
-- 2. Les trois SKU qui ne sont pas livrables
-- ---------------------------------------------------------------------------
-- >>> SKU SELLABILITY (mirrored verbatim in supabase/seed.sql) >>>

update public.plans set sellable = false
 where tier = any (array['roster_seat', 'fill_solo', 'fill_practice']);

-- <<< SKU SELLABILITY <<<


-- ---------------------------------------------------------------------------
-- 3. Les quatre SKU qui promettent une publication
-- ---------------------------------------------------------------------------
-- >>> PLATFORM ELIGIBILITY (mirrored verbatim in supabase/seed.sql) >>>

update public.plans set requires_publishable_platform = true
 where tier = any (array['foundation', 'roster', 'fill_solo', 'fill_practice']);

-- <<< PLATFORM ELIGIBILITY <<<


-- ---------------------------------------------------------------------------
-- 4. Garde-fous — l'état final, et le fait que la garde ne soit pas vide
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  if (select status from public.site_platforms where id = 'squarespace') <> 'refused' then
    raise exception 'corrections: Squarespace n''est pas refusé. Migration abandonnée.';
  end if;
  if (select notice from public.site_platforms where id = 'squarespace')
     not like '%covers store orders and forms%' then
    raise exception 'corrections: Squarespace est refusé sans dire pourquoi. Migration abandonnée.';
  end if;

  select count(*) into v_n from public.plans
   where tier = any (array['roster_seat','fill_solo','fill_practice']) and not sellable;
  if v_n <> 3 then
    raise exception
      'corrections: % des 3 SKU non livrables sont bloqués. Migration abandonnée.', v_n;
  end if;

  select count(*) into v_n from public.plans where requires_publishable_platform;
  if v_n <> 4 then
    raise exception
      'corrections: % SKU conditionnés à la plateforme au lieu de 4. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET LA GARDE N'EST PAS VIDE. Les trois blocs ci-dessus ne valent que s'il
  -- reste quelque chose à vendre : « tout est bloqué » passerait chacune des
  -- assertions précédentes sur le compte, et serait une panne complète.
  select count(*) into v_n from public.plans where sellable;
  if v_n < 1 then
    raise exception 'corrections: plus rien n''est vendable. Migration abandonnée.';
  end if;
  if exists (select 1 from public.plans
              where tier = any (array['starter','practice','signature','free','identity_addon'])
                and requires_publishable_platform) then
    raise exception
      'corrections: une ligne de l''ancienne offre est conditionnée à la plateforme. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Aucun. Ces trois valeurs SONT l'état de la production depuis le
--   14 septembre ; les défaire rouvrirait à la vente trois SKU qui ne se
--   livrent pas et remettrait Squarespace en « on vous le dira ».
