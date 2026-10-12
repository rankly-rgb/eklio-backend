-- ============================================================================
-- ⚠ L'ÉTAT ET LA VILLE DU CABINET ONT UNE SEULE AUTORITÉ : project_briefs
-- ============================================================================
--
-- F76, trouvé le 2026-10-12 sur le compte de contrôle (kit 45de0dac). Réglages →
-- Practice details : numéro de licence, État et ville saisis, « Save », et :
--
--     site_specs.practice_details   state = CA   city = Oakland   licence = 123456
--     project_briefs                state = OR   city = Portland  licence = 123456
--
-- Le formulaire avait ENREGISTRÉ. Il écrit dans `site_specs.practice_details`
-- (`site_spec_patch`), et seul le numéro de licence en sortait, par le trigger
-- de F64. L'État et la ville n'avaient aucun chemin vers le brief.
--
-- ── ⚠ LA CAUSE, ET POURQUOI ELLE A TENU ─────────────────────────────────
--
-- `site_spec_seed` (20260830060048) copie l'État et la ville du brief UNE FOIS,
-- à la création de la spec. Ensuite les deux lignes vivent séparément : la spec
-- nourrit le site, la signature, l'en-tête du kit et les annuaires ; le brief
-- nourrit la banque (les segments), la porte F46, la mention de licence et la
-- rédaction du mois. F64 a fermé ce trou pour le numéro, et pour lui seul.
--
-- Conséquence sur ce kit : un site qui dit Oakland, CA, et un mois qui aurait
-- été tiré, vérifié et signé pour l'Oregon — avec un numéro californien.
--
-- ── LA DÉCISION (2026-10-12) ────────────────────────────────────────────
--
-- 1. `project_briefs.state` et `project_briefs.city` font foi. C'est ce que lit
--    toute la chaîne du contenu, c'est la ligne qui porte déjà le numéro (F64),
--    et c'est d'elle que la spec naît.
-- 2. `site_specs.practice_details.state/city` deviennent une PROJECTION tenue
--    par trigger, dans les deux sens, exactement sur le modèle de F64.
-- 3. `project_briefs.license_state_code` est RETIRÉE. Aucun écran ne l'écrit
--    (seul le harnais la posait, en dur) ; tous les lecteurs retombaient sur
--    `state`. C'était une seconde source en attente : le jour où quelque chose
--    l'aurait écrite, F46 et la mention auraient lu un autre État que la banque
--    et le site. La licence d'un autre État en télésanté n'est PAS gérée — elle
--    reviendra, si elle revient, comme une fonctionnalité avec son champ et sa
--    porte, pas comme une colonne que rien ne remplit.
-- 4. `content_items.licence_state_code` : l'État pour lequel un post a été tiré
--    et signé. Un post dont cet État n'est plus celui qui fait autorité ne peut
--    pas passer « ready », et la route qui produit l'image le refuse.
--
-- ── ⚠ LA REPRISE S'ARRÊTE SUR UN DÉSACCORD — ELLE NE TRANCHE PAS ────────
--
-- Pour le numéro, « le brief gagne » était sans risque : la spec n'était pas
-- l'endroit où on le tapait. Pour l'État et la ville, la spec EST l'endroit où
-- la praticienne les corrige (Réglages). Faire gagner le brief effacerait ce
-- qu'elle vient de taper. Faire gagner la spec effacerait son brief. Aucune
-- règle ne sait laquelle des deux est vraie : la migration s'arrête et nomme
-- chaque désaccord, et une personne tranche, ligne par ligne, dans la liste
-- `practice_place_decisions` ci-dessous.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. L'État qui fait autorité pour un kit, en UN endroit
-- ---------------------------------------------------------------------------
create or replace function public.practice_state_of_kit(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select upper(nullif(btrim(coalesce(pb.state, '')), ''))
    from public.brand_kits bk
    join public.project_briefs pb on pb.project_id = bk.project_id
   where bk.id = p_brand_kit_id
$$;

comment on function public.practice_state_of_kit(uuid) is
  'The state that is authoritative for a kit: project_briefs.state of its project, trimmed and upper-cased, or NULL. Every check that compares a state to "the" state reads it here. INTERNAL ONLY. (20261012090000, F76)';

revoke all on function public.practice_state_of_kit(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La reprise : écrite comme une fonction, pour que la règle soit testée
-- ---------------------------------------------------------------------------
/*
 * ⚠ QUATRE CAS PAR CHAMP, ET UN SEUL S'ARRÊTE :
 *
 *   spec porte une valeur, brief vide   → le brief la prend (la reprise)
 *   brief porte une valeur, spec vide   → la spec suivra (§3)
 *   égales (casse et espaces ignorés)   → rien
 *   les deux portent une valeur, ≠      → ARRÊT, sauf décision écrite dans
 *                                         `p_decisions` : { "<brand_kit_id>":
 *                                         "spec" | "brief" }. Une décision vaut
 *                                         pour l'État ET la ville du kit.
 *
 * Une décision nommant un kit qui n'est pas en désaccord ARRÊTE aussi : une
 * décision qui ne s'applique à rien est une décision prise sur un état que la
 * base n'a plus, et l'appliquer en silence serait mentir sur ce qui a été fait.
 */
create or replace function public.practice_place_reprise(p_decisions jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row       record;
  v_open      text[] := '{}';
  v_used      text[] := '{}';
  v_unused    text;
  v_choice    text;
  v_taken     int := 0;
  v_decided   int := 0;
begin
  if p_decisions is null or jsonb_typeof(p_decisions) <> 'object' then
    raise exception 'Reprise F76 : les décisions doivent être un objet { brand_kit_id: "spec" | "brief" }';
  end if;

  for v_row in
    select bk.id as kit, bk.project_id,
           nullif(btrim(coalesce(ss.practice_details->>'state', '')), '') as spec_state,
           nullif(btrim(coalesce(ss.practice_details->>'city', '')), '')  as spec_city,
           nullif(btrim(coalesce(pb.state, '')), '')                      as brief_state,
           nullif(btrim(coalesce(pb.city, '')), '')                       as brief_city
      from public.site_specs ss
      join public.brand_kits bk     on bk.id = ss.brand_kit_id
      join public.project_briefs pb on pb.project_id = bk.project_id
     order by bk.id
  loop
    if (v_row.spec_state is not null and v_row.brief_state is not null
          and upper(v_row.spec_state) <> upper(v_row.brief_state))
       or (v_row.spec_city is not null and v_row.brief_city is not null
          and lower(v_row.spec_city) <> lower(v_row.brief_city)) then
      v_choice := p_decisions->>v_row.kit::text;
      if v_choice is null then
        v_open := v_open || format('%s (spec %s / %s, brief %s / %s)', v_row.kit,
                                   coalesce(v_row.spec_city, '∅'), coalesce(v_row.spec_state, '∅'),
                                   coalesce(v_row.brief_city, '∅'), coalesce(v_row.brief_state, '∅'));
        continue;
      end if;
      if v_choice not in ('spec', 'brief') then
        raise exception 'Reprise F76 : décision « % » pour le kit % — attendu "spec" ou "brief"', v_choice, v_row.kit;
      end if;
      v_used := v_used || v_row.kit::text;
      v_decided := v_decided + 1;
      if v_choice = 'spec' then
        update public.project_briefs
           set state = coalesce(v_row.spec_state, state),
               city  = coalesce(v_row.spec_city, city)
         where project_id = v_row.project_id;
      end if;
      -- "brief" : rien à écrire ici, l'alignement (§3) porte le brief dans la spec.
      continue;
    end if;

    -- spec porte, brief vide : le brief la prend
    if (v_row.spec_state is not null and v_row.brief_state is null)
       or (v_row.spec_city is not null and v_row.brief_city is null) then
      update public.project_briefs
         set state = coalesce(state, v_row.spec_state),
             city  = coalesce(city, v_row.spec_city)
       where project_id = v_row.project_id;
      v_taken := v_taken + 1;
    end if;
  end loop;

  if array_length(v_open, 1) > 0 then
    raise exception
      'Reprise F76 : État ou ville en désaccord entre la spec du site et le brief, à trancher kit par kit dans practice_place_decisions (spec = ce qu''elle a saisi dans ses réglages, brief = son questionnaire) : %',
      array_to_string(v_open, '; ');
  end if;

  select string_agg(k, ', ') into v_unused
    from jsonb_object_keys(p_decisions) k
   where not (k = any (v_used));
  if v_unused is not null then
    raise exception 'Reprise F76 : décision(s) pour des kits qui ne sont pas en désaccord (ou n''existent pas) : %. Rien n''a été appliqué.', v_unused;
  end if;

  raise notice 'Reprise F76 : % brief(s) complété(s) depuis la spec ; % désaccord(s) tranché(s) par décision.', v_taken, v_decided;
  return jsonb_build_object('taken', v_taken, 'decided', v_decided);
end
$$;

comment on function public.practice_place_reprise(jsonb) is
  'One-time F76 reprise: copies a state or city typed in a site spec into an empty brief, and STOPS on any spec/brief disagreement that p_decisions ({brand_kit_id: "spec"|"brief"}) does not settle. A function so the rule is tested, not only run. INTERNAL ONLY. (20261012090000)';

revoke all on function public.practice_place_reprise(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La spec ne peut plus diverger
-- ---------------------------------------------------------------------------
/*
 * ⚠ UN SEUL DRAPEAU POUR LES DEUX SENS : `eklio.place_sync`. Quand le brief
 * pousse sa valeur dans les specs, la spec la PREND sans la renvoyer ; quand la
 * spec écrit le brief, le brief ne la renvoie pas. Sans lui, chaque écriture
 * ferait un aller-retour — et un aller-retour qui normalise (casse, espaces)
 * réécrirait la valeur qu'il vient de recevoir.
 */
create or replace function public.site_specs_place_from_brief()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_state   text;
  v_city    text;
  v_typed_state  text;
  v_typed_city   text;
  v_before_state text;
  v_before_city  text;
begin
  select bk.project_id into v_project from public.brand_kits bk where bk.id = new.brand_kit_id;
  select pb.state, pb.city into v_state, v_city from public.project_briefs pb where pb.project_id = v_project;
  if not found then
    -- Pas de brief : on n'invente pas d'autorité, la spec ne porte rien.
    new.practice_details := coalesce(new.practice_details, '{}'::jsonb)
                            || jsonb_build_object('state', null, 'city', null);
    return new;
  end if;

  if coalesce(current_setting('eklio.place_sync', true), 'off') <> 'on' then
    v_typed_state := nullif(btrim(coalesce(new.practice_details->>'state', '')), '');
    v_typed_city  := nullif(btrim(coalesce(new.practice_details->>'city', '')), '');
    if tg_op = 'UPDATE' then
      v_before_state := nullif(btrim(coalesce(old.practice_details->>'state', '')), '');
      v_before_city  := nullif(btrim(coalesce(old.practice_details->>'city', '')), '');
    end if;

    /*
     * Une ÉDITION par la spec (valeur changée par rapport à la ligne d'avant, ou
     * une spec créée avec une valeur alors que le brief n'en a pas) s'écrit dans
     * le brief. Le brief est l'arbitre : `project_briefs_license_state_gate`
     * refuse ici un État qui ne délivre pas le titre de la praticienne, et
     * `site_spec_patch` l'a déjà dit en mots avant d'arriver là.
     */
    if (tg_op = 'UPDATE' and v_typed_state is distinct from v_before_state)
       or (tg_op = 'INSERT' and v_typed_state is not null and nullif(btrim(coalesce(v_state, '')), '') is null) then
      v_state := v_typed_state;
      perform set_config('eklio.place_sync', 'on', true);
      update public.project_briefs set state = v_state
       where project_id = v_project and state is distinct from v_state;
      perform set_config('eklio.place_sync', 'off', true);
    end if;
    if (tg_op = 'UPDATE' and v_typed_city is distinct from v_before_city)
       or (tg_op = 'INSERT' and v_typed_city is not null and nullif(btrim(coalesce(v_city, '')), '') is null) then
      v_city := v_typed_city;
      perform set_config('eklio.place_sync', 'on', true);
      update public.project_briefs set city = v_city
       where project_id = v_project and city is distinct from v_city;
      perform set_config('eklio.place_sync', 'off', true);
    end if;
  end if;

  new.practice_details := coalesce(new.practice_details, '{}'::jsonb)
                          || jsonb_build_object('state', nullif(btrim(coalesce(v_state, '')), ''),
                                                'city',  nullif(btrim(coalesce(v_city, '')), ''));
  return new;
end
$$;

comment on function public.site_specs_place_from_brief() is
  'Keeps site_specs.practice_details.state/city equal to project_briefs.state/city, the single authority: an edit through the spec is written to the brief first, and the spec then takes the brief''s value. (20261012090000, F76)';

revoke all on function public.site_specs_place_from_brief() from public, anon, authenticated;

drop trigger if exists site_specs_place_from_brief on public.site_specs;
create trigger site_specs_place_from_brief
  before insert or update on public.site_specs
  for each row execute function public.site_specs_place_from_brief();

create or replace function public.project_briefs_place_to_specs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(current_setting('eklio.place_sync', true), 'off') = 'on' then
    return null;
  end if;
  perform set_config('eklio.place_sync', 'on', true);
  update public.site_specs ss
     set practice_details = ss.practice_details
                            || jsonb_build_object('state', nullif(btrim(coalesce(new.state, '')), ''),
                                                  'city',  nullif(btrim(coalesce(new.city, '')), ''))
    from public.brand_kits bk
   where bk.id = ss.brand_kit_id
     and bk.project_id = new.project_id
     and ((ss.practice_details->>'state') is distinct from nullif(btrim(coalesce(new.state, '')), '')
       or (ss.practice_details->>'city')  is distinct from nullif(btrim(coalesce(new.city, '')), ''));
  perform set_config('eklio.place_sync', 'off', true);
  return null;
end
$$;

comment on function public.project_briefs_place_to_specs() is
  'Copies a state or city written to the brief into every site spec of the project, so no reader of a spec can see another value. (20261012090000, F76)';

revoke all on function public.project_briefs_place_to_specs() from public, anon, authenticated;

drop trigger if exists project_briefs_place_to_specs on public.project_briefs;
create trigger project_briefs_place_to_specs
  after insert or update of state, city on public.project_briefs
  for each row execute function public.project_briefs_place_to_specs();

-- ---------------------------------------------------------------------------
-- 4. Les décisions, puis la reprise, puis l'alignement
-- ---------------------------------------------------------------------------
/*
 * ⚠ CHAQUE LIGNE EST UNE DÉCISION D'UNE PERSONNE, DATÉE ET MOTIVÉE.
 *
 *   45de0dac-958f-4096-b83e-1559a89437e6  spec — compte de contrôle
 *     (contactnsocialmediaonline@…). CA / Oakland saisis dans les réglages le
 *     2026-10-12 ; OR / Portland est le reliquat d'un essai antérieur. La
 *     Californie est le seul État vérifié par F12. Décidé par Naïma, 2026-10-12.
 *
 * Un désaccord absent de cette liste ARRÊTE la migration et se nomme : on
 * l'ajoute ici après l'avoir tranché, et on relance.
 */
-- La reprise AVANT l'alignement : l'alignement porterait sinon un brief vide
-- dans une spec qui avait la valeur. Ordre vérifié par le test.
select public.practice_place_reprise(jsonb_build_object(
  '45de0dac-958f-4096-b83e-1559a89437e6', 'spec'
) - (
  -- ⚠ une base où ce kit n'existe pas (le rejeu local, la CI) n'a rien à
  -- trancher : la décision n'y est pas passée, plutôt que d'arrêter sur un kit
  -- absent. En production, il existe, et s'il n'est plus en désaccord la
  -- reprise le dit et s'arrête.
  select coalesce(array_agg(k), '{}') from unnest(array['45de0dac-958f-4096-b83e-1559a89437e6']) k
   where not exists (select 1 from public.brand_kits bk where bk.id::text = k)
));

-- Aligner les copies existantes sur l'autorité (déclenche le trigger §3 : une
-- ligne réécrite à l'identique n'est pas une édition, donc le brief gagne).
update public.site_specs ss
   set practice_details = ss.practice_details
 where true;

-- ---------------------------------------------------------------------------
-- 5. Le formulaire reçoit une erreur de champ, pas un refus de contrainte
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
  v_type   text;
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
    /*
     * ⚠ L'ÉTAT A UNE AUTORITÉ, ET CE N'EST PAS CETTE LIGNE (20261012090000, F76).
     * Le trigger `site_specs_place_from_brief` l'écrit dans `project_briefs`, où
     * `project_briefs_license_state_gate` refuse un État qui ne délivre pas le
     * titre de la praticienne. Le dire ICI, en mots et sur le champ, plutôt
     * qu'un refus de contrainte au moment de l'écriture.
     */
    if nullif(btrim(coalesce(v_det->>'state', '')), '')
       is distinct from nullif(btrim(coalesce(s.practice_details->>'state', '')), '') then
      select pb.license_type_id into v_type
        from public.brand_kits bk
        join public.project_briefs pb on pb.project_id = bk.project_id
       where bk.id = p_brand_kit_id;
      if not public.license_state_allowed(v_type, v_det->>'state') then
        return public.site_spec_error('invalid_field',
          format('%s does not issue the licence on your brief. Check the state, or the licence type on your brief.',
                 upper(btrim(v_det->>'state'))),
          'practice_details.state');
      end if;
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

-- ---------------------------------------------------------------------------
-- 6. license_state_code : arrêt sur désaccord, puis retrait
-- ---------------------------------------------------------------------------
/*
 * ⚠ RETIRÉE, PAS IGNORÉE. Une colonne qu'aucun lecteur ne lit encore est une
 * colonne que le prochain lecteur lira. Une ligne qui la porte AUTREMENT que
 * `state` est une licence d'un autre État que personne n'a saisie par le
 * produit : la migration s'arrête et la nomme, plutôt que de la perdre.
 */
do $$
declare
  v_bad text;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'project_briefs'
                and column_name = 'license_state_code') then
    execute $q$
      select string_agg(format('%s (license_state_code %s, state %s)', project_id, license_state_code, coalesce(state, '∅')), ', ')
        from public.project_briefs
       where license_state_code is not null
         and license_state_code is distinct from upper(nullif(btrim(coalesce(state, '')), ''))
    $q$ into v_bad;
    if v_bad is not null then
      raise exception 'F76 : license_state_code porte un autre État que state, à trancher à la main avant ce retrait : %', v_bad;
    end if;
  end if;
end $$;

alter table public.project_briefs drop constraint if exists project_briefs_license_state_shape;
alter table public.project_briefs drop column if exists license_state_code;

comment on column public.project_briefs.state is
  'The practice state, two letters, as typed. THE authority for every state the product reads: the bank segments, the F46 gate, the licence mention, the month, and -- by projection, F76 -- site_specs.practice_details.state. (20261012090000)';
comment on column public.project_briefs.city is
  'The practice city. The authority; site_specs.practice_details.city is a projection kept by trigger (F76, 20261012090000).';

-- ---------------------------------------------------------------------------
-- 7. Un post sait pour quel État il a été signé
-- ---------------------------------------------------------------------------
alter table public.content_items
  add column if not exists licence_state_code char(2);

alter table public.content_items drop constraint if exists content_items_licence_state_shape;
alter table public.content_items
  add constraint content_items_licence_state_shape
  check (licence_state_code is null or licence_state_code ~ '^[A-Z]{2}$');

comment on column public.content_items.licence_state_code is
  'The state this post was drawn and its licence mention composed for -- project_briefs.state when it was written. Stamped at insert, never changed. A post whose stamp is no longer the authoritative state cannot be marked ready, and the image route refuses it: a Californian number under an Oregon reading must not reach a publishable card. (20261012090000, F76)';

/*
 * ⚠ LES POSTS DÉJÀ ÉCRITS : L'ÉTAT DE LEUR SUJET, SINON CELUI D'AUJOURD'HUI.
 * Un sujet de banque est rédigé pour le segment d'un État : c'est l'État pour
 * lequel le post a été tiré, et il est EN BASE. Un post sans sujet d'État (un
 * sujet national, un post écrit par elle) n'a été signé que par la lecture du
 * brief au moment de l'afficher : l'État d'aujourd'hui, après la reprise.
 */
update public.content_items ci
   set licence_state_code = coalesce(
         (select upper(cs.state_code) from public.content_topics ct
            join public.content_segments cs on cs.id = ct.segment_id
           where ct.id = ci.topic_id and cs.state_code is not null),
         public.practice_state_of_kit(ci.brand_kit_id))
 where ci.licence_state_code is null;

create or replace function public.content_items_licence_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth    text := public.practice_state_of_kit(new.brand_kit_id);
  v_segment text;
begin
  if tg_op = 'INSERT' then
    /*
     * ⚠ L'ÉTAT DONNÉ PAR L'ÉCRIVAIN EST VÉRIFIÉ, PAS CRU. Le mois passe l'État
     * que son préalable a vérifié ; si le brief a changé entre ce préalable et
     * cette écriture, le post a été signé pour un autre État que celui qui fait
     * autorité maintenant, et il est refusé ici. Un écrivain qui ne dit rien
     * (une permutation, un post qu'elle crée) reçoit l'autorité.
     */
    if new.licence_state_code is null then
      new.licence_state_code := v_auth;
    elsif upper(new.licence_state_code) is distinct from v_auth then
      raise exception
        'licence_state_mismatch: this post was composed for % but the practice state is now %. A licence mention read for one state must not be published under another.',
        upper(new.licence_state_code), coalesce(v_auth, '(none)')
        using errcode = '23514';
    else
      new.licence_state_code := upper(new.licence_state_code);
    end if;

    if new.topic_id is not null then
      select upper(cs.state_code) into v_segment
        from public.content_topics ct
        join public.content_segments cs on cs.id = ct.segment_id
       where ct.id = new.topic_id;
      if v_segment is not null and v_segment is distinct from new.licence_state_code then
        raise exception
          'licence_state_mismatch: this topic was written for % and the post is signed for %.',
          v_segment, coalesce(new.licence_state_code, '(none)')
          using errcode = '23514';
      end if;
    end if;
    return new;
  end if;

  -- UPDATE
  if new.licence_state_code is distinct from old.licence_state_code then
    raise exception 'licence_state_code is stamped once, when the post is written; it is not edited.'
      using errcode = '23514';
  end if;
  if new.status = 'ready' and old.status is distinct from 'ready'
     and new.licence_state_code is distinct from v_auth then
    raise exception
      'licence_state_mismatch: this post was written for % and your practice is now in %. Its licence mention would be wrong; it cannot be marked ready.',
      coalesce(new.licence_state_code, '(no state)'), coalesce(v_auth, '(no state)')
      using errcode = '23514';
  end if;
  return new;
end
$$;

comment on function public.content_items_licence_state() is
  'Stamps content_items.licence_state_code from the authoritative state at insert, refuses a stamp or a topic segment that disagrees with it, keeps the stamp immutable, and refuses marking ready a post whose stamp is no longer the authoritative state. (20261012090000, F76)';

revoke all on function public.content_items_licence_state() from public, anon, authenticated;

drop trigger if exists content_items_licence_state on public.content_items;
create trigger content_items_licence_state
  before insert or update on public.content_items
  for each row execute function public.content_items_licence_state();

-- ---------------------------------------------------------------------------
-- 8. La route qui produit l'image pose la même question
-- ---------------------------------------------------------------------------
/*
 * ⚠ LA RÈGLE EST ICI, L'ÉCRAN NE LA RÉÉCRIT PAS. La route compose le PNG que
 * la praticienne publie ; elle demande à la base si ce post peut l'être, avec
 * la même comparaison que le passage à « ready ».
 */
create or replace function public.content_item_licence_state_problem(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_item record;
  v_auth text;
begin
  select ci.id, ci.brand_kit_id, ci.licence_state_code into v_item
    from public.content_items ci
    join public.brand_kits bk on bk.id = ci.brand_kit_id
    join public.projects p    on p.id = bk.project_id
   where ci.id = p_id
     and p.user_id = (select auth.uid());
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  v_auth := public.practice_state_of_kit(v_item.brand_kit_id);
  if v_item.licence_state_code is distinct from v_auth then
    return jsonb_build_object(
      'ok', false,
      'code', 'licence_state_mismatch',
      'item_state', v_item.licence_state_code,
      'practice_state', v_auth,
      'message', format('This post was written for %s, and your practice is now in %s. Its licence line would be wrong, so it is not exported.',
                        coalesce(v_item.licence_state_code, 'no state'), coalesce(v_auth, 'no state')));
  end if;
  return jsonb_build_object('ok', true, 'item_state', v_item.licence_state_code, 'practice_state', v_auth);
end
$$;

comment on function public.content_item_licence_state_problem(uuid) is
  'Whether a post may be exported: its stamped licence state must equal the authoritative practice state. Owner-only. (20261012090000, F76)';

revoke all on function public.content_item_licence_state_problem(uuid) from public, anon;
grant execute on function public.content_item_licence_state_problem(uuid) to authenticated;
