-- ============================================================================
-- La plateforme décide de l'ÉLIGIBILITÉ, elle ne refuse personne
-- ============================================================================
-- `20260914120000_platform_qualification.sql` a été écrite sur une prémisse
-- fausse, et c'est corrigé ici plutôt que contourné :
--
--   « Les autres sont refusées à l'inscription, avec une phrase qui dit
--     pourquoi. »
--
-- ⚠ L'ANCIENNE OFFRE N'EST PAS RETIRÉE DE LA VENTE. `starter`, `practice` et
-- `signature` sont toujours au catalogue, toujours sur `/pricing`, et elles ne
-- promettent AUCUNE publication : elles livrent des fichiers et un texte à
-- coller. Refuser à l'inscription quelqu'un qui est sur Wix, c'est donc
-- refuser une cliente qu'on sait encore servir — et lui dire non pour un
-- service qu'elle ne demandait pas.
--
-- La plateforme ne répond donc plus « dedans ou dehors ». Elle répond
-- « qu'est-ce que je peux vous vendre » :
--
--   WordPress            la nouvelle offre, qui promet de publier
--   toute autre chose    l'ancienne offre, qui ne promet que d'écrire
--
-- ── POURQUOI UNE COLONNE SUR `plans`, ET PAS UNE SECONDE MÉCANIQUE ──────────
--
-- Le lot 2 a posé `plans.sellable` : une donnée lue par le CHEMIN DE CHECKOUT
-- avant tout appel à Stripe, jamais par l'affichage, jamais par un CHECK sur
-- `purchases` qui arriverait après l'argent. Cette colonne-ci est la seconde
-- moitié de la même phrase, au même endroit, lue par le même point de passage.
--
-- Deux raisons de refuser une vente, une seule porte :
--
--   sellable = false                      on ne sait pas livrer ce SKU, à
--                                         PERSONNE. Global.
--   requires_publishable_platform = true  on ne sait pas le livrer à ELLE,
--                                         parce qu'on ne publiera pas sur sa
--                                         plateforme. Dépend de sa réponse.
--
-- Écrire un second mécanisme aurait donné deux endroits où une vente peut être
-- refusée, et c'est exactement la forme du défaut que ce lot corrige : une
-- règle construite d'un côté et jamais branchée de l'autre.
-- ============================================================================

alter table public.plans
  add column if not exists requires_publishable_platform boolean not null default false;

comment on column public.plans.requires_publishable_platform is
  'True when this SKU promises that Eklio PUBLISHES pages on her own site, which we can only do where site_platforms.status is accepted. Read by the CHECKOUT PATH beside plans.sellable - the same single door, the second reason it can close. This is eligibility, NOT refusal: someone on an unreachable platform is still sold the previous offer, which promises files and copy to paste and never promised publication. False on every legacy tier for that reason, and on identity_addon, which delivers files.';

-- >>> PUBLISHABLE PLATFORM DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ LES QUATRE DE LA NOUVELLE OFFRE, NOMMÉES UNE PAR UNE. Pas
-- `where sort_order >= 10` : une future ligne de catalogue deviendrait
-- silencieusement conditionnée à WordPress, et `identity_addon`, qui est de la
-- même génération, ne l'est PAS — il livre un logo et des exports, qui
-- n'exigent aucun site.
update public.plans set requires_publishable_platform = true
 where tier = any (array['foundation', 'roster', 'fill_solo', 'fill_practice']);

-- <<< PUBLISHABLE PLATFORM DATA <<<

-- ── L'auto-contrôle ─────────────────────────────────────────────────────────
do $$
declare
  v_gated int;
  v_free  int;
  v_wp    text;
begin
  select count(*) into v_gated from public.plans where requires_publishable_platform;
  if v_gated <> 4 then
    raise exception
      'eligibility: % SKU conditionnés à la plateforme au lieu de 4. Un tier renommé laisserait une promesse de publication sans condition.',
      v_gated;
  end if;

  -- ⚠ L'ANCIENNE OFFRE DOIT RESTER INCONDITIONNELLE. C'est toute la correction :
  -- si elle se retrouvait conditionnée, on refuserait à nouveau des clientes
  -- qu'on sait servir, et par la porte même qui devait cesser de le faire.
  select count(*) into v_free
    from public.plans
   where tier = any (array['starter', 'practice', 'signature', 'free', 'identity_addon'])
     and requires_publishable_platform;
  if v_free <> 0 then
    raise exception
      'eligibility: % ligne(s) de l''ancienne offre conditionnée(s) à la plateforme. Elles ne promettent aucune publication.',
      v_free;
  end if;

  -- ⚠ ET IL FAUT QU'IL EXISTE UNE PLATEFORME ACCEPTÉE. Sans elle, les quatre
  -- SKU conditionnés ne seraient vendables à personne — la condition serait un
  -- refus déguisé, ce que ce fichier existe pour défaire.
  select string_agg(id, ', ') into v_wp
    from public.site_platforms where status = 'accepted';
  if v_wp is null then
    raise exception
      'eligibility: aucune plateforme acceptée dans site_platforms. Conditionner quatre SKU à un ensemble vide les rend invendables.';
  end if;
  raise notice 'eligibility: plateformes acceptées = %', v_wp;
end $$;
