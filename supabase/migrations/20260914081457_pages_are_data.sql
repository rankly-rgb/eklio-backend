-- Les pages deviennent une donnée. Fichier complet :
-- supabase/migrations/20260914150000_pages_are_data.sql
create table if not exists public.site_pages (
  key         text        not null,
  label       text        not null,
  sort_order  smallint    not null,
  created_at  timestamptz not null default now(),
  constraint site_pages_pkey primary key (key),
  constraint site_pages_key_check   check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  constraint site_pages_label_check check (btrim(label) <> '')
);

comment on table public.site_pages is
  'Which page keys a site specification may carry. THE single source: site_spec_page_keys() reads it, and site_spec_pages_valid() reads that. Adding a page is an INSERT - which is what The Fill needs, since it adds one page a month and the previous four-value hard-coded list refused the fifth.';

alter table public.site_pages enable row level security;
drop policy if exists site_pages_select_all on public.site_pages;
create policy site_pages_select_all on public.site_pages
  for select to anon, authenticated using (true);
drop policy if exists site_pages_insert_denied on public.site_pages;
create policy site_pages_insert_denied on public.site_pages for insert with check (false);
drop policy if exists site_pages_update_denied on public.site_pages;
create policy site_pages_update_denied on public.site_pages for update using (false);
drop policy if exists site_pages_delete_denied on public.site_pages;
create policy site_pages_delete_denied on public.site_pages for delete using (false);

grant select on public.site_pages to anon, authenticated;

-- >>> SITE PAGE DATA (mirrored verbatim in supabase/seed.sql) >>>
insert into public.site_pages (key, label, sort_order) values
  ('home',     'Home',     1),
  ('about',    'About',    2),
  ('services', 'Services', 3),
  ('contact',  'Contact',  4)
on conflict (key) do update set
  label = excluded.label, sort_order = excluded.sort_order;
-- <<< SITE PAGE DATA <<<

create or replace function public.site_spec_page_keys()
returns text[]
language sql
stable
set search_path to ''
as $$
  select coalesce(
           (select array_agg(sp.key order by sp.sort_order, sp.key)
              from public.site_pages sp),
           array[]::text[]
         )
$$;

comment on function public.site_spec_page_keys() is
  'The page keys a site specification may carry, read from site_pages. STABLE rather than IMMUTABLE because it reads a table - and site_spec_pages_valid follows, since an IMMUTABLE function calling a STABLE one is a lie Postgres does not check and does use.';

create or replace function public.site_spec_pages_valid(p jsonb)
returns boolean
language sql
stable
set search_path to ''
as $$
  select case
    when p is null then false
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) = 0 then false
    else
      not exists (
        select 1 from jsonb_array_elements(p) as pg
        where jsonb_typeof(pg.value) <> 'object'
           or not (pg.value->>'key' = any (public.site_spec_page_keys()))
           or jsonb_typeof(pg.value->'label')    is distinct from 'string'
           or jsonb_typeof(pg.value->'enabled')  is distinct from 'boolean'
           or jsonb_typeof(pg.value->'sections') is distinct from 'array'
           or exists (
             select 1 from jsonb_array_elements(pg.value->'sections') as s
             where jsonb_typeof(s.value) <> 'object'
                or jsonb_typeof(s.value->'key')  is distinct from 'string'
                or btrim(coalesce(s.value->>'key', '')) = ''
                or not (s.value->>'type' = any (public.site_spec_section_types()))
                or jsonb_typeof(s.value->'enabled') is distinct from 'boolean'
                or jsonb_typeof(s.value->'order')   is distinct from 'number'
                or (s.value->>'order')::numeric <> trunc((s.value->>'order')::numeric)
                or jsonb_typeof(s.value->'fields')  is distinct from 'object'
           )
           or (select count(distinct s.value->>'key')
                 from jsonb_array_elements(pg.value->'sections') s)
              <> jsonb_array_length(pg.value->'sections')
      )
      and (select count(distinct pg.value->>'key') from jsonb_array_elements(p) pg)
          = jsonb_array_length(p)
  end
$$;

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
     and p.proname not in ('site_spec_default_pages', 'site_spec_section_types');

  if v_offenders is not null then
    raise exception
      'fonction(s) portant leur propre liste de pages au lieu de lire site_spec_page_keys(): %. Faites-les lire la source, ou inscrivez-les dans cette garde AVEC LA RAISON.',
      v_offenders;
  end if;
end $$;

do $$
declare
  v_keys  text[];
  v_page  text;
  v_spec  jsonb;
  v_extra text[];
begin
  v_keys := public.site_spec_page_keys();
  if v_keys is distinct from array['home','about','services','contact'] then
    raise exception 'site_spec_page_keys() ne rend pas les quatre pages de site_pages : %', v_keys;
  end if;

  v_spec := jsonb_build_array(jsonb_build_object(
    'key', 'anxiety_therapy_portland', 'label', 'Anxiety therapy in Portland',
    'enabled', true,
    'sections', jsonb_build_array(jsonb_build_object(
      'key','intro','type','intro','enabled',true,'order',1,'fields','{}'::jsonb))));

  if public.site_spec_pages_valid(v_spec) then
    raise exception 'une page absente du catalogue est déjà acceptée';
  end if;

  insert into public.site_pages (key, label, sort_order)
  values ('anxiety_therapy_portland', 'Probe', 99);

  if not public.site_spec_pages_valid(v_spec) then
    raise exception 'une page ajoutée au catalogue reste refusée : la liste n''est pas réellement ouverte';
  end if;

  delete from public.site_pages where key = 'anxiety_therapy_portland';

  if public.site_spec_pages_valid(v_spec) then
    raise exception 'une page retirée du catalogue reste acceptée';
  end if;

  for v_page in
    select value ->> 'key'
      from jsonb_array_elements(public.site_spec_default_pages(array[]::text[], array[]::text[]))
  loop
    if not (v_page = any (public.site_spec_page_keys())) then
      raise exception 'site_spec_default_pages sème "%" qui n''est pas dans site_pages', v_page;
    end if;
  end loop;

  select array_agg(distinct page) into v_extra
    from public.section_types st, lateral unnest(st.allowed_pages) as page
   where not (page = any (public.site_spec_page_keys()));
  if v_extra is not null then
    raise exception 'section_types.allowed_pages nomme des pages absentes de site_pages : %', v_extra;
  end if;

  select array_agg(distinct value ->> 'key') into v_extra
    from public.site_specs ss, lateral jsonb_array_elements(ss.pages)
   where not (value ->> 'key' = any (public.site_spec_page_keys()));
  if v_extra is not null then
    raise exception 'des specs portent des pages absentes de site_pages (%) : elles ne seraient plus modifiables', v_extra;
  end if;
end $$;
