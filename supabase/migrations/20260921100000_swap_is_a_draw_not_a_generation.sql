-- ============================================================================
-- Eklio — Swap : un tirage, pas une génération
-- ============================================================================
-- ⚠ SWAP NE COÛTE RIEN PARCE QU'IL N'APPELLE RIEN, et c'est la banque qui le
-- permet.
--
-- La tentation, en écrivant ce bouton, est de redemander une carte à un
-- modèle. Ce serait instantanément cher (trente abonnées qui swappent trois
-- fois valent un mois de génération), lent, et non déterministe — trois
-- propriétés que « instantané, gratuit et déterministe » exclut chacune.
--
-- `content_topics` porte déjà tout ce qu'une carte a besoin d'avoir :
-- `caption_seed` est la caption, `payload` est le diagramme, `hook` est la
-- ligne posée SUR l'image, `rationale_template` est la justification. Un swap
-- ne fabrique donc rien : il tire le sujet suivant et recopie ce qui est déjà
-- écrit.
--
-- Le ledger l'enregistre quand même, avec `delta = 0` : « elle a swappé onze
-- fois ce mois-ci » est le signal que le scoring de la banque est mauvais, et
-- un acte gratuit qui ne laisse aucune trace ne peut pas être mesuré.
-- ============================================================================


-- ============================================================================
-- 1. render_rationale — le gabarit, rempli avec SON brief
-- ============================================================================
create or replace function public.render_rationale(
  p_template     text,
  p_brand_kit_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out       text := coalesce(p_template, '');
  v_specialty text;
  v_modality  text;
begin
  select s.label into v_specialty
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
    join public.project_briefs pb on pb.project_id = pr.id
    join public.specialties s on s.id = any (pb.specialty_ids)
   where bk.id = p_brand_kit_id
   order by s.sort_order
   limit 1;

  select m.label into v_modality
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
    join public.project_briefs pb on pb.project_id = pr.id
    join public.modality_cards m on m.id = any (pb.modality_ids)
   where bk.id = p_brand_kit_id
   order by m.sort_order
   limit 1;

  v_out := replace(v_out, '{{specialty}}', coalesce(lower(v_specialty), 'this'));
  v_out := replace(v_out, '{{modality}}',  coalesce(lower(v_modality),  'the work'));

  /*
   * ⚠ TOUT PLACEHOLDER INCONNU EST RETIRÉ, PAS LAISSÉ.
   *
   * Un gabarit qui nomme une substitution que cette fonction ne connaît pas
   * afficherait `{{something}}` sous une carte, sur l'écran d'une praticienne.
   * Le retirer laisse une phrase un peu plus courte ; le laisser laisse une
   * phrase manifestement cassée. La première se lit, la seconde se signale.
   */
  v_out := regexp_replace(v_out, '\s*\{\{[a-z_]+\}\}\s*', ' ', 'g');
  v_out := btrim(regexp_replace(v_out, '\s+', ' ', 'g'));

  return left(nullif(v_out, ''), 200);
end
$$;

comment on function public.render_rationale(text, uuid) is
  'Fills a topic''s rationale template with THIS kit''s brief. An unknown placeholder is removed rather than left: `{{something}}` under a card on a practitioner''s screen is visibly broken, while a slightly shorter sentence simply reads.';

revoke all on function public.render_rationale(text, uuid) from public, anon, authenticated;


-- ============================================================================
-- 2. swap_content_item — tire, recopie, journalise
-- ============================================================================
create or replace function public.swap_content_item(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit    uuid;
  v_user   uuid;
  v_month  date;
  v_topic  uuid;
  v_t      public.content_topics%rowtype;
  v_res    jsonb;
begin
  -- ⚠ LA PROPRIÉTÉ D'ABORD, ET PAR LE MÊME CHEMIN QUE PARTOUT. Un item qui
  -- n'est pas à elle répond `not_found`, jamais `payment_required` : la
  -- distinction dirait à une inconnue que cet identifiant existe.
  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = p_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  declare v_access text;
  begin
    v_access := public.content_kit_access(v_kit);
    if v_access is not null then
      return public.content_error(v_access);
    end if;
  end;

  select pr.user_id into v_user
    from public.brand_kits bk join public.projects pr on pr.id = bk.project_id
   where bk.id = v_kit;

  select coalesce(ci.scheduled_for, current_date) into v_month
    from public.content_items ci where ci.id = p_id;
  v_month := date_trunc('month', v_month)::date;

  -- ── Le tirage. Gratuit, déterministe, aucun modèle ────────────────────
  v_topic := public.assign_topic_to_kit(v_kit, v_month);
  if v_topic is null then
    /*
     * ⚠ LA BANQUE EST VIDE POUR CE SEGMENT, ET ON LE DIT.
     *
     * Un appelant qui reçoit ça doit l'AFFICHER, pas réessayer : réessayer
     * tirera le même rien. C'est aussi le signal de dimensionnement que la
     * simulation de la phase 6 mesure — quand il apparaît en production, la
     * banque est sous-dimensionnée pour ce segment.
     */
    return public.content_error('bank_exhausted');
  end if;

  select * into v_t from public.content_topics where id = v_topic;

  -- ── La recopie. Rien n'est fabriqué ───────────────────────────────────
  update public.content_items ci
     set title         = left(v_t.title, 34),
         caption       = v_t.caption_seed,
         on_image_text = v_t.hook,
         topic_id      = v_t.id,
         rationale     = public.render_rationale(v_t.rationale_template, v_kit),
         updated_at    = now()
   where ci.id = p_id;

  -- ── Le journal. delta 0, et il compte quand même ──────────────────────
  v_res := public.reserve_credit(
    v_user, 'swap', 'swapped ' || p_id::text, 'content_item', p_id,
    null, null, null, v_month
  );
  if (v_res ->> 'ok')::boolean then
    perform public.settle_credit((v_res ->> 'reservation_id')::uuid, null, true);
  end if;

  return public.content_item_json(p_id);
end
$$;

comment on function public.swap_content_item(uuid) is
  'Draws the next bank topic for this kit and copies it onto the post. No model call: caption_seed IS the caption, hook IS the on-image line, payload IS the diagram. That is why Swap is instant, free and deterministic, and why it is the dominant action on the stream. Recorded in credit_ledger with delta 0 -- "she swapped eleven times" is the signal the bank''s scoring is wrong, and a free act that leaves no trace cannot be measured.';

revoke all on function public.swap_content_item(uuid) from public, anon;
grant execute on function public.swap_content_item(uuid) to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_mod text; v_per text; v_spec text;
  v_u uuid := gen_random_uuid(); v_p uuid := gen_random_uuid(); v_k uuid := gen_random_uuid();
  v_seg uuid; v_item uuid; v_json jsonb; v_n integer;
begin
  -- Le gabarit se remplit, et un placeholder inconnu disparaît.
  if public.render_rationale('Because {{specialty}} keeps coming up.', null)
     is distinct from 'Because this keeps coming up.' then
    raise exception 'render_rationale: la substitution par défaut ne s''applique pas: %',
      public.render_rationale('Because {{specialty}} keeps coming up.', null);
  end if;
  if public.render_rationale('Because {{unknown_thing}} matters.', null)
     is distinct from 'Because matters.' then
    raise exception 'render_rationale: un placeholder inconnu survit: %',
      public.render_rationale('Because {{unknown_thing}} matters.', null);
  end if;

  if has_function_privilege('anon', 'public.swap_content_item(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'anon peut exécuter swap_content_item.';
  end if;
  if has_function_privilege('authenticated', 'public.render_rationale(text,uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated peut exécuter render_rationale directement.';
  end if;

  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;
  select id into v_spec from public.specialties where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u, 'swap@example.invalid');
  insert into public.projects (id, user_id, name) values (v_p, v_u, 'S');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, specialty_ids, state)
  values (v_p, array[v_mod], array[v_per], array[v_spec], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k, v_p);
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_u, 'swap guard rail', 'migration 20260921100000', now() + interval '1 day');

  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'invite', 'Drawn by the swap',
          'A hook the composer will set on the image',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'The caption the bank already wrote.', 'Because {{specialty}} keeps coming up.', now());

  insert into public.content_items (brand_kit_id, archetype, status, title)
  values (v_k, 'statement', 'proposed', 'Before the swap')
  returning id into v_item;

  /*
   * ⚠ UN APPELANT EST POSÉ, PARCE QUE `swap_content_item` EN EXIGE UN.
   *
   * Elle passe par `content_kit_access` → `kit_paid_access`, scopée
   * `auth.uid()`. Sans claim, `auth.uid()` est NULL, la fonction répond
   * `not_found` — correctement — et la sonde mesure l'absence d'appelant au
   * lieu du swap.
   *
   * Poser le claim ici n'est pas un contournement : c'est la seule façon
   * d'exercer une fonction dont la portée EST l'appelant. Il est retiré juste
   * après, et la portée elle-même est éprouvée depuis un vrai rôle dans
   * `supabase/tests/20260921100000_swap.test.sql`.
   */
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  -- ⚠ LE SWAP RECOPIE, IL NE FABRIQUE PAS.
  v_json := public.swap_content_item(v_item);
  if v_json ? 'error' then
    raise exception 'le swap a échoué: %', v_json;
  end if;
  if v_json ->> 'caption' <> 'The caption the bank already wrote.' then
    raise exception 'le swap n''a pas recopié la caption du sujet: %', v_json ->> 'caption';
  end if;
  if v_json ->> 'on_image_text' <> 'A hook the composer will set on the image' then
    raise exception 'le swap n''a pas recopié le hook: %', v_json ->> 'on_image_text';
  end if;
  if v_json ->> 'rationale' not like 'Because %keeps coming up.' then
    raise exception 'la justification n''a pas été rendue: %', v_json ->> 'rationale';
  end if;
  if v_json #>> '{topic,angle_label}' <> 'A soft invitation' then
    raise exception 'le libellé d''angle n''a pas suivi: %', v_json #>> '{topic,angle_label}';
  end if;

  -- ⚠ ET IL EST GRATUIT. delta 0, consommation 0, et une ligne quand même.
  select consumed into v_n from public.credit_balances
   where user_id = v_u and kind = 'swap' and month = date_trunc('month', now())::date;
  if coalesce(v_n, -1) <> 0 then
    raise exception 'un swap a consommé % crédit(s)', v_n;
  end if;
  select count(*) into v_n from public.credit_ledger
   where user_id = v_u and kind = 'swap';
  if v_n < 1 then
    raise exception 'un swap n''a laissé aucune trace dans le journal.';
  end if;

  -- ── La banque épuisée se dit, elle ne boucle pas ───────────────────────
  v_json := public.swap_content_item(v_item);
  if (v_json #>> '{error,code}') is distinct from 'bank_exhausted' then
    raise exception 'un second swap sur une banque à un seul sujet n''a pas dit bank_exhausted: %', v_json;
  end if;

  perform set_config('request.jwt.claims', null, true);

  delete from public.content_segments where id = v_seg;
  delete from auth.users where id = v_u;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.swap_content_item(uuid);
--   drop function if exists public.render_rationale(text, uuid);
