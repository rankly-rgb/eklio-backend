-- La phrase de positionnement, recadrée. Fichier complet :
-- supabase/migrations/20260914130000_positioning_in_her_patients_words.sql
create or replace function public.project_briefs_usp_options_valid(p jsonb)
returns boolean
language sql
immutable
set search_path to ''
as $function$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) < 2 then false
    when jsonb_array_length(p) > 3 then false
    else
      not exists (
        select 1
        from jsonb_array_elements(p) as c(value)
        where jsonb_typeof(c.value) <> 'object'
           or not (c.value ?& array['id', 'angle', 'statement', 'rationale', 'evidence'])
           or jsonb_typeof(c.value -> 'id') is distinct from 'string'
           or jsonb_typeof(c.value -> 'angle') is distinct from 'string'
           or (c.value ->> 'angle') <> all (array[
                'presenting_problem', 'the_moment', 'what_keeps_returning',
                'population', 'method', 'lived_experience'
              ])
           or jsonb_typeof(c.value -> 'statement') is distinct from 'string'
           or jsonb_typeof(c.value -> 'rationale') is distinct from 'string'
           or jsonb_typeof(c.value -> 'evidence') is distinct from 'array'
           or char_length(c.value ->> 'statement') > 200
           or char_length(c.value ->> 'rationale') > 240
           or exists (
                select 1 from jsonb_array_elements(c.value -> 'evidence') as e(value)
                where jsonb_typeof(e.value) is distinct from 'string'
              )
      )
      and (select count(distinct c.value ->> 'id') from jsonb_array_elements(p) c) = jsonb_array_length(p)
      and (select count(distinct c.value ->> 'angle') from jsonb_array_elements(p) c) = jsonb_array_length(p)
  end
$function$;

comment on function public.project_briefs_usp_options_valid(jsonb) is
  'Shape of project_briefs.usp_options. Accepts SIX angles and only three are ever generated: the offer of 13 September reframed the positioning line onto the patient''s own words, and the three it replaced still sit on rows written before it. Refusing them would fail the next write to a column nobody touched.';

do $$
declare
  v_new jsonb := jsonb_build_array(
    jsonb_build_object('id','a','angle','presenting_problem','statement','x','rationale','y','evidence',jsonb_build_array('referral_quote')),
    jsonb_build_object('id','b','angle','the_moment','statement','x','rationale','y','evidence',jsonb_build_array('referral_quote')),
    jsonb_build_object('id','c','angle','what_keeps_returning','statement','x','rationale','y','evidence',jsonb_build_array('referral_quote'))
  );
  v_old jsonb := jsonb_build_array(
    jsonb_build_object('id','a','angle','population','statement','x','rationale','y','evidence',jsonb_build_array('x')),
    jsonb_build_object('id','b','angle','method','statement','x','rationale','y','evidence',jsonb_build_array('x')),
    jsonb_build_object('id','c','angle','lived_experience','statement','x','rationale','y','evidence',jsonb_build_array('x'))
  );
  v_bad jsonb := jsonb_build_array(
    jsonb_build_object('id','a','angle','presenting_problem','statement','x','rationale','y','evidence',jsonb_build_array('x')),
    jsonb_build_object('id','b','angle','pas_un_angle','statement','x','rationale','y','evidence',jsonb_build_array('x'))
  );
begin
  if not public.project_briefs_usp_options_valid(v_new) then
    raise exception 'les trois nouveaux angles sont refusés';
  end if;
  if not public.project_briefs_usp_options_valid(v_old) then
    raise exception 'les trois anciens angles sont refusés : les briefs qui les portent ne pourraient plus être écrits';
  end if;
  if public.project_briefs_usp_options_valid(v_bad) then
    raise exception 'un angle inventé est accepté';
  end if;
  if public.project_briefs_usp_options_valid(
       jsonb_build_array(
         jsonb_build_object('id','a','angle','presenting_problem','statement','x'),
         jsonb_build_object('id','b','angle','the_moment','statement','x','rationale','y','evidence',jsonb_build_array('x'))
       )) is not false then
    raise exception 'un candidat sans rationale ni evidence n''est pas refusé net';
  end if;
  if public.project_briefs_usp_options_valid(null) is not true then
    raise exception 'une colonne nulle n''est plus acceptée';
  end if;
end $$;
