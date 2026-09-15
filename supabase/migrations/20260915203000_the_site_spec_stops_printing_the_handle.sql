-- ============================================================================
-- Le spec de site cesse d'imprimer la poignée interne
-- ============================================================================
-- `20260915183000` a fait de `license_types.label` une POIGNÉE INTERNE : « LP »
-- s'est révélé faux dans quatre États sur cinq, la poignée du psychologue vaut
-- « PSYCH », et rien de ce qu'une cliente lit ne doit en venir.
--
-- ⚠ UNE SURFACE LISAIT ENCORE CETTE COLONNE, et c'est celle qui imprime :
-- `site_spec_seed_values()` semait `practice_details.license_label` depuis
-- `lt.label`, et `site_spec_credential_line()` le rend tel quel dans le pied
-- de page et le bloc contact du site — puis dans la fiche Google, qui n'a
-- aucun champ structuré pour le corriger.
--
-- Aucun État n'étant vérifié aujourd'hui, rien de faux n'est encore imprimé.
-- C'est précisément pour ça qu'on le traite MAINTENANT : un correctif rattaché
-- à un événement futur — « au moment où on ouvrira les États » — n'arrive pas.
-- Le jour où CA s'ouvre, personne ne relit cette fonction.
--
-- ── CE QUI CHANGE, EN UNE EXPRESSION ────────────────────────────────────
--
--   avant : lt.label                                   (« PSYCH », « LP »)
--   après : title_abbreviation(titre, État)             (le sigle de SON État,
--           ?? lt.description                            s'il est VÉRIFIÉ)
--                                                       sinon les mots entiers
--
-- `title_abbreviation()` rend NULL sur une ligne non vérifiée, donc le
-- `coalesce` retombe du bon côté sans que l'appelant ait à le savoir. Et
-- `description` est vraie dans les cinquante États : il y a toujours quelque
-- chose d'imprimable.
--
-- ⚠ LE RESTE DE LA FONCTION EST REPRIS VERBATIM depuis la base, pas réécrit —
-- une transcription serait l'occasion d'y changer autre chose sans le voir.
-- ============================================================================


CREATE OR REPLACE FUNCTION public.site_spec_seed_values(p_brand_kit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  v_project uuid;
  v_dir     jsonb;
  v_brief   record;
  v_specs   text[];
  v_persona text[];
  v_pal     jsonb;
  v_fb      record;
  v_lim     jsonb;
  v_clamped jsonb := '{}'::jsonb;
  v_primary       text;
  v_secondary     text;
  v_accent        text;
  v_light_neutral text;
  v_dark_neutral  text;
  v_paper         text;
begin
  select p.id into v_project
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;
  if v_project is null then
    return null;
  end if;

  select d.value into v_dir
    from public.brand_kits bk
    cross join lateral jsonb_array_elements(bk.directions) as d
   where bk.id = p_brand_kit_id
     and bk.selected_direction_id is not null
     and d.value->>'id' = bk.selected_direction_id;
  if v_dir is null then
    return null;
  end if;

  select * into v_brief from public.project_briefs pb where pb.project_id = v_project;

  select array_agg(s.label order by e.ord) into v_specs
    from unnest(coalesce(v_brief.specialty_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.specialties s on s.id = e.id;

  select array_agg(c.label order by e.ord) into v_persona
    from unnest(coalesce(v_brief.client_persona_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.client_persona_cards c on c.id = e.id;

  v_pal := v_dir->'palette';
  select pf.primary_hex, pf.secondary_hex, pf.light_hex, pf.dark_hex, pf.paper_hex, pf.accent_hex
    into v_fb
    from public.palette_families pf where pf.id = 'clay_sand';

  v_primary       := coalesce(public.site_spec_palette_role(v_pal, 'primary'),       v_fb.primary_hex);
  v_secondary     := coalesce(public.site_spec_palette_role(v_pal, 'secondary'),     v_fb.secondary_hex);
  v_light_neutral := coalesce(public.site_spec_palette_role(v_pal, 'light_neutral'), v_fb.light_hex);
  v_dark_neutral  := coalesce(public.site_spec_palette_role(v_pal, 'dark_neutral'),  v_fb.dark_hex);
  v_paper         := coalesce(public.site_spec_palette_role(v_pal, 'paper'),         v_fb.paper_hex);
  v_accent := coalesce(
    public.site_spec_palette_role(v_pal, 'accent'),
    public.site_spec_curated_accent(v_pal),
    public.site_spec_derive_accent(v_primary, v_secondary, v_paper));

  v_lim := public.site_spec_limits();

  v_clamped := v_clamped
    || public.site_spec_clamp_note('hero.overline',  v_dir->'hero'->>'overline',  (v_lim->>'hero_overline')::int)
    || public.site_spec_clamp_note('hero.headline',  v_dir->'hero'->>'headline',  (v_lim->>'hero_headline')::int)
    || public.site_spec_clamp_note('hero.subhead',   v_dir->'hero'->>'subhead',   (v_lim->>'hero_subhead')::int)
    || public.site_spec_clamp_note('hero.cta_label', v_dir->'hero'->>'cta_label', (v_lim->>'hero_cta_label')::int)
    || public.site_spec_clamp_note('about_excerpt',  v_dir->>'about_excerpt',     (v_lim->>'about_excerpt')::int);

  return jsonb_build_object(
    'primary',       v_primary,
    'secondary',     v_secondary,
    'accent',        v_accent,
    'light_neutral', v_light_neutral,
    'dark_neutral',  v_dark_neutral,
    'paper',         v_paper,

    'type_pairing_id',
      (select tp.id from public.type_pairings tp
        where tp.heading_font = v_dir->'typography'->>'heading_font'
          and tp.body_font    = v_dir->'typography'->>'body_font'
        order by tp.sort_order limit 1),
    'heading_font',
      coalesce(nullif(btrim(v_dir->'typography'->>'heading_font'), ''), 'Fraunces'),
    'body_font',
      coalesce(nullif(btrim(v_dir->'typography'->>'body_font'), ''), 'Nunito Sans'),
    'google_fonts_url',
      coalesce(nullif(btrim(v_dir->'typography'->>'google_fonts_url'), ''),
               (select tp.google_fonts_url from public.type_pairings tp
                 where tp.id = 'fraunces_nunito')),

    'hero', jsonb_build_object(
      'overline',       public.truncate_on_word_boundary(v_dir->'hero'->>'overline',  (v_lim->>'hero_overline')::int),
      'headline',       public.truncate_on_word_boundary(v_dir->'hero'->>'headline',  (v_lim->>'hero_headline')::int),
      'subhead',        public.truncate_on_word_boundary(v_dir->'hero'->>'subhead',   (v_lim->>'hero_subhead')::int),
      'cta_label',      public.truncate_on_word_boundary(v_dir->'hero'->>'cta_label', (v_lim->>'hero_cta_label')::int),
      'cta_target_url', null),

    'about_excerpt',
      coalesce(public.truncate_on_word_boundary(v_dir->>'about_excerpt', (v_lim->>'about_excerpt')::int), ''),

    'pages', public.site_spec_default_pages(v_specs, v_persona),

    'practice_details', jsonb_build_object(
      -- ⚠ EMPTY. `project_briefs` has no question that answers this today; the
      -- brief needs one before it can carry anything. Empty prints nothing.
      'practitioner_name', null,
      'practice_name',  coalesce(nullif(btrim(v_brief.practice_name), ''),
                                 (select nullif(btrim(p.name), '') from public.projects p
                                   where p.id = v_project)),
      /*
       * ⚠ CE N'EST PLUS `lt.label`. Cette colonne a cessé d'être un credential
       * (20260915183000) : « LP » était faux dans quatre États sur cinq, et la
       * poignée vaut « PSYCH » aujourd'hui — ce qu'aucune cliente ne doit lire.
       *
       * Ce qui s'imprime est le sigle de SON État, et seulement s'il a été
       * vérifié contre le board ; sinon les mots en toutes lettres, qui sont
       * vrais partout. `title_abbreviation()` rend NULL sur une ligne non
       * vérifiée, donc le `coalesce` retombe tout seul du bon côté.
       */
      'license_label',  coalesce(
                          public.title_abbreviation(
                            v_brief.license_type_id, v_brief.state),
                          (select lt.description from public.license_types lt
                            where lt.id = v_brief.license_type_id)),
      'license_number', null,
      'city',           nullif(btrim(v_brief.city), ''),
      'state',          nullif(btrim(v_brief.state), ''),
      'email',          null,
      'phone',          null),

    'target', public.site_spec_default_target(p_brand_kit_id),
    'seed_clamped', nullif(v_clamped, '{}'::jsonb));
end
$function$;

-- ---------------------------------------------------------------------------
-- Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'site_spec_seed_values';

  -- La poignée interne n'est plus semée.
  if v_def ~ 'license_label''\s*,\s*\(select lt\.label' then
    raise exception
      'credential_line: le spec sème encore la poignée interne. Migration abandonnée.';
  end if;

  -- Et c'est bien le sigle du couple qui la remplace, avec son repli.
  if v_def !~ 'title_abbreviation' then
    raise exception
      'credential_line: le spec ne lit pas le sigle du couple. Migration abandonnée.';
  end if;
  if v_def !~ 'lt\.description' then
    raise exception
      'credential_line: le spec n''a pas de repli sur les mots entiers. Migration abandonnée.';
  end if;

  -- Anti-vacuité : on a bien inspecté une fonction, pas une chaîne vide.
  if length(coalesce(v_def, '')) < 2000 then
    raise exception 'credential_line: la définition lue est trop courte pour être la bonne.';
  end if;
end
$$;
