-- ============================================================================
-- ⚠ LE NUMÉRO DE LICENCE A UNE SEULE AUTORITÉ : project_briefs.license_number
-- ============================================================================
--
-- F64, trouvé le 2026-09-27. Le numéro vivait à deux endroits :
--
--   · `site_specs.practice_details.license_number` — où la praticienne le
--     TAPE (éditeur de site, réglages), et d'où le kit, le site et la
--     signature e-mail le lisent ;
--   · `project_briefs.license_number` — que le préalable du mois et la carte
--     de contenu EXIGENT (F56), et que rien n'écrivait.
--
-- Chaque cliente réelle aurait donc tapé son numéro, et vu son premier mois
-- refusé pour « licence manquante ».
--
-- ── LA DÉCISION (2026-09-27) ────────────────────────────────────────────
--
-- Le brief fait autorité. C'est la source du pied de carte, c'est ce que la
-- conformité californienne exige sur chaque publicité (B&P §4980.44, §4996.2,
-- §4999.80), et c'est déjà ce que le préalable interroge. L'éditeur de site
-- écrit dans le brief, et non l'inverse.
--
-- ── ⚠ POURQUOI UNE PROJECTION TENUE PAR TRIGGER, ET PAS UNE LECTURE RÉÉCRITE ─
--
-- Six fonctions SQL lisent `site_specs` (get, patch, reset, fix_contrast,
-- site_output_get, seed) et une douzaine de lecteurs TypeScript passent par
-- `site_spec_get`. Réécrire chacune pour aller chercher le brief, c'est six
-- occasions d'en oublier une — et celle qu'on oublie est un second arbitre.
--
-- La copie dans `site_specs` reste donc, mais elle ne peut plus DIVERGER :
--
--   1. toute écriture du numéro dans une spec est d'abord écrite dans le
--      brief, puis la spec prend la valeur du brief (trigger BEFORE) ;
--   2. toute écriture directe du brief est recopiée dans les specs du projet
--      (trigger AFTER) ;
--   3. une spec créée prend la valeur du brief.
--
-- Une copie qui ne peut pas diverger n'est pas une seconde source : c'est la
-- même valeur, lue plus près. Le test le prouve dans les trois sens.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La règle de forme, en UN endroit
-- ---------------------------------------------------------------------------
/*
 * La même règle que `project_briefs_license_number_shape` (20260924160000),
 * mais qui DIT ce qui ne va pas. La contrainte reste l'arbitre final ; cette
 * fonction sert à rendre une erreur de champ avant d'y arriver. Un test vérifie
 * qu'elles s'accordent sur chaque cas.
 */
create or replace function public.licence_number_problem(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then null
    when btrim(p) <> p then 'Remove the spaces at the start or end of the license number.'
    when p = '' then null
    when char_length(p) < 3 or char_length(p) > 20
      then 'A license number is 3 to 20 characters, as your board prints it.'
    when p !~ '^[A-Za-z0-9][A-Za-z0-9 .#-]*[A-Za-z0-9]$'
      then 'Use only the letters, digits, spaces, dots, dashes or # that your board prints.'
    when p !~ '[0-9]'
      then 'A license number contains at least one digit.'
    else null
  end
$$;

comment on function public.licence_number_problem(text) is
  'Why a licence number would be refused by project_briefs_license_number_shape, in words, or NULL when it would pass. Empty string passes here because the site editor clears a field with it; it is stored as NULL. (20260927130000, F64)';

-- ---------------------------------------------------------------------------
-- 2. La reprise — écrite une fois, même sans cliente réelle
-- ---------------------------------------------------------------------------
/*
 * ⚠ TROIS CAS, ET UN SEUL S'ARRÊTE :
 *
 *   spec porte un numéro, brief vide  → le brief le prend (la reprise)
 *   les deux portent un numéro, ≠     → le brief gagne ; la spec suivra (§3).
 *                                       Compté et imprimé : c'est la décision.
 *   spec porte un numéro INVALIDE     → ARRÊT. Le recopier violerait la
 *                                       contrainte ; l'effacer perdrait ce
 *                                       qu'elle a tapé sans le lui dire. Une
 *                                       personne tranche, ligne par ligne.
 */
create or replace function public.licence_number_reprise()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad   text;
  v_taken int;
  v_lost  int;
begin
  select string_agg(format('%s (« %s »)', ss.brand_kit_id, ss.practice_details->>'license_number'), ', ')
    into v_bad
    from public.site_specs ss
   where nullif(btrim(coalesce(ss.practice_details->>'license_number', '')), '') is not null
     and public.licence_number_problem(ss.practice_details->>'license_number') is not null;
  if v_bad is not null then
    raise exception
      'Reprise F64 : numéros de licence invalides dans des specs de site, à corriger à la main avant cette migration : %', v_bad;
  end if;

  select count(*) into v_lost
    from public.site_specs ss
    join public.brand_kits bk on bk.id = ss.brand_kit_id
    join public.project_briefs pb on pb.project_id = bk.project_id
   where nullif(ss.practice_details->>'license_number', '') is not null
     and pb.license_number is not null
     and pb.license_number <> ss.practice_details->>'license_number';

  -- Un projet peut porter plusieurs kits : le plus récent non supprimé l'emporte,
  -- la règle de `queueFirstContentMonth` (F54).
  with candidates as (
    select distinct on (bk.project_id)
           bk.project_id, ss.practice_details->>'license_number' as n
      from public.site_specs ss
      join public.brand_kits bk on bk.id = ss.brand_kit_id
     where nullif(ss.practice_details->>'license_number', '') is not null
     order by bk.project_id, (bk.deleted_at is null) desc, bk.created_at desc
  )
  update public.project_briefs pb
     set license_number = c.n
    from candidates c
   where pb.project_id = c.project_id
     and pb.license_number is null;
  get diagnostics v_taken = row_count;

  raise notice 'Reprise F64 : % numéro(s) repris des specs vers le brief ; % spec(s) en désaccord avec le brief, le brief gagne.',
    v_taken, v_lost;
  return jsonb_build_object('taken', v_taken, 'brief_won', v_lost);
end
$$;

comment on function public.licence_number_reprise() is
  'One-time F64 reprise: copies a licence number typed in a site spec into an empty brief, lets the brief win a disagreement, and stops on a number the brief constraint would refuse. A function so the rule is tested, not only run. INTERNAL ONLY. (20260927130000)';

revoke all on function public.licence_number_reprise() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La spec ne peut plus diverger
-- ---------------------------------------------------------------------------
create or replace function public.site_specs_licence_number_from_brief()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_brief   text;
  v_typed   text;
  v_before  text;
begin
  select bk.project_id into v_project from public.brand_kits bk where bk.id = new.brand_kit_id;
  select pb.license_number into v_brief from public.project_briefs pb where pb.project_id = v_project;
  if not found then
    -- Pas de brief (un kit ne naît pas sans brief ; ceci ne devrait pas
    -- arriver). On n'invente pas d'autorité : la spec ne porte rien.
    new.practice_details := jsonb_set(coalesce(new.practice_details, '{}'::jsonb), '{license_number}', 'null'::jsonb);
    return new;
  end if;

  v_typed := nullif(btrim(coalesce(new.practice_details->>'license_number', '')), '');
  v_before := case when tg_op = 'UPDATE'
                   then nullif(btrim(coalesce(old.practice_details->>'license_number', '')), '')
              end;

  /*
   * Une ÉDITION du numéro par la spec (valeur changée par rapport à la ligne
   * précédente, ou une spec créée avec un numéro alors que le brief n'en a pas)
   * s'écrit dans le brief. La contrainte du brief est l'arbitre : une forme
   * refusée lève ici, et `site_spec_patch` l'a déjà dit en mots avant.
   */
  if (tg_op = 'UPDATE' and v_typed is distinct from v_before)
     or (tg_op = 'INSERT' and v_typed is not null and v_brief is null) then
    /*
     * ⚠ LE DRAPEAU ÉVITE LA BOUCLE. Écrire le brief déclenche la recopie vers
     * les specs (§3, trigger AFTER) — qui viserait la ligne en cours de mise à
     * jour. La valeur y est déjà : on le dit à la recopie, pour cette écriture.
     */
    perform set_config('eklio.licence_from_spec', 'on', true);
    update public.project_briefs set license_number = v_typed
     where project_id = v_project and license_number is distinct from v_typed;
    perform set_config('eklio.licence_from_spec', 'off', true);
    v_brief := v_typed;
  end if;

  new.practice_details := jsonb_set(coalesce(new.practice_details, '{}'::jsonb),
                                    '{license_number}', coalesce(to_jsonb(v_brief), 'null'::jsonb));
  return new;
end
$$;

comment on function public.site_specs_licence_number_from_brief() is
  'Keeps site_specs.practice_details.license_number equal to project_briefs.license_number, the single authority: an edit through the spec is written to the brief first, and the spec then takes the brief''s value. (20260927130000, F64)';

revoke all on function public.site_specs_licence_number_from_brief() from public, anon, authenticated;

drop trigger if exists site_specs_licence_number_from_brief on public.site_specs;
create trigger site_specs_licence_number_from_brief
  before insert or update on public.site_specs
  for each row execute function public.site_specs_licence_number_from_brief();

create or replace function public.project_briefs_licence_number_to_specs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('eklio.licence_from_spec', true) = 'on' then
    return null;
  end if;
  update public.site_specs ss
     set practice_details = jsonb_set(ss.practice_details, '{license_number}',
                                      coalesce(to_jsonb(new.license_number), 'null'::jsonb))
    from public.brand_kits bk
   where bk.id = ss.brand_kit_id
     and bk.project_id = new.project_id
     and (ss.practice_details->>'license_number') is distinct from new.license_number;
  return null;
end
$$;

comment on function public.project_briefs_licence_number_to_specs() is
  'Copies a licence number written to the brief into every site spec of the project, so no reader of a spec can see another value. (20260927130000, F64)';

revoke all on function public.project_briefs_licence_number_to_specs() from public, anon, authenticated;

drop trigger if exists project_briefs_licence_number_to_specs on public.project_briefs;
create trigger project_briefs_licence_number_to_specs
  after insert or update of license_number on public.project_briefs
  for each row
  execute function public.project_briefs_licence_number_to_specs();

-- La reprise AVANT l'alignement : sinon l'alignement écraserait les numéros
-- tapés dans les specs par un brief vide. Ordre vérifié par le test.
select public.licence_number_reprise();

-- Aligner les copies existantes sur l'autorité (déclenche le trigger §3).
update public.site_specs ss
   set practice_details = ss.practice_details
 where true;

-- ---------------------------------------------------------------------------
-- 4. L'éditeur reçoit une erreur de champ, pas un refus de contrainte
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.site_spec_patch(p_brand_kit_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  v_gate jsonb;
  s        public.site_specs%rowtype;
  n        public.site_specs%rowtype;
  k        text;
  v_marks  jsonb := '{}'::jsonb;
  v_hero   jsonb;
  v_det    jsonb;
  v_len    int;
  v_path   text;
  v_next   int;
begin
  v_gate := public.site_spec_entitlement_error(p_brand_kit_id);
  if v_gate is not null then return v_gate; end if;

  select * into s
    from public.site_specs
   where brand_kit_id = p_brand_kit_id
     and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return public.site_spec_error('invalid_body', 'The update must be a JSON object.');
  end if;

  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (public.site_spec_patchable_keys())) then
      return public.site_spec_error('unknown_field',
        format('"%s" is not a field of the site spec.', k), k);
    end if;
  end loop;

  n := s;

  for k in select unnest(array['primary', 'secondary', 'accent',
                               'light_neutral', 'dark_neutral', 'paper']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string'
         or (p_patch->>k) !~ '^#[0-9A-Fa-f]{6}$' then
        return public.site_spec_error('invalid_field',
          'A color must be a hex value like #3B2C3A.', k);
      end if;
      case k
        when 'primary'       then n.primary_hex       := upper(p_patch->>k);
        when 'secondary'     then n.secondary_hex     := upper(p_patch->>k);
        when 'accent'        then n.accent_hex        := upper(p_patch->>k);
        when 'light_neutral' then n.light_neutral_hex := upper(p_patch->>k);
        when 'dark_neutral'  then n.dark_neutral_hex  := upper(p_patch->>k);
        when 'paper'         then n.paper_hex         := upper(p_patch->>k);
      end case;
    end if;
  end loop;

  if p_patch ? 'type_pairing_id' then
    if jsonb_typeof(p_patch->'type_pairing_id') = 'null' then
      n.type_pairing_id := null;
    elsif jsonb_typeof(p_patch->'type_pairing_id') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The type pairing must be a catalog id.', 'type_pairing_id');
    else
      if not exists (select 1 from public.type_pairings tp
                      where tp.id = p_patch->>'type_pairing_id') then
        return public.site_spec_error('invalid_field',
          format('"%s" is not a type pairing we carry.', p_patch->>'type_pairing_id'),
          'type_pairing_id');
      end if;
      n.type_pairing_id := p_patch->>'type_pairing_id';
      select tp.heading_font, tp.body_font, tp.google_fonts_url
        into n.heading_font, n.body_font, n.google_fonts_url
        from public.type_pairings tp where tp.id = n.type_pairing_id;
    end if;
  end if;

  for k in select unnest(array['heading_font', 'body_font', 'google_fonts_url']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string' or btrim(p_patch->>k) = '' then
        return public.site_spec_error('invalid_field',
          'This must be a font name we can render.', k);
      end if;
      case k
        when 'heading_font'     then n.heading_font     := btrim(p_patch->>k);
        when 'body_font'        then n.body_font        := btrim(p_patch->>k);
        when 'google_fonts_url' then n.google_fonts_url := btrim(p_patch->>k);
      end case;
    end if;
  end loop;

  if p_patch ? 'hero' then
    if jsonb_typeof(p_patch->'hero') <> 'object' then
      return public.site_spec_error('invalid_field', 'The hero must be an object.', 'hero');
    end if;
    v_hero := n.hero;
    for k in select jsonb_object_keys(p_patch->'hero') loop
      if not (k = any (array['overline', 'headline', 'subhead',
                             'cta_label', 'cta_target_url'])) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a field of the hero.', k), 'hero.' || k);
      end if;
      v_hero := jsonb_set(v_hero, array[k], p_patch->'hero'->k);
    end loop;

    if not public.site_spec_hero_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'Every hero field must be text.', 'hero');
    end if;
    if not public.site_spec_hero_lengths_valid(v_hero) then
      for k, v_len in select * from (values ('overline', 48), ('headline', 90),
                                            ('subhead', 220), ('cta_label', 28)) x(a, b) loop
        if coalesce(char_length(v_hero->>k), 0) > v_len then
          return public.site_spec_error('too_long',
            format('This is %s characters. The limit is %s.',
                   char_length(v_hero->>k), v_len), 'hero.' || k);
        end if;
      end loop;
    end if;
    if not public.site_spec_cta_target_url_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'The button link must start with https://, http://, mailto: or tel:.',
        'hero.cta_target_url');
    end if;
    n.hero := v_hero;
  end if;

  if p_patch ? 'about_excerpt' then
    if jsonb_typeof(p_patch->'about_excerpt') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The About text must be text.', 'about_excerpt');
    end if;
    if char_length(p_patch->>'about_excerpt') > 600 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 600.',
               char_length(p_patch->>'about_excerpt')), 'about_excerpt');
    end if;
    n.about_excerpt := p_patch->>'about_excerpt';
  end if;

  if p_patch ? 'extra_instructions' then
    if jsonb_typeof(p_patch->'extra_instructions') = 'null' then
      n.extra_instructions := null;
    elsif jsonb_typeof(p_patch->'extra_instructions') <> 'string' then
      return public.site_spec_error('invalid_field',
        'Your notes must be text.', 'extra_instructions');
    elsif char_length(p_patch->>'extra_instructions') > 2000 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 2000.',
               char_length(p_patch->>'extra_instructions')), 'extra_instructions');
    else
      n.extra_instructions := p_patch->>'extra_instructions';
    end if;
  end if;

  if p_patch ? 'pages' then
    if not public.site_spec_pages_valid(p_patch->'pages') then
      return public.site_spec_error('invalid_field',
        'Each page needs a known key, a label, an enabled flag and a list of sections with unique keys.',
        'pages');
    end if;
    if not public.site_spec_pages_lengths_valid(p_patch->'pages') then
      v_path := public.site_spec_first_overlong_field(p_patch->'pages');
      return public.site_spec_error('too_long',
        'This is over 800 characters, which is the limit for a section field.',
        coalesce(v_path, 'pages'));
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_patch->'pages') pg
      cross join lateral jsonb_array_elements(pg.value->'sections') sc
      join public.section_types st on st.id = sc.value->>'type'
       where not (pg.value->>'key' = any (st.allowed_pages))
    ) then
      return public.site_spec_error('invalid_field',
        'One of these sections is not allowed on the page it was put on.', 'pages');
    end if;
    n.pages := p_patch->'pages';
  end if;

  if p_patch ? 'practice_details' then
    if jsonb_typeof(p_patch->'practice_details') <> 'object' then
      return public.site_spec_error('invalid_field',
        'The practice details must be an object.', 'practice_details');
    end if;
    v_det := n.practice_details;
    for k in select jsonb_object_keys(p_patch->'practice_details') loop
      if not (k = any (public.site_spec_practice_detail_keys())) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a practice detail.', k), 'practice_details.' || k);
      end if;
      v_det := jsonb_set(v_det, array[k], p_patch->'practice_details'->k);
    end loop;
    if not public.site_spec_practice_details_valid(v_det) then
      return public.site_spec_error('invalid_field',
        'The state must be a two-letter code, and every other detail must be text.',
        'practice_details');
    end if;
    /*
     * ⚠ LE NUMÉRO DE LICENCE A UNE AUTORITÉ, ET CE N'EST PAS CETTE LIGNE
     * (20260927130000, F64). Il est validé ICI par la règle du brief, pour que
     * l'éditeur reçoive une erreur de champ lisible plutôt qu'un refus de
     * contrainte au moment où le trigger l'écrit dans `project_briefs`.
     */
    if public.licence_number_problem(v_det->>'license_number') is not null then
      return public.site_spec_error('invalid_field',
        public.licence_number_problem(v_det->>'license_number'),
        'practice_details.license_number');
    end if;
    n.practice_details := v_det;
  end if;

  if p_patch ? 'target' then
    if jsonb_typeof(p_patch->'target') <> 'string'
       or not exists (select 1 from public.builder_targets bt
                       where bt.id = p_patch->>'target') then
      return public.site_spec_error('invalid_field',
        'Pick one of the website builders we support.', 'target');
    end if;
    n.target := p_patch->>'target';
  end if;

  v_next := s.spec_version + 1;

  if n.primary_hex is distinct from s.primary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Primary color changed', v_next); end if;
  if n.secondary_hex is distinct from s.secondary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Secondary color changed', v_next); end if;
  if n.accent_hex is distinct from s.accent_hex then
    v_marks := v_marks || jsonb_build_object('colors|Accent color changed', v_next); end if;
  if n.paper_hex is distinct from s.paper_hex then
    v_marks := v_marks || jsonb_build_object('colors|Page background changed', v_next); end if;
  if n.light_neutral_hex is distinct from s.light_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Section background changed', v_next); end if;
  if n.dark_neutral_hex is distinct from s.dark_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Body text color changed', v_next); end if;

  if n.heading_font is distinct from s.heading_font then
    v_marks := v_marks || jsonb_build_object('typography|Heading font changed', v_next); end if;
  if n.body_font is distinct from s.body_font then
    v_marks := v_marks || jsonb_build_object('typography|Body font changed', v_next); end if;
  if n.google_fonts_url is distinct from s.google_fonts_url then
    v_marks := v_marks || jsonb_build_object('typography|Font stylesheet changed', v_next); end if;

  if n.hero is distinct from s.hero then
    v_marks := v_marks || jsonb_build_object('copy|Hero copy edited', v_next); end if;
  if n.about_excerpt is distinct from s.about_excerpt then
    v_marks := v_marks || jsonb_build_object('copy|About text edited', v_next); end if;
  if n.practice_details is distinct from s.practice_details then
    v_marks := v_marks || jsonb_build_object('copy|Practice details edited', v_next); end if;

  if n.pages is distinct from s.pages then
    if public.site_spec_pages_skeleton(n.pages)
       is distinct from public.site_spec_pages_skeleton(s.pages) then
      v_marks := v_marks || jsonb_build_object('structure|Page structure changed', v_next);
    end if;
    if public.site_spec_pages_copy(n.pages)
       is distinct from public.site_spec_pages_copy(s.pages) then
      v_marks := v_marks || jsonb_build_object('copy|Section copy edited', v_next);
    end if;
  end if;

  if n.extra_instructions is distinct from s.extra_instructions then
    v_marks := v_marks || jsonb_build_object('instructions|Your own notes edited', v_next); end if;

  if n.target is distinct from s.target then
    v_marks := v_marks || jsonb_build_object('structure|Website builder changed', v_next); end if;

  if v_marks = '{}'::jsonb then
    return public.site_spec_envelope(to_jsonb(s));
  end if;

  update public.site_specs
     set primary_hex        = n.primary_hex,
         secondary_hex      = n.secondary_hex,
         accent_hex         = n.accent_hex,
         light_neutral_hex  = n.light_neutral_hex,
         dark_neutral_hex   = n.dark_neutral_hex,
         paper_hex          = n.paper_hex,
         type_pairing_id    = n.type_pairing_id,
         heading_font       = n.heading_font,
         body_font          = n.body_font,
         google_fonts_url   = n.google_fonts_url,
         hero               = n.hero,
         about_excerpt      = n.about_excerpt,
         pages              = n.pages,
         practice_details   = n.practice_details,
         extra_instructions = n.extra_instructions,
         target             = n.target,
         spec_version       = v_next,
         change_marks       = coalesce(change_marks, '{}'::jsonb) || v_marks
   where id = s.id
   returning * into n;

  return public.site_spec_envelope(to_jsonb(n));
end
$function$;

revoke all on function public.site_spec_patch(uuid, jsonb) from public, anon;
grant execute on function public.site_spec_patch(uuid, jsonb) to authenticated;
revoke all on function public.licence_number_problem(text) from public, anon;
grant execute on function public.licence_number_problem(text) to authenticated, service_role;
