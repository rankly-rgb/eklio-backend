-- ============================================================================
-- Une tentative refusée a coûté des jetons, et le livre l'ignorait
-- ============================================================================
-- ⚠ LA PLOMBERIE ÉTAIT COMPLÈTE, ET UNE VALEUR `null` LA TRAVERSAIT.
--
-- `settle_credit(p_reservation_id, p_actual_cost_usd, p_succeeded => false)`
-- écrit depuis toujours une ligne `release` qui REND le crédit ET porte
-- `actual_cost_usd`. Les deux choses sont déjà séparées en base : le crédit
-- utilisateur et l'argent dépensé auprès du fournisseur.
--
-- `release_on_demand_write` appelait pourtant `settle_credit(…, null, false)`.
-- Le crédit revenait, ce qui est juste ; la dépense disparaissait, ce qui ne
-- l'est pas. Mesuré le 2026-09-21 : sur onze appels de « Write it », trois ont
-- abouti et huit ont été refusés par le budget de mots. Le livre portait le
-- coût des trois. Un plafond de dépense lu là sous-déclarait donc d'exactement
-- ce qui rate — c'est-à-dire de la majorité.
--
-- Le paramètre est AJOUTÉ avec un défaut, jamais substitué : les appelants qui
-- ne le passent pas se comportent exactement comme avant.
--
-- ⚠ ET LE CRÉDIT REVIENT TOUJOURS. Enregistrer la dépense n'est pas facturer :
-- `settle_credit` écrit `delta = -r.delta` sur une release, et rien ici ne
-- touche à ce calcul. Une tentative refusée coûte de l'argent à Eklio et ne
-- coûte rien à la praticienne.

-- ⚠ L'ANCIENNE SIGNATURE EST RETIRÉE, PAS LAISSÉE À CÔTÉ. Deux surcharges dont
-- l'une a un défaut rendent tout appel à un seul argument ambigu — « function
-- is not unique » — et PostgREST choisit par NOM d'argument, donc la panne
-- n'apparaîtrait qu'au premier appelant positionnel. La nouvelle signature
-- couvre exactement l'ancienne : `p_cost_usd` vaut `null` par défaut, ce qui
-- est le comportement d'avant, au caractère près.
drop function if exists public.release_on_demand_write(uuid);

create or replace function public.release_on_demand_write(
  p_write_id uuid,
  p_cost_usd numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_write public.on_demand_writes%rowtype;
  v_error text;
  v_kit   uuid;
begin
  select * into v_write from public.on_demand_writes where id = p_write_id;
  if not found then
    return public.content_error('not_found');
  end if;

  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = v_write.content_item_id;
  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  if v_write.state <> 'reserved' then
    return jsonb_build_object('ok', true, 'reason', 'not_reserved');
  end if;

  -- ⚠ LE COÛT PASSE, LE CRÉDIT REVIENT. C'est toute la réparation.
  perform public.settle_credit(v_write.reservation_id, p_cost_usd, false);
  delete from public.on_demand_writes where id = p_write_id;

  return jsonb_build_object('ok', true, 'reason', 'released');
end
$function$;

-- ⚠ LA SURFACE ANONYME NE S'ÉLARGIT PAS. Une fonction naît avec EXECUTE
-- accordé à PUBLIC ; `20260902090000_revoke_internal_function_surface.sql` le
-- documente, et une signature nouvelle est une fonction nouvelle.
revoke all on function public.release_on_demand_write(uuid, numeric) from public, anon;
grant execute on function public.release_on_demand_write(uuid, numeric) to authenticated, service_role;
