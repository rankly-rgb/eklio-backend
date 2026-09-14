-- ============================================================================
-- La phrase de positionnement, recadrée sur les mots de la patiente
-- ============================================================================
-- L'offre du 13 septembre demande, littéralement : « sa phrase de
-- positionnement (sa niche, formulée dans les mots de ses patients, pas en
-- modalités ni en démographie) ».
--
-- ⚠ DEUX DES TROIS ANGLES ÉTAIENT EXACTEMENT CE QUE L'OFFRE INTERDIT.
-- `population` était la démographie ; `method` était la modalité. Le validateur
-- de cette table les exige encore — donc tant qu'il n'a pas bougé, une
-- génération recadrée ne peut pas s'écrire.
--
--   presenting_problem     ce qu'elle porte, dans ses mots à elle
--   the_moment             l'instant où quelqu'un se décide à chercher
--   what_keeps_returning   ce qu'elle a déjà essayé, et qui revient
--
-- ── ⚠ LES ANCIENS ANGLES RESTENT ACCEPTÉS, ET CE N'EST PAS DE LA PRUDENCE ───
--
-- Des `project_briefs.usp_options` portent les trois anciens. Les refuser ferait
-- échouer la PROCHAINE écriture sur ces lignes — un autosave, une reprise de
-- brief — avec une violation de contrainte sur une colonne que personne n'a
-- touchée. Et si la validation avait été plus permissive, le positionnement
-- aurait simplement disparu d'un écran au rechargement : une valeur qui s'en
-- va sans erreur, le défaut que ce dépôt documente depuis le lot 6.
--
-- On GÉNÈRE donc trois angles et on en ACCEPTE six. L'asymétrie est portée côté
-- application par deux schémas distincts (`generatedUspOptionSchema` pour ce
-- que le modèle a le droit de produire, `uspOptionSchema` pour ce qu'on lit).
-- ============================================================================

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
                -- L'offre du 13 septembre : la niche dans les mots de la patiente.
                'presenting_problem', 'the_moment', 'what_keeps_returning',
                -- Les angles de l'offre précédente. Conservés parce que des
                -- lignes les portent ; plus jamais générés.
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
      -- Distinct across WHATEVER LENGTH the array actually is (2 or 3) --
      -- hardcoding `= 3` here would make a genuinely valid 2-element array
      -- unpassable, since two elements can have at most two distinct ids.
      and (select count(distinct c.value ->> 'id') from jsonb_array_elements(p) c) = jsonb_array_length(p)
      and (select count(distinct c.value ->> 'angle') from jsonb_array_elements(p) c) = jsonb_array_length(p)
  end
$function$;

comment on function public.project_briefs_usp_options_valid(jsonb) is
  'Shape of project_briefs.usp_options. Accepts SIX angles and only three are ever generated: the offer of 13 September reframed the positioning line onto the patient''s own words, and the three it replaced still sit on rows written before it. Refusing them would fail the next write to a column nobody touched.';

-- ── Auto-contrôle ──────────────────────────────────────────────────────────
--
-- ⚠ AUCUNE LIGNE EXISTANTE N'EST LUE. Tout est fabriqué sur place, donc ceci
-- vérifie autant sur une base vide qu'en production.

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

  -- ⚠ ET LE TROU NULL RESTE FERMÉ. Un validateur jsonb de ce dépôt doit rendre
  -- TRUE ou FALSE, jamais NULL — un CHECK ACCEPTE NULL. Une clé manquante est
  -- le chemin le plus court vers ce trou.
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
