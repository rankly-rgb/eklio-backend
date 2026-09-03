-- ============================================================================
-- Eklio — retirer de la surface anonyme les fonctions qui n'y ont rien à faire
--
-- Le README nomme ce défaut en tête, quatrième ligne du tableau : « anon reçoit
-- EXECUTE sur toute fonction créée ». C'est le défaut de PostgreSQL — toute
-- fonction naît avec `EXECUTE` accordé à `PUBLIC` — et il ne lève rien. Il rend
-- une fonction qui répond.
--
-- Le lot 8 l'avait révoqué pour les RPC d'entitlement. L'audit de la base
-- montre que c'était le seul endroit : les 103 autres fonctions de `public`
-- sont toujours exécutables par `anon`, donc publiées dans l'OpenAPI anonyme de
-- PostgREST. Cette migration ferme les dix-huit pour lesquelles c'est un défaut
-- exploitable, pas seulement une surface inutile.
--
-- CE QUI EST FERMÉ, ET POURQUOI CES DIX-HUIT
--
--   * Les treize fonctions de trigger et d'event trigger. Appelées en RPC elles
--     échouent, mais elles sont publiées, et `rls_auto_enable` est un event
--     trigger `SECURITY DEFINER` dans une surface anonyme.
--
--   * Les cinq helpers `SECURITY DEFINER` qui prennent un argument. Ceux-là
--     sont le vrai défaut : ils s'exécutent avec les droits du propriétaire,
--     donc au-dessus de la RLS, et sont indexés par uuid.
--       - `seed_site_spec(uuid)` et `seed_launch_checklist(uuid)` écrivent.
--       - `complete_choose_direction(uuid)` coche un item de checklist.
--       - `site_spec_default_target(uuid)` lit un kit sans contrôle de
--         propriété.
--       - `purchase_status_before(uuid, text)` lit l'historique de statut d'un
--         achat — un oracle de lecture sur la facturation, pour `anon`.
--     Aucun n'est appelé par un client : les quatre premiers sont appelés par
--     des triggers, qui les exécutent dans le contexte du trigger et ne
--     revérifient pas le privilège. Le dernier est appelé par le webhook, en
--     `service_role`, à qui il est réaccordé explicitement plus bas.
--
-- CE QUI N'EST PAS FERMÉ, ET C'EST DÉLIBÉRÉ
--
--   ⚠ Dix-sept fonctions sont câblées dans des contraintes CHECK
--   (`brand_kit_directions_shape_valid`, `site_spec_pages_valid`, …). Une
--   contrainte CHECK est évaluée avec les droits du rôle qui écrit : révoquer
--   EXECUTE sur l'une d'elles ferait échouer tout INSERT de ce rôle avec un
--   « permission denied for function », loin de sa cause. Aucune des dix-huit
--   ci-dessous n'en fait partie — la requête qui l'établit est dans le test.
--
--   Le reste de la surface (les fonctions pures de couleur, de rendu et de
--   catalogue) reste exécutable par `anon`. Fermer cela aussi est juste, mais
--   demande de prouver, une par une, qu'aucune n'est atteinte depuis un CHECK,
--   un index ou une policy. C'est un lot à part, pas une ligne de plus ici.
--
-- ⚠ `revoke ... from public` retire aussi le droit à `service_role`, qui n'est
-- pas propriétaire de ces fonctions. Chaque révocation qui touche une fonction
-- réellement appelée par le serveur applicatif est donc suivie d'un `grant` à
-- `service_role`.
--
-- RETOUR ARRIÈRE
--   grant execute on function public.<nom>(<args>) to anon, authenticated;
--   ... pour chacune des dix-huit. Rien d'autre n'est modifié.
-- ============================================================================

-- ============================================================================
-- 1. Les fonctions de trigger et d'event trigger
-- ============================================================================
-- Le privilège EXECUTE sur une fonction de trigger est vérifié à la création du
-- trigger, pas à chaque déclenchement. Les révoquer ne casse donc aucun
-- trigger existant — seulement leur publication en RPC.

revoke execute on function public.enforce_direction_selection_entitlement()  from public, anon, authenticated;
revoke execute on function public.handle_brand_kit_direction_selected()      from public, anon, authenticated;
revoke execute on function public.handle_new_brand_kit()                     from public, anon, authenticated;
revoke execute on function public.handle_new_project()                       from public, anon, authenticated;
revoke execute on function public.handle_new_user()                          from public, anon, authenticated;
revoke execute on function public.maintain_site_spec_text_variants()         from public, anon, authenticated;
revoke execute on function public.purchase_status_events_advance()           from public, anon, authenticated;
revoke execute on function public.purchase_status_events_append_only()       from public, anon, authenticated;
revoke execute on function public.purchase_status_events_apply()             from public, anon, authenticated;
revoke execute on function public.refresh_brand_kit_site_prompt()            from public, anon, authenticated;
revoke execute on function public.retire_seed_clamp_notes()                  from public, anon, authenticated;
revoke execute on function public.rls_auto_enable()                          from public, anon, authenticated;
revoke execute on function public.set_updated_at()                           from public, anon, authenticated;


-- ============================================================================
-- 2. Les helpers SECURITY DEFINER indexés par uuid
-- ============================================================================

revoke execute on function public.complete_choose_direction(uuid)     from public, anon, authenticated;
revoke execute on function public.seed_launch_checklist(uuid)         from public, anon, authenticated;
revoke execute on function public.seed_site_spec(uuid)                from public, anon, authenticated;
revoke execute on function public.site_spec_default_target(uuid)      from public, anon, authenticated;
revoke execute on function public.purchase_status_before(uuid, text)  from public, anon, authenticated;

-- Le webhook Stripe l'appelle pour résoudre un litige gagné : un litige clos
-- rend l'achat à l'état qu'il avait AVANT, qui peut être `partially_refunded`
-- et pas `paid`. C'est le seul appelant applicatif de cette liste.
grant execute on function public.purchase_status_before(uuid, text) to service_role;


-- ============================================================================
-- 3. Le garde-fou
-- ============================================================================
-- Sans lui, la prochaine migration qui fait `create or replace function` sur
-- l'une des dix-huit lui rend son `EXECUTE` à `PUBLIC` — le défaut revient
-- exactement comme il est arrivé la première fois, et sans rien lever.

do $$
declare
  leaked text;
begin
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into leaked
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and (
       p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
       or (p.prosecdef and p.proname in (
             'complete_choose_direction', 'seed_launch_checklist', 'seed_site_spec',
             'site_spec_default_target', 'purchase_status_before'))
     );

  if leaked is not null then
    raise exception
      'Ces fonctions sont encore exécutables par anon : %. Une fonction de trigger ou un helper SECURITY DEFINER indexé par uuid n''a rien à faire dans la surface OpenAPI anonyme.',
      leaked;
  end if;
end
$$;
