-- ============================================================================
-- Tests — 20260905194933_brand_images.sql
--
-- Les quatre écarts délibérés d'avec `direction_assets` sont exactement ce que
-- ces tests fixent : un refus se RETIENT, la modération est TERMINALE, la
-- réservation se libère sur SON jour, et un appelant `authenticated` ne peut
-- pas desserrer le plafond.
--
-- Le plafond quotidien n'est pas lisible par `authenticated` (c'est voulu :
-- la table lui est révoquée), donc les lectures de solde passent par un
-- `reset role`. Cela vérifie la frontière de privilège en même temps.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000a1','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-0000000000a2','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-0000000000a1','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000a1','bbbbbbbb-0000-0000-0000-0000000000a1');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000a1','bbbbbbbb-0000-0000-0000-0000000000a1',
        'starter','cs_test_a1',7900,'paid',now());

create or replace function pg_temp.spend() returns integer language sql as
$$ select reserved_cents from public.brand_image_daily_spend where spend_date = current_date $$;
create or replace function pg_temp.actual() returns integer language sql as
$$ select actual_cents from public.brand_image_daily_spend where spend_date = current_date $$;

-- ---------------------------------------------------------------------------
-- Une inconnue n'obtient rien, et ne laisse RIEN derrière elle : le contrôle
-- de paiement passe avant l'upsert, donc pas de ligne fantôme.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a2"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','hero','abcdef0123456789', 25, 2000);
  assert v->>'reason' = 'payment_required', format('refus attendu, reçu %s', v);
  reset role;
  assert (select count(*) from public.brand_images) = 0,
    'une inconnue refusée a laissé une ligne derrière elle';
end
$$;

-- ---------------------------------------------------------------------------
-- Le chemin heureux, le jeton de réservation, et le fait qu'un appel
-- concurrent ne double PAS la réservation.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid; v_tok timestamptz; v_r jsonb; v_res int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','hero','abcdef0123456789', 25, 2000);
  assert (v->>'claimed')::boolean and v->>'reason' = 'claimed', format('réservation attendue, reçu %s', v);
  v_id := (v->>'image_id')::uuid;
  v_tok := (v->>'claim_token')::timestamptz;

  reset role;
  v_res := pg_temp.spend();
  assert v_res = 25, format('25 cents auraient dû être réservés, trouvé %s', v_res);

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','hero','abcdef0123456789', 25, 2000);
  assert v->>'reason' = 'busy', format('un second appel doit être « busy », reçu %s', v);
  reset role;
  v_res := pg_temp.spend();
  assert v_res = 25, format('« busy » a doublé la réservation : %s', v_res);

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';

  -- Un jeton périmé n'écrase jamais le gagnant.
  v_r := public.brand_images_mark_ready(v_id, v_tok - interval '1 second',
    public.brand_images_path('cccccccc-0000-0000-0000-0000000000a1','abcdef0123456789','hero'),
    100000, 25, 'gpt-image-1','high','1536x1024');
  assert v_r->>'reason' = 'stale_claim', format('un jeton périmé doit être refusé, reçu %s', v_r);

  -- Le chemin est recalculé, jamais cru sur parole.
  v_r := public.brand_images_mark_ready(v_id, v_tok, 'somewhere/else.webp',
    100000, 25, 'gpt-image-1','high','1536x1024');
  assert v_r->>'reason' = 'invalid_field', format('un chemin étranger doit être refusé, reçu %s', v_r);

  v_r := public.brand_images_mark_ready(v_id, v_tok,
    public.brand_images_path('cccccccc-0000-0000-0000-0000000000a1','abcdef0123456789','hero'),
    100000, 25, 'gpt-image-1','high','1536x1024');
  assert (v_r->>'ok')::boolean, format('le règlement aurait dû passer, reçu %s', v_r);

  reset role;
  assert pg_temp.spend() = 0, format('la réservation n''a pas été libérée : %s', pg_temp.spend());
  assert pg_temp.actual() = 25, format('le réel n''a pas été crédité : %s', pg_temp.actual());

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','hero','abcdef0123456789', 25, 2000);
  assert v->>'reason' = 'already_ready', format('la même empreinte ne se regénère pas, reçu %s', v);
end
$$;

-- ---------------------------------------------------------------------------
-- ÉCART n°2 : un échec transitoire reste rejouable, une modération non.
-- C'est la distinction que `direction_assets` ne fait pas, et c'est celle qui
-- compte : un refus de politique de contenu est un défaut de PROMPT.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid; v_tok timestamptz; v_r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','texture','1111111111111111', 5, 2000);
  v_id := (v->>'image_id')::uuid; v_tok := (v->>'claim_token')::timestamptz;

  -- Un échec sans motif est refusé : c'est précisément le défaut à éviter.
  v_r := public.brand_images_mark_failed(v_id, v_tok, 'failed', '');
  assert v_r->>'reason' = 'invalid_field', format('un échec sans motif doit être refusé, reçu %s', v_r);

  v_r := public.brand_images_mark_failed(v_id, v_tok, 'failed', 'upstream timeout after 2 attempts');
  assert (v_r->>'ok')::boolean, format('l''échec aurait dû être enregistré, reçu %s', v_r);
  reset role;
  assert pg_temp.spend() = 0,
    format('un échec réglé doit libérer sa réservation, trouvé %s', pg_temp.spend());

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','texture','1111111111111111', 5, 2000);
  assert (v->>'claimed')::boolean,
    format('un échec transitoire ne doit pas lui coûter la place : %s', v);
  v_id := (v->>'image_id')::uuid; v_tok := (v->>'claim_token')::timestamptz;

  v_r := public.brand_images_mark_failed(v_id, v_tok, 'moderated', 'content policy refused the prompt');
  assert (v_r->>'ok')::boolean, format('la modération aurait dû être enregistrée, reçu %s', v_r);

  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','texture','1111111111111111', 5, 2000);
  assert v->>'reason' = 'already_moderated',
    format('une modération ne se rejoue pas : %s', v);

  -- Mais une AUTRE empreinte est un autre prompt, et a le droit de tourner.
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','texture','2222222222222222', 5, 2000);
  assert (v->>'claimed')::boolean,
    format('une empreinte différente est un prompt différent : %s', v);
  perform public.brand_images_mark_failed((v->>'image_id')::uuid, (v->>'claim_token')::timestamptz,
                                          'failed', 'upstream 503');
end
$$;

-- ---------------------------------------------------------------------------
-- ÉCART n°1 : le plafond refuse ET l'écrit sur la ligne. Un dégradé doit
-- toujours être explicable après coup.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_row public.brand_images%rowtype;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','ambient_a','3333333333333333', 25, 1);
  assert v->>'reason' = 'budget_exceeded', format('le plafond aurait dû refuser, reçu %s', v);

  reset role;
  select * into v_row from public.brand_images
   where brand_kit_id = 'cccccccc-0000-0000-0000-0000000000a1' and slot = 'ambient_a';
  assert v_row.status = 'refused_cap', format('statut attendu refused_cap, trouvé %s', v_row.status);
  assert v_row.failure_reason <> '', 'un refus de plafond doit se dire sur la ligne';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','ambient_a','3333333333333333', 25, 2000);
  assert (v->>'claimed')::boolean, format('un refus de plafond doit rester rejouable : %s', v);
  perform public.brand_images_mark_failed((v->>'image_id')::uuid, (v->>'claim_token')::timestamptz,
                                           'failed', 'upstream 503');
end
$$;

-- ---------------------------------------------------------------------------
-- ÉCART n°4 : l'appelante est `authenticated`. Elle peut RESSERRER les bornes,
-- jamais les desserrer -- ni par un plafond forgé, ni par une estimation nulle.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  reset role;
  update public.app_settings set value = '10' where key = 'brand_images_daily_cap_cents';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','ambient_b','4444444444444444', 25, 999999999);
  assert v->>'reason' = 'budget_exceeded',
    format('un plafond forgé doit être ramené à la borne serveur : %s', v);
  reset role;
  update public.app_settings set value = '2000' where key = 'brand_images_daily_cap_cents';
end
$$;

do $$
declare v jsonb; v_before int; v_after int;
begin
  reset role;
  v_before := coalesce(pg_temp.spend(), 0);
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','post_bg_1','5555555555555555', 0, 2000);
  assert (v->>'claimed')::boolean, format('réservation attendue, reçu %s', v);
  reset role;
  v_after := pg_temp.spend();
  assert v_after - v_before >= 4,
    format('une estimation à zéro doit quand même réserver le plancher, réservé %s', v_after - v_before);
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  perform public.brand_images_mark_failed((v->>'image_id')::uuid, (v->>'claim_token')::timestamptz,
                                           'failed', 'upstream 503');
end
$$;

-- ---------------------------------------------------------------------------
-- L'interrupteur : il refuse tout, et ne laisse aucune ligne derrière lui.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_rows int;
begin
  reset role;
  select count(*) into v_rows from public.brand_images;
  update public.app_settings set value = 'false' where key = 'brand_images_enabled';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';
  v := public.brand_images_claim('cccccccc-0000-0000-0000-0000000000a1','post_bg_2','6666666666666666', 5, 2000);
  assert v->>'reason' = 'disabled', format('l''interrupteur aurait dû refuser, reçu %s', v);
  reset role;
  assert (select count(*) from public.brand_images) = v_rows,
    'l''interrupteur a laissé une ligne derrière lui';
  update public.app_settings set value = 'true' where key = 'brand_images_enabled';
end
$$;

-- ---------------------------------------------------------------------------
-- La lecture : seul `ready` À L'EMPREINTE COURANTE est une image. Tout le
-- reste est un dégradé, et tout le reste dit pourquoi.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; e jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a1"}';

  v := public.get_brand_images('cccccccc-0000-0000-0000-0000000000a1','abcdef0123456789');
  select el into e from jsonb_array_elements(v) el where el->>'slot' = 'hero';
  assert (e->>'current')::boolean, format('le héros devrait être courant, reçu %s', e);
  assert e->>'storage_path' = 'cccccccc-0000-0000-0000-0000000000a1/images/abcdef0123456789/hero.webp',
    format('chemin inattendu : %s', e);

  v := public.get_brand_images('cccccccc-0000-0000-0000-0000000000a1','9999999999999999');
  select el into e from jsonb_array_elements(v) el where el->>'slot' = 'hero';
  assert not (e->>'current')::boolean,
    format('une image périmée ne doit jamais être exposée : %s', e);

  assert not exists (
    select 1 from jsonb_array_elements(v) el
     where el->>'status' <> 'ready' and coalesce(el->>'failure_reason','') = ''
  ), format('tout dégradé doit être explicable : %s', v);
end
$$;

-- ---------------------------------------------------------------------------
-- Rien de tout cela ne s'ouvre à une autre, ni par la RPC ni par la table.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000a2"}';
  v := public.get_brand_images('cccccccc-0000-0000-0000-0000000000a1','abcdef0123456789');
  assert v->'error'->>'code' = 'payment_required', format('lecture inconnue : %s', v);
  assert (select count(*) from public.brand_images) = 0, 'RLS a laissé une inconnue lire des lignes';
end
$$;

reset role;
rollback;
