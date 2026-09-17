-- ============================================================================
-- Les pages sont une donnée — et aucun validateur ne porte sa propre liste
-- ============================================================================
-- `site_spec_page_keys()` rendait quatre valeurs écrites en dur. The Fill
-- ajoute une page par mois ; à la cinquième, `site_spec_pages_valid` refusait
-- d'écrire.
--
-- ⚠ POURQUOI CE FICHIER EXISTE EN PLUS DE LA GARDE DANS LA MIGRATION. Une
-- garde de migration ne s'exécute qu'au replay. Celle-ci s'exécute contre le
-- schéma tel qu'il EST — y compris après un `create or replace` fait à la main
-- sur le projet vivant, qui est exactement la façon dont ce dépôt a déjà cessé
-- de décrire sa base (TENANCY.md §11).
--
-- Il y a quinze validateurs jsonb dans ce schéma et ils ont déjà été troués
-- une fois. Le recensement est donc mécanique, pas une liste tenue à la main.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. La source est une lecture, pas une liste
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'site_spec_page_keys';

  assert v_def ~ 'site_pages',
    'site_spec_page_keys() ne lit plus site_pages : la liste est redevenue une constante';

  -- ⚠ ET ELLE N'EST PLUS IMMUTABLE. Une fonction qui lit une table et se
  -- déclare IMMUTABLE ment au planificateur, qui la croit et met son résultat
  -- en cache — la page ajoutée resterait refusée, sans erreur.
  assert (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'site_spec_page_keys') = 's',
    'site_spec_page_keys() lit une table en se déclarant IMMUTABLE';

  assert (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'site_spec_pages_valid') = 's',
    'site_spec_pages_valid() appelle une fonction STABLE en se déclarant IMMUTABLE';
end $$;

-- ---------------------------------------------------------------------------
-- 2. ⚠ LE RECENSEMENT — aucun validateur ne porte sa propre liste
-- ---------------------------------------------------------------------------
-- Le registre et sa raison vivent dans `20260914150000_pages_are_data.sql`.
-- Ici on re-pose la même question au schéma vivant.
do $$
declare
  v_offenders text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_offenders
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and exists (select 1 from public.site_pages sp
                  where pg_get_functiondef(p.oid) ~ ('''' || sp.key || ''''))
     and pg_get_functiondef(p.oid) !~ 'site_spec_page_keys'
     and p.proname not in (
       -- Le SEMEUR : il construit les pages initiales d'un nouveau site.
       -- « Quelles pages peuvent exister » et « par quelles pages on
       -- commence » sont deux questions différentes.
       'site_spec_default_pages',
       -- Une COLLISION DE VOCABULAIRE : deux des onze types de section
       -- s'appellent `contact` et `services`, comme deux clés de page, parce
       -- qu'une page Contact contient une section Contact. Elle ne nomme
       -- aucune page. C'est la limite de ce recensement, dite plutôt que
       -- masquée : il cherche des littéraux, et un littéral ne porte pas ce
       -- qu'il désigne.
       'site_spec_section_types'
     );

  assert v_offenders is null, coalesce(
    'fonction(s) portant leur propre liste de pages au lieu de lire '
    || 'site_spec_page_keys(): ' || v_offenders
    || '. Faites-les lire la source, ou inscrivez-les ici AVEC LA RAISON.', '');
end $$;

-- ---------------------------------------------------------------------------
-- 3. CANARY — la règle mord
-- ---------------------------------------------------------------------------
-- ⚠ Une règle qui a cessé de correspondre à quoi que ce soit ressemble
-- exactement à une règle satisfaite. On fabrique donc l'infraction et on exige
-- que la MÊME requête la trouve. C'est la forme établie par
-- `20260911170458_function_surface.test.sql`, et la raison pour laquelle cette
-- énumération-là a fini par attraper quelque chose de réel.
do $$
declare found boolean;
begin
  execute $fn$
    create or replace function public.zzz_canary_own_page_list()
    returns text[] language sql immutable set search_path = ''
    as 'select array[''home'', ''about'']'
  $fn$;

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname = 'zzz_canary_own_page_list'
       and exists (select 1 from public.site_pages sp
                    where pg_get_functiondef(p.oid) ~ ('''' || sp.key || ''''))
       and pg_get_functiondef(p.oid) !~ 'site_spec_page_keys'
  ) into found;

  execute 'drop function public.zzz_canary_own_page_list()';

  assert found,
    'le recensement ne trouve plus une fonction qui porte sa propre liste de pages : il ne vérifie plus rien';
end $$;

-- ---------------------------------------------------------------------------
-- 4. La liste est RÉELLEMENT ouverte
-- ---------------------------------------------------------------------------
-- ⚠ On l'ouvre pour de vrai et on écrit. Relire la définition de la fonction
-- aurait décrit une intention ; c'est précisément l'erreur du garde-fou de
-- `20260910144421`, qui n'a par conséquent jamais rien vérifié en CI.
do $$
declare
  v_spec jsonb := jsonb_build_array(jsonb_build_object(
    'key', 'therapy_for_burnout_portland',
    'label', 'Therapy for burnout in Portland',
    'enabled', true,
    'sections', jsonb_build_array(jsonb_build_object(
      'key','intro','type','intro','enabled',true,'order',1,'fields','{}'::jsonb))));
begin
  assert not public.site_spec_pages_valid(v_spec),
    'une page absente du catalogue est déjà acceptée';

  insert into public.site_pages (key, label, sort_order)
  values ('therapy_for_burnout_portland', 'Burnout', 90);

  assert public.site_spec_pages_valid(v_spec),
    'une page ajoutée au catalogue reste refusée : la liste n''est pas ouverte';

  -- Et la cinquième, la sixième, la douzième. C'est le cas de The Fill.
  insert into public.site_pages (key, label, sort_order) values
    ('page_two', 'Two', 91), ('page_three', 'Three', 92),
    ('page_four', 'Four', 93), ('page_five', 'Five', 94),
    ('page_six', 'Six', 95), ('page_seven', 'Seven', 96),
    ('page_eight', 'Eight', 97), ('page_nine', 'Nine', 98);

  assert array_length(public.site_spec_page_keys(), 1) = 13,
    'le catalogue de pages ne grandit pas';
end $$;

-- ---------------------------------------------------------------------------
-- 5. Les données qui nomment des pages nomment des pages qui existent
-- ---------------------------------------------------------------------------
do $$
declare v_extra text[];
begin
  -- ⚠ `allowed_pages` est un `text[]`, pas un jsonb. La lecture JSON de la
  -- colonne rend `["home"]`, ce qui donne exactement l'impression inverse.
  select array_agg(distinct page) into v_extra
    from public.section_types st, lateral unnest(st.allowed_pages) as page
   where not (page = any (public.site_spec_page_keys()));
  assert v_extra is null, coalesce(
    'section_types.allowed_pages nomme des pages absentes de site_pages : '
    || array_to_string(v_extra, ', '), '');

  -- Les pages que le semeur pose doivent exister.
  select array_agg(distinct value ->> 'key') into v_extra
    from jsonb_array_elements(
           public.site_spec_default_pages(array[]::text[], array[]::text[]))
   where not (value ->> 'key' = any (public.site_spec_page_keys()));
  assert v_extra is null, coalesce(
    'site_spec_default_pages sème des pages absentes de site_pages : '
    || array_to_string(v_extra, ', '), '');
end $$;

rollback;
