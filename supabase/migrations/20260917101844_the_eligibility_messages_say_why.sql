-- ============================================================================
-- Les messages d'éligibilité redisent POURQUOI
-- ============================================================================
-- `20260914134552_eligibility_is_not_refusal` a été appliquée en production
-- sous forme d'EXTRAIT : la prose avait été retirée en chemin, et avec elle la
-- moitié explicative de trois messages d'exception. Le fichier complet existait
-- sur `claude/foundation-lot3-wiring`, et il disait :
--
--   « … au lieu de 4. Un tier renommé laisserait une promesse de publication
--     sans condition. »
--   « … conditionnée(s) à la plateforme. Elles ne promettent aucune
--     publication. »
--   « … aucune plateforme acceptée dans site_platforms. Conditionner quatre SKU
--     à un ensemble vide les rend invendables. »
--
-- Là où l'extrait s'arrête au constat, la version longue dit la conséquence.
-- Un message qui dit ce qui est faux sans dire ce que ça casse envoie son
-- lecteur relire la migration ; c'est le moment où on ne la relit pas.
--
-- ⚠ POURQUOI UNE MIGRATION NEUVE ET PAS UNE RETOUCHE.
--
-- `20260914134552` est appliquée. Le README l'interdit en une ligne : « si un
-- horodatage est faux, la correction est une nouvelle migration — jamais une
-- modification d'une ancienne », et la raison vaut pour le contenu autant que
-- pour le nom. Un fichier appliqué est un compte rendu, pas un brouillon.
--
-- Celle-ci est donc un NO-OP en données — les quatre invariants tiennent déjà,
-- c'est justement ce qu'elle vérifie — et son seul effet est que le REJEU les
-- revérifie désormais avec des messages entiers.
-- ============================================================================

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

  select count(*) into v_free
    from public.plans
   where tier = any (array['starter', 'practice', 'signature', 'free', 'identity_addon'])
     and requires_publishable_platform;
  if v_free <> 0 then
    raise exception
      'eligibility: % ligne(s) de l''ancienne offre conditionnée(s) à la plateforme. Elles ne promettent aucune publication.',
      v_free;
  end if;

  select string_agg(id, ', ' order by id) into v_wp
    from public.site_platforms where status = 'accepted';
  if v_wp is null then
    raise exception
      'eligibility: aucune plateforme acceptée dans site_platforms. Conditionner quatre SKU à un ensemble vide les rend invendables.';
  end if;

  /*
   * ⚠ ET LA DEUXIÈME ASSERTION N'EST PAS VIDE.
   *
   * « zéro ligne de l'ancienne offre est conditionnée » est vrai de deux
   * façons : parce qu'aucune ne l'est, ou parce qu'il n'y en a plus. La
   * première fois que j'ai écrit cette garde, je l'ai écrite en comptant
   * `plans` — et ce compte ne pouvait PAS descendre sous quatre, puisque les
   * quatre lignes conditionnées sont elles-mêmes dans `plans`. Une garde
   * inatteignable, trouvée en la sabotant, pas en la relisant.
   *
   * Ce qu'il faut nommer, ce sont les cinq lignes que l'assertion 2 est censée
   * examiner. Si l'une disparaît, l'assertion cesse de la couvrir en silence.
   */
  select count(*) into v_free
    from public.plans
   where tier = any (array['starter', 'practice', 'signature', 'free', 'identity_addon']);
  if v_free <> 5 then
    raise exception
      'eligibility: % des 5 lignes de l''ancienne offre sont au catalogue — l''assertion qui les vérifie ne les voit plus toutes.',
      v_free;
  end if;

  raise notice 'eligibility: plateformes acceptées = %', v_wp;
end
$$;

-- ============================================================================
-- DOWN
-- ============================================================================
--   Aucun. Cette migration ne change aucune donnée ; elle n'ajoute que des
--   assertions au rejeu. La défaire, c'est retirer une vérification.
