-- ============================================================================
-- Eklio — app_search (post-purchase-v2, Lot 2: global search)
-- ============================================================================
-- One RPC, server-side, no client-side full scan. Searches rows she already
-- owns for the current kit: assets (by key/label against the catalog) and
-- launch steps (by label/description). content_items and ethics_checks
-- don't exist yet (Lots 6/7, later sessions) -- their branches are simply
-- absent from the UNION today rather than stubbed, so adding those tables
-- later is a matter of adding a branch here, not redesigning the RPC.
-- ============================================================================

create or replace function public.app_search(p_brand_kit_id uuid, p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owned boolean;
  v_needle text := trim(p_query);
begin
  if (select auth.uid()) is null then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'unauthenticated',
      'message', 'Sign in to search.'
    ));
  end if;

  select exists (
    select 1 from public.brand_kits bk
      join public.projects p on p.id = bk.project_id
     where bk.id = p_brand_kit_id
       and p.user_id = (select auth.uid())
  ) into v_owned;

  if not v_owned then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such brand kit.'
    ));
  end if;

  if v_needle = '' then
    return jsonb_build_object('assets', '[]'::jsonb, 'launch_steps', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'assets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', c.key, 'group', c."group", 'label', c.label
      ) order by c.sort_order)
      from public.asset_catalog c
     where c.key ilike '%' || v_needle || '%'
        or c.label ilike '%' || v_needle || '%'
    ), '[]'::jsonb),
    'launch_steps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', i.key, 'label', i.label,
        'status', case
          when i.done_at is not null then 'done'
          when i.skipped_at is not null then 'skipped'
          else 'todo'
        end
      ) order by i.sort_order)
      from public.launch_checklist_items i
     where i.brand_kit_id = p_brand_kit_id
       and i.key <> 'choose_direction'
       and (i.label ilike '%' || v_needle || '%' or i.description ilike '%' || v_needle || '%')
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.app_search(uuid, text) from public, anon;
grant execute on function public.app_search(uuid, text) to authenticated, service_role;
