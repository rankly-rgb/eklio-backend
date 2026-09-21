-- ============================================================================
-- Eklio — un post peut être demandé, pas seulement reçu
-- ============================================================================
--
-- Jusqu'ici le produit ne savait écrire qu'un MOIS ENTIER, en batch, le 1er.
-- Quand elle crée un post ou rouvre un post inachevé, elle tombe sur un
-- formulaire vide — exactement ce que ce produit promet de ne jamais lui
-- montrer.
--
-- ⚠ ET IL N'Y A PAS DE SECOND CHEMIN DE GÉNÉRATION. Même banque, même modèle,
-- mêmes gardes déontologiques, même moteur de composition, même journal de
-- crédits. La seule différence est l'appel : synchrone au lieu du Batch,
-- toujours derrière le même préfixe mis en cache.
--
-- ── ⚠ LE TROU STRUCTUREL QUE CETTE MIGRATION OUVRE D'ABORD ──────────────
--
-- **Un payload de diagramme n'avait nulle part où vivre sur un post.** Il vit
-- sur `content_topics.payload`, et un sujet de banque est du STOCK partagé
-- entre praticiennes. Une idée à elle n'est pas du stock : l'écrire dans la
-- banque la ferait entrer dans le pool anti-collision des autres.
--
-- Donc `content_items.payload`. Nullable, et null veut dire « celui du sujet »
-- — exactement comme `compose_archetype` porte « la mise en page du sujet »
-- quand il est null.
-- ============================================================================

alter table public.content_items
  add column if not exists payload jsonb;

comment on column public.content_items.payload is
  'The diagram payload of THIS post, when it has one of its own. Null means "the topic''s payload", which is the normal state for a post drawn from the bank. Written by generation, never by the editor: update_content_item does not accept it.';

-- ⚠ UN PAYLOAD SANS MISE EN PAGE NE VEUT RIEN DIRE. Le validateur prend un
-- archétype ; sans lui il n'y a rien contre quoi valider, et le moteur n'aurait
-- pas de module à appeler.
alter table public.content_items
  drop constraint if exists content_items_payload_needs_archetype;
alter table public.content_items
  add constraint content_items_payload_needs_archetype
  check (payload is null or compose_archetype is not null);

-- ⚠ ET IL EST VALIDÉ PAR LE MÊME VALIDATEUR QUE LA BANQUE. Une seconde
-- définition de « ce qu'est un payload de cycle » dériverait de la première le
-- jour où l'un des onze archétypes change de bornes.
alter table public.content_items
  drop constraint if exists content_items_payload_valid;
alter table public.content_items
  add constraint content_items_payload_valid
  check (
    payload is null
    or public.content_topic_payload_valid(compose_archetype, payload)
  );


-- ============================================================================
-- Le payload d'un post est du texte publié, comme celui d'un sujet
-- ============================================================================
-- ⚠ MÊME GARDE QUE `20260920160000`, POUR LA MÊME RAISON. Un mot posé sur la
-- carte est publié aussi fort qu'une phrase de légende. La garde existante sur
-- `content_items` lit `title`, `caption`, `on_image_text` et `alt_text` ; elle
-- ne connaissait pas `payload`, qui n'existait pas.
create or replace function public.content_items_payload_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block   text;
  v_text    text;
  v_cliches text[];
begin
  if new.payload is null then
    return new;
  end if;

  v_text := public.content_topic_text(new.payload);
  if coalesce(btrim(v_text), '') = '' then
    return new;
  end if;

  v_block := public.ethics_blocks(v_text);
  if v_block is not null then
    raise exception 'Advertising ethics: %', v_block
      using errcode = 'check_violation',
            hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
  end if;

  v_cliches := public.usp_banned_phrases_check(v_text);
  if coalesce(array_length(v_cliches, 1), 0) > 0 then
    raise exception 'Worn phrasing on the card: %', array_to_string(v_cliches, ', ')
      using errcode = 'check_violation',
            hint = 'These phrases appear on every practice website. Say the thing itself.';
  end if;

  return new;
end
$$;

revoke all on function public.content_items_payload_ethics_gate() from public, anon, authenticated;

drop trigger if exists content_items_payload_ethics_gate on public.content_items;
create trigger content_items_payload_ethics_gate
  before insert or update of payload on public.content_items
  for each row execute function public.content_items_payload_ethics_gate();


-- ============================================================================
-- Trois sujets proposés, GRATUITEMENT et sans rien consommer
-- ============================================================================
-- ⚠ PROPOSER N'EST PAS TIRER. `assign_topic_to_kit` écrit une ligne
-- d'assignation : un sujet montré puis refusé serait brûlé à vie pour elle.
-- Cette fonction ne fait que REGARDER, et « Show three others » peut donc
-- tourner autant de fois qu'elle veut.
--
-- ⚠ ET C'EST `next_topic_for_kit`, PAS `next_topic_for_user`. Le brief nomme
-- la seconde ; elle n'existe pas. Les sujets sont assignés PAR KIT — c'est
-- l'arbitrage de grain consigné au §10.4 du rapport d'implémentation : le
-- contenu appartient à une marque, les crédits à une personne. Une même
-- praticienne avec deux cabinets a deux calendriers et deux banques tirées.
create or replace function public.suggest_topics_for_kit(
  p_brand_kit_id uuid,
  p_month        date default null,
  p_limit        integer default 3,
  p_exclude      uuid[] default '{}'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_error text;
  v_out   jsonb;
begin
  /*
   * ⚠ LE DROIT D'ABORD, ET IL MANQUAIT. Cette fonction lisait la banque en
   * joignant `brand_kits` sans passer par `content_kit_access` : un kit
   * impayé, ou celui de quelqu'un d'autre, recevait des suggestions.
   *
   * Gratuites ne veut pas dire publiques. La banque est le stock du produit ;
   * la montrer à qui n'y a pas droit, c'est la livrer.
   *
   * `content_kit_access` répond `not_found` avant `payment_required`, comme
   * partout : un 402 à une inconnue confirmerait que ce kit existe.
   */
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  with kit as materialized (
    select coalesce(pb.modality_ids, '{}')       as modalities,
           coalesce(pb.client_persona_ids, '{}') as personas,
           upper(nullif(btrim(coalesce(pb.state, '')), '')) as state_code,
           pr.user_id                            as user_id,
           bk.id                                 as kit_id
      from public.brand_kits bk
      join public.projects      pr on pr.id = bk.project_id
      left join public.project_briefs pb on pb.project_id = pr.id
     where bk.id = p_brand_kit_id
  ),
  blocked as materialized (
    select distinct ta.topic_id
      from public.topic_assignments ta
      join public.brand_kits   obk on obk.id = ta.brand_kit_id
      join public.projects     opr on opr.id = obk.project_id
      left join public.project_briefs opb on opb.project_id = opr.id
     cross join kit k
     where ta.assigned_at > now() - public.topic_collision_window()
       and opr.user_id is distinct from k.user_id
       and k.state_code is not null
       and upper(nullif(btrim(coalesce(opb.state, '')), '')) = k.state_code
       and coalesce(opb.modality_ids, '{}') && k.modalities
  ),
  mine as materialized (
    select ta.topic_id from public.topic_assignments ta
     where ta.brand_kit_id = p_brand_kit_id
  )
  select coalesce(jsonb_agg(row_to_json(picked)::jsonb order by picked.rank), '[]'::jsonb)
    from (
      select t.id,
             t.title,
             t.hook,
             t.intent                                            as angle,
             ci_intent.label                                     as angle_label,
             t.archetype_key,
             t.timely,
             public.render_rationale(t.rationale_template, p_brand_kit_id) as rationale,
             row_number() over (
               order by
                 (case when s.modality_id = any (k.modalities) then 2 else 0 end)
                 + (case when s.persona_id = any (k.personas) then 2 else 0 end)
                 + (case when s.state_code is not null then 1 else 0 end)
                 + (case when t.timely then 3 else 0 end)
                 desc,
                 t.created_at desc,
                 t.id
             ) as rank
        from public.content_topics t
        join public.content_segments s on s.id = t.segment_id
        left join public.content_intents ci_intent on ci_intent.id = t.intent
       cross join kit k
       where t.ethics_reviewed_at is not null
         and (t.expires_at is null or t.expires_at > now())
         and not (t.id = any (coalesce(p_exclude, '{}')))
         and not exists (select 1 from mine m where m.topic_id = t.id)
         and not exists (select 1 from blocked b where b.topic_id = t.id)
         and (s.modality_id = any (k.modalities) or s.persona_id = any (k.personas))
         and (s.state_code is null or s.state_code = k.state_code)
       order by rank
       limit greatest(coalesce(p_limit, 3), 0)
    ) picked
  into v_out;

  return coalesce(v_out, '[]'::jsonb);
end
$$;

comment on function public.suggest_topics_for_kit(uuid, date, integer, uuid[]) is
  'Up to N bank topics this kit could be given, WITHOUT assigning any of them. Free and unlimited: showing a topic and having it refused must not burn it for life, which is what assign_topic_to_kit would do. `p_exclude` is how "show three others" walks past the ones already seen.';

revoke all on function public.suggest_topics_for_kit(uuid, date, integer, uuid[]) from public, anon;
grant execute on function public.suggest_topics_for_kit(uuid, date, integer, uuid[]) to authenticated, service_role;


-- ============================================================================
-- « Write it » — un crédit, une fois, même si elle double-clique
-- ============================================================================
-- ⚠ L'IDEMPOTENCE EST EN BASE, PAS DANS LE BOUTON. Un bouton désactivé pendant
-- la requête protège d'un double clic et de rien d'autre : deux onglets, un
-- réseau qui rejoue, un retour arrière puis un nouveau clic passent tous à
-- côté. Ce qui tient est une clef unique sur une table.
create table if not exists public.on_demand_writes (
  id              uuid primary key default gen_random_uuid(),
  content_item_id uuid not null references public.content_items(id) on delete cascade,
  -- La clef que le client génère pour CETTE intention d'écriture. Deux clics
  -- sur le même bouton portent la même ; deux demandes distinctes non.
  idempotency_key text not null,
  reservation_id  uuid not null references public.credit_ledger(id) on delete cascade,
  state           text not null default 'reserved',
  created_at      timestamptz not null default now(),
  settled_at      timestamptz,

  constraint on_demand_writes_key_check check (char_length(idempotency_key) between 8 and 128),
  constraint on_demand_writes_state_check check (state in ('reserved', 'written', 'released')),
  constraint on_demand_writes_unique unique (content_item_id, idempotency_key)
);

comment on table public.on_demand_writes is
  'One row per "Write it" intent. The unique key on (item, idempotency_key) is what makes a double click cost one credit instead of two -- a disabled button protects against a double click and nothing else: two tabs, a replayed request and a back-then-click all walk past it.';

create index if not exists on_demand_writes_item_idx
  on public.on_demand_writes (content_item_id, created_at desc);

alter table public.on_demand_writes enable row level security;

-- ⚠ AUCUNE POLICY OUVERTE. Cette table se lit et s'écrit uniquement par les
-- fonctions SECURITY DEFINER ci-dessous. Le navigateur n'a rien à y faire :
-- une cliente qui pourrait insérer une ligne pourrait se réserver un crédit.
drop policy if exists on_demand_writes_no_browser on public.on_demand_writes;
create policy on_demand_writes_no_browser on public.on_demand_writes
  for all to authenticated, anon using (false) with check (false);

/*
 * ⚠ LA POLICY NE SUFFIT PAS, ET C'EST MON PROPRE GARDE-FOU QUI L'A DIT.
 *
 * `enable row level security` + une policy qui refuse bloque bien la ligne,
 * mais le GRANT de table reste : `has_table_privilege('authenticated', …,
 * 'INSERT')` répondait vrai. Deux verrous différents, et seul le second se
 * lit dans un audit de privilèges.
 *
 * Ce dépôt révoque explicitement sur ses tables internes — `stripe_events`,
 * `banned_phrases`, `comp_grants` — et celle-ci en est une : une cliente qui
 * pourrait y insérer une ligne pourrait se réserver un crédit.
 */
revoke all on table public.on_demand_writes from anon, authenticated;


create or replace function public.begin_on_demand_write(
  p_item_id         uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit      uuid;
  v_user     uuid;
  v_error    text;
  v_existing public.on_demand_writes%rowtype;
  v_month    date;
  v_res      jsonb;
  v_id       uuid;
begin
  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = p_item_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  /*
   * ⚠ LA CLEF EST CONSULTÉE AVANT TOUTE RÉSERVATION. Le second clic doit
   * retrouver la première ligne, pas en créer une seconde puis la relâcher :
   * un journal plein de paires réservation/libération ne dit plus rien.
   */
  select * into v_existing from public.on_demand_writes
   where content_item_id = p_item_id and idempotency_key = p_idempotency_key;

  if found then
    return jsonb_build_object(
      'ok', true,
      'reason', 'already_started',
      'write_id', v_existing.id,
      'reservation_id', v_existing.reservation_id,
      'state', v_existing.state
    );
  end if;

  select pr.user_id into v_user
    from public.brand_kits bk join public.projects pr on pr.id = bk.project_id
   where bk.id = v_kit;

  select coalesce(ci.scheduled_for, current_date) into v_month
    from public.content_items ci where ci.id = p_item_id;
  v_month := date_trunc('month', v_month)::date;

  /*
   * ⚠ LE PLAFOND EST APPLIQUÉ ICI, EN SQL. `reserve_credit` refuse quand le
   * quota mensuel de `regeneration` est atteint (10 au plan standard), et
   * cette fonction n'a aucun moyen de le contourner : elle ne sait pas ce
   * qu'est un quota, seulement qu'on lui a répondu non.
   */
  v_res := public.reserve_credit(
    p_user => v_user, p_kind => 'regeneration', p_reason => 'write ' || p_item_id::text,
    p_ref_type => 'content_item', p_ref_id => p_item_id, p_month => v_month
  );

  if not coalesce((v_res ->> 'ok')::boolean, false) then
    -- `quota_exhausted` remonte tel quel : l'écran dit la date de renouvellement.
    return public.content_error(coalesce(v_res #>> '{error,code}', v_res ->> 'reason', 'quota_exhausted'));
  end if;

  begin
    insert into public.on_demand_writes (content_item_id, idempotency_key, reservation_id)
    values (p_item_id, p_idempotency_key, (v_res ->> 'reservation_id')::uuid)
    returning id into v_id;
  exception when unique_violation then
    /*
     * ⚠ LA COURSE, RÉSOLUE PAR LA CONTRAINTE. Deux requêtes simultanées
     * passent toutes les deux la lecture ci-dessus ; une seule insère. La
     * perdante relâche SON crédit et rend la ligne gagnante, donc une seule
     * dépense subsiste.
     */
    perform public.settle_credit((v_res ->> 'reservation_id')::uuid, null, false);
    select * into v_existing from public.on_demand_writes
     where content_item_id = p_item_id and idempotency_key = p_idempotency_key;
    return jsonb_build_object(
      'ok', true, 'reason', 'already_started',
      'write_id', v_existing.id, 'reservation_id', v_existing.reservation_id,
      'state', v_existing.state
    );
  end;

  return jsonb_build_object(
    'ok', true, 'reason', 'reserved',
    'write_id', v_id, 'reservation_id', (v_res ->> 'reservation_id')::uuid, 'state', 'reserved'
  );
end
$$;

comment on function public.begin_on_demand_write(uuid, text) is
  'Reserves ONE regeneration credit for a "Write it", idempotently. A second call with the same key returns the first row and reserves nothing. The monthly ceiling is applied by reserve_credit, in SQL -- this function cannot bypass it because it does not know what a quota is.';

revoke all on function public.begin_on_demand_write(uuid, text) from public, anon;
grant execute on function public.begin_on_demand_write(uuid, text) to authenticated, service_role;


-- ============================================================================
-- Le résultat, écrit sur le post et réglé en une transaction
-- ============================================================================
create or replace function public.apply_on_demand_write(
  p_write_id          uuid,
  p_title             text,
  p_caption           text,
  p_on_image_text     text,
  p_alt_text          text,
  p_compose_archetype text,
  p_payload           jsonb,
  p_rationale         text default null,
  p_topic_id          uuid default null,
  p_cost_usd          numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_write public.on_demand_writes%rowtype;
  v_kit   uuid;
  v_error text;
begin
  select * into v_write from public.on_demand_writes where id = p_write_id;
  if not found then
    return public.content_error('not_found');
  end if;

  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = v_write.content_item_id;
  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  /*
   * ⚠ DÉJÀ ÉCRIT VEUT DIRE : ON NE RÉÉCRIT PAS, ET ON NE REFACTURE PAS. C'est
   * la seconde moitié de l'idempotence — la première empêche de réserver deux
   * fois, celle-ci empêche d'écrire deux fois si la génération est rejouée.
   */
  if v_write.state <> 'reserved' then
    return jsonb_build_object('ok', true, 'reason', 'already_written',
                              'id', v_write.content_item_id);
  end if;

  update public.content_items ci set
    title             = coalesce(left(p_title, 34), ci.title),
    caption           = coalesce(p_caption, ci.caption),
    on_image_text     = coalesce(p_on_image_text, ci.on_image_text),
    alt_text          = coalesce(p_alt_text, ci.alt_text),
    compose_archetype = coalesce(p_compose_archetype, ci.compose_archetype),
    payload           = coalesce(p_payload, ci.payload),
    rationale         = coalesce(p_rationale, ci.rationale),
    topic_id          = coalesce(p_topic_id, ci.topic_id),
    status            = case when ci.status = 'proposed' then 'draft' else ci.status end,
    updated_at        = now()
  where ci.id = v_write.content_item_id;

  update public.on_demand_writes
     set state = 'written', settled_at = now()
   where id = p_write_id;

  -- Le crédit est réglé avec son coût réel, comme partout ailleurs.
  perform public.settle_credit(v_write.reservation_id, p_cost_usd, true);

  return jsonb_build_object('ok', true, 'reason', 'written', 'id', v_write.content_item_id);
end
$$;

comment on function public.apply_on_demand_write(uuid, text, text, text, text, text, jsonb, text, uuid, numeric) is
  'Writes a generated post onto its item and settles the credit, in one transaction. Idempotent on the write row''s state: a replayed generation does not rewrite and does not re-charge.';

revoke all on function public.apply_on_demand_write(uuid, text, text, text, text, text, jsonb, text, uuid, numeric) from public, anon;
grant execute on function public.apply_on_demand_write(uuid, text, text, text, text, text, jsonb, text, uuid, numeric) to authenticated, service_role;


create or replace function public.release_on_demand_write(p_write_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_write public.on_demand_writes%rowtype;
  v_error text;
  v_kit   uuid;
begin
  select * into v_write from public.on_demand_writes where id = p_write_id;
  if not found then
    return public.content_error('not_found');
  end if;

  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = v_write.content_item_id;
  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  if v_write.state <> 'reserved' then
    return jsonb_build_object('ok', true, 'reason', 'not_reserved');
  end if;

  /*
   * ⚠ LA LIGNE EST SUPPRIMÉE, PAS MARQUÉE. Une génération qui échoue ne doit
   * pas bloquer la suivante : si la ligne restait avec sa clef, un nouveau
   * « Write it » identique retrouverait un écrit mort et ne repartirait
   * jamais. Le crédit, lui, est relâché — rien n'a été produit.
   */
  perform public.settle_credit(v_write.reservation_id, null, false);
  delete from public.on_demand_writes where id = p_write_id;

  return jsonb_build_object('ok', true, 'reason', 'released');
end
$$;

revoke all on function public.release_on_demand_write(uuid) from public, anon;
grant execute on function public.release_on_demand_write(uuid) to authenticated, service_role;


-- ============================================================================
-- Et l'écran relit ce qui a été écrit
-- ============================================================================
-- Corps de `20260921110000`, plus `payload`. Repris en entier : `create or
-- replace` remplace tout, et une clef perdue disparaît de tous les écrans en
-- silence — ce qui est déjà arrivé une fois avec `theme`.
create or replace function public.content_item_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select jsonb_build_object(
    'id',            ci.id,
    'brand_kit_id',  ci.brand_kit_id,
    'archetype',     ci.archetype,
    'register',      ci.register,
    'month_id',      ci.month_id,
    'theme',         ci.theme,
    'status',        ci.status,
    'title',         ci.title,
    'caption',       ci.caption,
    'on_image_text', ci.on_image_text,
    'alt_text',      ci.alt_text,
    'tags',          to_jsonb(ci.tags),
    'category',      ci.category,
    'image_slot',    ci.image_slot,
    'scheduled_for', ci.scheduled_for,
    'created_at',    ci.created_at,
    'updated_at',    ci.updated_at,
    'posted',        coalesce(last_pub.action = 'published', false),
    'posted_at',     case when last_pub.action = 'published' then last_pub.occurred_at end,
    'channel',       case when last_pub.action = 'published' then last_pub.channel end,
    'rationale',     ci.rationale,
    'compose_archetype', ci.compose_archetype,
    -- Le diagramme de CE post, quand il en a un à lui.
    'payload',       ci.payload,
    'topic',         case when t.id is null then null else jsonb_build_object(
                       'id',          t.id,
                       'angle',       t.intent,
                       'angle_label', ci_intent.label,
                       'archetype_key', t.archetype_key,
                       'timely',      t.timely
                     ) end
  )
  from public.content_items ci
  left join public.content_topics  t         on t.id = ci.topic_id
  left join public.content_intents ci_intent on ci_intent.id = t.intent
  left join lateral (
    select cp.action, cp.occurred_at, cp.channel
      from public.content_publications cp
     where cp.content_item_id = ci.id
     order by cp.occurred_at desc, cp.id desc
     limit 1
  ) last_pub on true
  where ci.id = p_id
$function$;


-- ============================================================================
-- GUARD RAILS
-- ============================================================================
do $guard$
declare
  v_def text;
  v_key text;
  v_expected text[] := array[
    'alt_text','archetype','brand_kit_id','caption','category','channel',
    'compose_archetype','created_at','id','image_slot','month_id',
    'on_image_text','payload','posted','posted_at','rationale','register',
    'scheduled_for','status','tags','theme','title','topic','updated_at'
  ];
begin
  -- ── 1. Le json porte encore toutes ses clefs, plus `payload` ────────────
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'content_item_json';
  foreach v_key in array v_expected loop
    if v_def not like '%''' || v_key || '''%' then
      raise exception 'content_item_json a perdu la clef %', v_key;
    end if;
  end loop;

  -- ── 2. Le payload N'EST PAS patchable depuis l'éditeur ──────────────────
  -- ⚠ Il vient de la génération, qui l'a fait valider par le modèle puis par
  -- la garde déontologique. Le rendre patchable ouvrirait un chemin où un
  -- diagramme arrive sans être passé par l'un ni par l'autre.
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'update_content_item';
  if v_def like '%''payload''%' then
    raise exception 'update_content_item accepte payload; un diagramme pourrait entrer sans garde';
  end if;

  -- ── 3. Le navigateur ne touche ni la table d'écritures ni ses fonctions ─
  if has_table_privilege('authenticated', 'public.on_demand_writes', 'INSERT') then
    raise exception 'authenticated peut insérer dans on_demand_writes; elle pourrait se réserver un crédit';
  end if;
  if has_function_privilege('anon', 'public.begin_on_demand_write(uuid,text)'::regprocedure, 'EXECUTE') then
    raise exception 'anon peut démarrer une écriture';
  end if;

  -- ── 4. Les suggestions passent par le contrôle de droit ─────────────────
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'suggest_topics_for_kit';
  if v_def not like '%content_kit_access%' then
    raise exception 'suggest_topics_for_kit ne vérifie pas le droit; un kit impayé recevrait la banque';
  end if;

  -- ── 5. Un payload sans mise en page est refusé ──────────────────────────
  if not exists (
    select 1 from pg_constraint
     where conname = 'content_items_payload_needs_archetype'
       and conrelid = 'public.content_items'::regclass
  ) then
    raise exception 'la contrainte payload/compose_archetype a disparu';
  end if;
end
$guard$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.release_on_demand_write(uuid);
--   drop function if exists public.apply_on_demand_write(uuid,text,text,text,text,text,jsonb,text,uuid,numeric);
--   drop function if exists public.begin_on_demand_write(uuid,text);
--   drop table if exists public.on_demand_writes;
--   drop function if exists public.suggest_topics_for_kit(uuid,date,integer,uuid[]);
--   drop trigger if exists content_items_payload_ethics_gate on public.content_items;
--   drop function if exists public.content_items_payload_ethics_gate();
--   alter table public.content_items drop column payload;
--   -- puis restaurer content_item_json depuis 20260921110000
