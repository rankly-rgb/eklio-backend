-- Le profil d'annuaire. Fichier complet :
-- supabase/migrations/20260914140000_the_directory_profile.sql
create or replace function public.directory_structured_valid(p jsonb)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select coalesce(
    case
      when p is null then true
      when jsonb_typeof(p) <> 'object' then false
      else
        not exists (
          select 1
            from jsonb_each(p) as kv(key, value)
           where jsonb_typeof(kv.value) <> 'array'
              or exists (
                   select 1 from jsonb_array_elements(kv.value) as e(value)
                    where jsonb_typeof(e.value) is distinct from 'string'
                       or btrim(e.value #>> '{}') = ''
                 )
        )
    end,
    false
  )
$$;

comment on function public.directory_structured_valid(jsonb) is
  'Shape of directory_profiles.structured: an object whose every value is an array of non-empty strings. An ABSENT key is allowed - a profile with no declared insurance is a valid profile, not a broken one. An EMPTY STRING inside a list is not: that is the shape a dropped optional field takes when nobody handled it.';

create table if not exists public.directory_profiles (
  id              uuid        not null default gen_random_uuid(),
  brand_kit_id    uuid        not null,
  platform        text        not null,
  first_paragraph text        not null,
  body            text        not null,
  structured      jsonb       not null default '{}'::jsonb,
  ethics_check    jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint directory_profiles_pkey primary key (id),
  constraint directory_profiles_brand_kit_id_fkey
    foreign key (brand_kit_id) references public.brand_kits (id) on delete cascade,
  constraint directory_profiles_one_per_platform unique (brand_kit_id, platform),
  constraint directory_profiles_platform_check
    check (platform = any (array['psychology_today', 'google_business'])),
  constraint directory_profiles_first_paragraph_check
    check (btrim(first_paragraph) <> '' and char_length(first_paragraph) <= 1200),
  constraint directory_profiles_body_check
    check (btrim(body) <> '' and char_length(body) <= 6000),
  constraint directory_profiles_structured_shape
    check (public.directory_structured_valid(structured)),
  constraint directory_profiles_ethics_check_shape
    check (public.brand_kit_ethics_check_valid(ethics_check))
);

comment on table public.directory_profiles is
  'A written directory profile. The STRUCTURED FIELDS and the PROSE are stored apart on purpose: the form fields will be read back to fill a form, to measure and to compare, and a sentence you have to re-extract "LCSW, Oregon, trauma" from is a sentence you will re-extract badly.';
comment on column public.directory_profiles.first_paragraph is
  'The only part of the prose that appears in the directory''s SEARCH RESULTS. A column, not "the text up to the first newline": it is rewritten alone in The First Line, refreshed alone each season, and measured alone. Splitting it at read time means splitting it differently for each reader.';
comment on column public.directory_profiles.body is
  'The rest of the prose. Does NOT repeat the first paragraph.';
comment on column public.directory_profiles.structured is
  'The form fields, as lists of resolved catalogue LABELS - never merged into the prose. Assembled in the application, never by SQL concatenation: see this migration''s header for the three lines that vanished from a paid deliverable the last time optional fields were concatenated in SQL.';

alter table public.directory_profiles enable row level security;

drop policy if exists directory_profiles_select_own on public.directory_profiles;
create policy directory_profiles_select_own on public.directory_profiles
  for select using (
    exists (
      select 1 from public.brand_kits bk
       where bk.id = directory_profiles.brand_kit_id
         and public.owns_project(bk.project_id)
    )
  );
drop policy if exists directory_profiles_insert_denied on public.directory_profiles;
create policy directory_profiles_insert_denied on public.directory_profiles for insert with check (false);
drop policy if exists directory_profiles_update_denied on public.directory_profiles;
create policy directory_profiles_update_denied on public.directory_profiles for update using (false);
drop policy if exists directory_profiles_delete_denied on public.directory_profiles;
create policy directory_profiles_delete_denied on public.directory_profiles for delete using (false);

grant select on public.directory_profiles to authenticated;

drop trigger if exists set_directory_profiles_updated_at on public.directory_profiles;
create trigger set_directory_profiles_updated_at
  before update on public.directory_profiles
  for each row execute function public.set_updated_at();

create or replace function public.get_directory_profile(
  p_brand_kit_id uuid,
  p_platform     text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_error text;
  v_row   public.directory_profiles;
begin
  v_error := public.kit_paid_access(p_brand_kit_id);
  if v_error is not null then
    return jsonb_build_object('error', v_error);
  end if;

  select * into v_row
    from public.directory_profiles
   where brand_kit_id = p_brand_kit_id and platform = p_platform;

  if not found then
    return jsonb_build_object('profile', null);
  end if;

  return jsonb_build_object('profile', jsonb_build_object(
    'platform',        v_row.platform,
    'first_paragraph', v_row.first_paragraph,
    'body',            v_row.body,
    'structured',      v_row.structured,
    'ethics_check',    v_row.ethics_check,
    'updated_at',      v_row.updated_at
  ));
end
$$;

revoke all on function public.get_directory_profile(uuid, text) from public, anon;
grant execute on function public.get_directory_profile(uuid, text) to authenticated, service_role;

create or replace function public.save_directory_profile(
  p_brand_kit_id    uuid,
  p_platform        text,
  p_first_paragraph text,
  p_body            text,
  p_structured      jsonb,
  p_ethics_check    jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id uuid;
begin
  if not (public.caller_is_the_database() or auth.role() = 'service_role') then
    raise exception 'save_directory_profile: reserved to the generation job'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.directory_profiles
    (brand_kit_id, platform, first_paragraph, body, structured, ethics_check)
  values
    (p_brand_kit_id, p_platform, p_first_paragraph, p_body,
     coalesce(p_structured, '{}'::jsonb), p_ethics_check)
  on conflict (brand_kit_id, platform) do update set
    first_paragraph = excluded.first_paragraph,
    body            = excluded.body,
    structured      = excluded.structured,
    ethics_check    = excluded.ethics_check
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end
$$;

revoke all on function public.save_directory_profile(uuid, text, text, text, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_directory_profile(uuid, text, text, text, jsonb, jsonb)
  to service_role;

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org  uuid;
  v_proj uuid := gen_random_uuid();
  v_kit  uuid := gen_random_uuid();
  v_broke boolean;
  v_got  jsonb;
begin
  if not public.directory_structured_valid('{}'::jsonb) then
    raise exception 'un profil sans aucun champ structuré est refusé';
  end if;
  if not public.directory_structured_valid(
       jsonb_build_object('issues', jsonb_build_array('Trauma', 'Anxiety'))) then
    raise exception 'une liste de libellés est refusée';
  end if;
  if public.directory_structured_valid(
       jsonb_build_object('issues', jsonb_build_array('Trauma', ''))) then
    raise exception 'un libellé vide passe : un champ perdu ne se verrait pas';
  end if;
  if public.directory_structured_valid(jsonb_build_object('issues', 'Trauma')) then
    raise exception 'une chaîne au lieu d''une liste passe';
  end if;
  if public.directory_structured_valid('[]'::jsonb) is null
  or public.directory_structured_valid('null'::jsonb) is null then
    raise exception 'le validateur rend NULL : un CHECK l''accepterait';
  end if;

  insert into auth.users (id, email) values (v_user, 'directory@example.invalid');
  select m.organization_id into v_org from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Directory');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  perform public.save_directory_profile(
    v_kit, 'psychology_today',
    'The first paragraph, which is the only part search results show.',
    'The rest of the prose, which does not repeat it.',
    jsonb_build_object('issues', jsonb_build_array('Trauma')), null);

  perform public.save_directory_profile(
    v_kit, 'psychology_today', 'Rewritten first paragraph.', 'Rewritten body.',
    jsonb_build_object('issues', jsonb_build_array('Trauma')), null);

  if (select count(*) from public.directory_profiles where brand_kit_id = v_kit) <> 1 then
    raise exception 'deux enregistrements ont produit deux profils';
  end if;

  select public.get_directory_profile(v_kit, 'psychology_today') into v_got;
  if v_got -> 'profile' ->> 'first_paragraph' <> 'Rewritten first paragraph.' then
    raise exception 'le premier paragraphe n''est pas rendu séparément';
  end if;
  if v_got -> 'profile' ->> 'body' = v_got -> 'profile' ->> 'first_paragraph' then
    raise exception 'le corps répète le premier paragraphe';
  end if;

  begin
    perform public.save_directory_profile(v_kit, 'psychology_today', '   ', 'x',
                                          '{}'::jsonb, null);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un premier paragraphe vide a été accepté';
  end if;

  delete from public.projects where id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;
