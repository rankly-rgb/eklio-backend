-- ============================================================================
-- Une fermeture est une DÉCISION, avec sa date et la photo de ses causes
-- ============================================================================
-- `20260914190000_sellability.test.sql` portait une alarme : « le jour où un
-- État devient vendable, la moitié mesurable de la raison tombe, ce test vire
-- au rouge, et quelqu'un doit reprendre la décision au lieu de la laisser
-- dormir ». La Californie l'a fait virer au rouge. La décision est reprise :
--
--   FOUNDATION ET ROSTER RESTENT FERMÉS — 17 septembre 2026.
--   Raison : les prix Stripe LIVE ne sont pas configurés, et les textes n'ont
--   pas encore été jugés.
--
-- ⚠ ET C'EST POUR ÇA QUE CE FICHIER CRÉE UNE TABLE PLUTÔT QUE D'ÉDITER UN
-- TEST. Une alarme qui reste rouge n'est plus une alarme : on apprend à
-- l'ignorer, et le jour où elle dit autre chose, personne ne regarde. Mais la
-- remettre au vert en supprimant sa condition serait pire — la fermeture
-- redeviendrait ce qu'elle était avant, une chose « en attendant » que
-- l'oubli rend permanente.
--
-- La sortie n'est ni l'un ni l'autre : on ENREGISTRE la décision avec la
-- PHOTO de ses causes mesurables au moment où elle est prise. Le test compare
-- alors le monde à la photo, et non plus à un zéro figé. Il est vert tant que
-- rien n'a bougé, et il redevient rouge au prochain CHANGEMENT DE CAUSE — un
-- deuxième État qui s'ouvre, une plateforme acceptée ou retirée, ou quelqu'un
-- qui bascule `plans.sellable` sans repasser par ici.
--
-- ⚠ DEUX DES TROIS CONDITIONS NE SE LISENT PAS EN SQL, et il faut le dire
-- plutôt que de faire semblant : les prix Stripe LIVE et « j'ai jugé les
-- textes » ne sont dans aucune table. Elles vivent en toutes lettres dans
-- `conditions_to_revisit`, et c'est une personne qui les relit. La photo ne
-- couvre que ce qu'une machine peut voir — le prétendre autrement serait
-- exactement le genre de garantie creuse que ce dépôt refuse.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. La table
-- ---------------------------------------------------------------------------
create table if not exists public.sellability_decisions (
  tier                  text primary key references public.plans(tier) on delete cascade,
  decided_on            date    not null,
  decided_by            text    not null,
  sellable              boolean not null,
  reason                text    not null,
  conditions_to_revisit text    not null,
  /*
   * ⚠ LA PHOTO. Ces deux entiers ne sont pas de la statistique : ce sont les
   * causes mesurables telles qu'elles étaient quand la décision a été prise.
   * Le test compare le monde À EUX. Les mettre à jour sans reprendre la
   * décision, c'est faire taire l'alarme — et la contrainte ci-dessous ne peut
   * pas l'empêcher, seule une relecture le peut.
   */
  states_sellable       int     not null check (states_sellable    >= 0),
  accepted_platforms    int     not null check (accepted_platforms >= 0),

  constraint sellability_decisions_reason_check
    check (btrim(reason) <> '' and btrim(conditions_to_revisit) <> '' and btrim(decided_by) <> '')
);

comment on table public.sellability_decisions is
  'Why a plan is open or closed, who decided, when, and what the measurable causes were AT THAT MOMENT. The sellability test compares the world to this snapshot instead of to a frozen zero: green while nothing moved, red again the next time a cause changes. A closure with no row here is a closure nobody owns.';
comment on column public.sellability_decisions.states_sellable is
  'How many states were open when this was decided. Not a statistic: the test fires when the live count stops matching it.';
comment on column public.sellability_decisions.accepted_platforms is
  'How many site_platforms were accepted when this was decided. Same contract as states_sellable.';
comment on column public.sellability_decisions.conditions_to_revisit is
  'The conditions to revisit, in words -- including the ones SQL cannot read (a LIVE Stripe price, a human having read the copy). A person reads these; the snapshot columns cover only what a machine can see.';

/*
 * ⚠ AUCUN NAVIGATEUR NE LIT CETTE TABLE. C'est de l'exploitation, pas du
 * catalogue : RLS active et aucune politique, donc `anon` et `authenticated`
 * n'y voient rien même si un jour quelqu'un leur accorde un SELECT.
 */
alter table public.sellability_decisions enable row level security;
revoke all on public.sellability_decisions from anon, authenticated;
grant select, insert, update, delete on public.sellability_decisions to service_role;


-- ---------------------------------------------------------------------------
-- 2. La décision du 17 septembre
-- ---------------------------------------------------------------------------
insert into public.sellability_decisions
  (tier, decided_on, decided_by, sellable, reason, conditions_to_revisit,
   states_sellable, accepted_platforms)
select t.tier,
       date '2026-09-17',
       'nainarahal@gmail.com',
       false,
       'Les prix Stripe LIVE ne sont pas configurés (STRIPE_PRICE_FOUNDATION et '
       'STRIPE_PRICE_ROSTER sont absentes de l''environnement de production : la '
       'session de checkout échoue APRÈS le clic), et les textes n''ont pas encore '
       'été jugés. La Californie est ouverte depuis le 17 septembre, donc la '
       'condition « au moins un État vendable » est désormais REMPLIE — elle n''est '
       'plus ce qui ferme. Encaisser puis refuser reste pire que ne pas vendre.',
       'a) STRIPE_PRICE_FOUNDATION et STRIPE_PRICE_ROSTER dans l''environnement de '
       'production, pointant sur des prix Stripe actifs en mode LIVE. Ne se lit pas '
       'en SQL. '
       'b) au moins un État vendable : REMPLIE le 2026-09-17 (Californie, 5 couples). '
       'c) au moins une plateforme acceptée : REMPLIE (wordpress). '
       'd) les textes jugés par leur propriétaire. Ne se lit pas en SQL. '
       'Quand (a) et (d) tiennent : UPDATE dans une migration neuve qui revérifie '
       'les quatre ET met à jour la ligne de cette table.',
       (select count(*) from public.sellable_states where sellable),
       (select count(*) from public.site_platforms where status = 'accepted')
  from (values ('foundation'), ('roster')) as t(tier)
on conflict (tier) do update
  set decided_on            = excluded.decided_on,
      decided_by            = excluded.decided_by,
      sellable              = excluded.sellable,
      reason                = excluded.reason,
      conditions_to_revisit = excluded.conditions_to_revisit,
      states_sellable       = excluded.states_sellable,
      accepted_platforms    = excluded.accepted_platforms;


-- ---------------------------------------------------------------------------
-- 3. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  -- La décision existe pour les deux paliers, et elle dit « fermé ».
  select count(*) into v_n from public.sellability_decisions
   where tier in ('foundation', 'roster') and sellable = false;
  if v_n <> 2 then
    raise exception
      'décision: % ligne(s) fermées enregistrées, attendu 2. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET ELLE DIT LA MÊME CHOSE QUE LA COLONNE. Une décision qui contredit
  -- l'état réel est pire que pas de décision du tout : elle donne l'air d'un
  -- registre à jour.
  select count(*) into v_n
    from public.sellability_decisions d
    join public.plans p on p.tier = d.tier
   where p.sellable is distinct from d.sellable;
  if v_n <> 0 then
    raise exception
      'décision: % palier(s) dont la décision enregistrée contredit plans.sellable. Migration abandonnée.', v_n;
  end if;

  -- La photo est celle du monde d'aujourd'hui.
  select count(*) into v_n
    from public.sellability_decisions d
   where d.states_sellable
           is distinct from (select count(*) from public.sellable_states where sellable)
      or d.accepted_platforms
           is distinct from (select count(*) from public.site_platforms where status = 'accepted');
  if v_n <> 0 then
    raise exception
      'décision: % photo(s) ne correspondent pas au monde au moment de l''enregistrement. Migration abandonnée.', v_n;
  end if;

  -- La photo enregistre bien 1 État et 1 plateforme : sans ce contrôle, deux
  -- zéros se compareraient égaux et le mécanisme serait creux.
  select count(*) into v_n from public.sellability_decisions
   where states_sellable = 1 and accepted_platforms = 1;
  if v_n <> 2 then
    raise exception
      'décision: la photo ne dit pas 1 État et 1 plateforme. Migration abandonnée.';
  end if;

  -- ⚠ ET LA COMPARAISON MORD. On décale la photo d'un cran, le désaccord doit
  -- se voir, puis on remet. Sans ceci, un test qui compare deux fois la même
  -- requête à elle-même serait vert pour toujours.
  update public.sellability_decisions set states_sellable = states_sellable + 1
   where tier = 'foundation';

  select count(*) into v_n
    from public.sellability_decisions d
   where d.states_sellable
           is distinct from (select count(*) from public.sellable_states where sellable);
  if v_n <> 1 then
    raise exception
      'décision: une photo décalée ne se voit pas — le mécanisme est creux. Migration abandonnée.';
  end if;

  update public.sellability_decisions set states_sellable = states_sellable - 1
   where tier = 'foundation';

  select count(*) into v_n
    from public.sellability_decisions d
   where d.states_sellable
           is distinct from (select count(*) from public.sellable_states where sellable);
  if v_n <> 0 then
    raise exception 'décision: la sonde a laissé une photo décalée. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop table if exists public.sellability_decisions;
