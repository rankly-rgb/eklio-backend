-- Ce que la migration doit tenir, et ce qu'elle ne doit surtout pas casser.
begin;

-- 1. Plus aucune fonction de trigger n'est exécutable par anon ou authenticated.
do $$
declare leaked text;
begin
  select string_agg(p.proname, ', ')
    into leaked
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));

  assert leaked is null,
    'fonctions de trigger encore exposées à un client : ' || coalesce(leaked, '');
end
$$;

-- 2. Les cinq helpers SECURITY DEFINER sont fermés aux deux rôles clients.
do $$
declare leaked text;
begin
  select string_agg(p.proname, ', ')
    into leaked
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('complete_choose_direction', 'seed_launch_checklist',
                       'seed_site_spec', 'site_spec_default_target',
                       'purchase_status_before')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));

  assert leaked is null,
    'helpers SECURITY DEFINER encore exposés : ' || coalesce(leaked, '');
end
$$;

-- 3. ⚠ Le test qui compte vraiment : aucune fonction câblée dans un CHECK n'a
--    perdu son EXECUTE. Une contrainte CHECK s'évalue avec les droits du rôle
--    qui écrit ; une révocation de trop ici ferait échouer tous les INSERT de
--    ce rôle, avec un message qui ne nomme pas la cause.
do $$
declare broken text;
begin
  select string_agg(distinct p.proname, ', ')
    into broken
    from pg_constraint c
    join pg_depend d on d.objid = c.oid and d.refclassid = 'pg_proc'::regclass
    join pg_proc p on p.oid = d.refobjid
   where c.contype = 'c'
     and not has_function_privilege('authenticated', p.oid, 'execute');

  assert broken is null,
    'une contrainte CHECK appelle une fonction qu''authenticated ne peut plus exécuter, '
    'donc toute écriture sur sa table échouera : ' || coalesce(broken, '');
end
$$;

-- 4. Le webhook garde ce dont il a besoin.
do $$
begin
  assert has_function_privilege('service_role',
           'public.purchase_status_before(uuid, text)', 'execute'),
    'le webhook ne peut plus résoudre un litige gagné';
end
$$;

-- 5. La surface cliente documentée répond toujours.
do $$
declare missing text;
begin
  select string_agg(f, ', ') into missing from (
    select f from unnest(array[
      'public.site_spec_get(uuid)',
      'public.site_spec_patch(uuid, jsonb)',
      'public.site_spec_reset(uuid, text)',
      'public.site_spec_set_target(uuid, text)',
      'public.site_output_get(uuid, text, text)',
      'public.site_output_mark_copied(uuid)',
      'public.site_spec_fix_contrast(uuid, text)',
      'public.site_catalog()',
      'public.brand_kit_select_direction(uuid, text)',
      'public.consume_generation_credit(uuid)',
      'public.brand_kit_entitled(uuid)',
      'public.brief_preview(uuid)'
    ]) as f
    where not has_function_privilege('authenticated', f, 'execute')
  ) t;

  assert missing is null,
    'la migration a fermé une entrée du contrat : ' || coalesce(missing, '');
end
$$;

rollback;
