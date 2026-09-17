-- ============================================================================
-- Ce qu'on ne sait pas livrer ne doit pas pouvoir être encaissé
-- ============================================================================
-- `DECISIONS_NEEDED.md` §4 et §7, écrits au lot 1, disent la même chose deux
-- fois et se terminent tous les deux par une phrase qui ne tient pas :
--
--   §4  « ⚠ Un siège se vend et ne livre rien. Il ne faut pas le mettre en
--        vente avant L21. RIEN DANS LE CODE NE L'EMPÊCHE AUJOURD'HUI — c'est
--        une décision de mise en vente, pas une garde technique. »
--   §7  « ⚠ Créer ces deux prix chez Stripe est préparatoire. RIEN NE DOIT
--        ÊTRE MIS EN VENTE AVEC EUX AVANT L20. »
--
-- « Il ne faut pas » et « rien ne doit » sont des consignes. Une consigne
-- survit tant que la personne qui l'a écrite est encore là pour la rappeler.
-- Trois lignes de catalogue existent, portent un prix, et sont invisibles dans
-- le code à l'endroit où l'argent bouge. Ce fichier remplace les trois
-- consignes par une colonne.
--
-- ── LES TROIS, ET CE QUI LEUR MANQUE ────────────────────────────────────────
--
--   roster_seat    120 $/clinicienne. `directions_limit` est NULL, donc
--                  `consume_generation_credit` échoue fermé : un siège acheté
--                  ne produit rien. Ce qu'une clinicienne de plus reçoit est
--                  déclenché par son arrivée dans le cabinet, et ce
--                  déclenchement n'est pas écrit.       → repassé à true par L21
--
--   fill_solo      59 $/mois. Ce qui est vendu est un cycle mensuel de contenu
--                  qui n'existe pas encore.             → repassé à true par L18
--
--   fill_practice  69 $/clinicienne/mois. Le cycle, ET la multiplication : la
--                  quantité de la ligne d'abonnement ne s'écrit nulle part
--                  dans ce dépôt (`subscriptions` n'a ni `quantity` ni
--                  `organization_id`).                  → repassé à true par
--                                                          L18 ET L20, les deux
--
-- ── ⚠ POURQUOI CE N'EST PAS UN CHECK SUR `purchases` ────────────────────────
--
-- La garde évidente serait d'interdire en base une ligne de `purchases` dont
-- le `tier` n'est pas vendable. Elle est ÉCARTÉE, et pour la raison que
-- `lib/stripe/checkout.ts` a déjà écrite à propos du double paiement :
--
--   « the money is taken and the row is lost: strictly worse, because there is
--     no refund primitive anywhere in this product. »
--
-- `purchases` est écrite par le webhook, APRÈS que l'argent a bougé. Un CHECK
-- à cet endroit ne refuserait pas la vente : il refuserait la TRACE de la
-- vente. On encaisserait 120 $ et on n'aurait plus rien qui dise pour quoi.
--
-- Une garde ne vaut qu'à un endroit : AVANT le paiement. Cette colonne est
-- donc une donnée que le CHEMIN DE CHECKOUT lit — pas l'affichage, qui peut
-- toujours montrer un prix, et pas la base, qui arrive trop tard.
-- ============================================================================

alter table public.plans
  add column if not exists sellable boolean not null default true;

comment on column public.plans.sellable is
  'False when this SKU cannot be delivered yet, read by the CHECKOUT PATH before any call to Stripe - not by the display, which may still show a price, and not by a CHECK on purchases, which would arrive after the money moved and would lose the record rather than refuse the sale. Three rows are false today: roster_seat, which a bought seat delivers nothing for until the arrival of a clinician triggers her pack (flipped back to true by L21); fill_solo, which sells a monthly content cycle that does not exist (L18); and fill_practice, which needs that cycle AND per-seat quantity on the subscription line (L18 and L20, both). The owning lot flips it back to true in its own migration.';

-- >>> SELLABILITY DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ NOMMÉES UNE PAR UNE, PAS `where kind <> 'kit'`. Une règle par nature
-- ferait d'une future ligne de catalogue une chose invendable par accident, et
-- l'inverse : `identity_addon` n'est pas un kit et SE VEND — il livre l'add-on
-- identité à 89 $, qui existe et fonctionne. Ce ne sont pas les catégories qui
-- sont invendables, ce sont ces trois lignes-là, chacune pour sa raison.
update public.plans set sellable = false
 where tier = any (array['roster_seat', 'fill_solo', 'fill_practice']);

-- <<< SELLABILITY DATA <<<

-- ── L'auto-contrôle ─────────────────────────────────────────────────────────
--
-- ⚠ La migration vérifie SON PROPRE effet, dans la même transaction. Le
-- `update` ci-dessus ne touche aucune ligne si un `tier` a été renommé entre
-- temps, et un UPDATE qui ne touche rien ne lève pas : c'est exactement la
-- famille de défaut que ce dépôt appelle « une valeur qui disparaît sans
-- erreur ».
do $$
declare
  v_blocked int;
  v_open    int;
begin
  select count(*) into v_blocked
    from public.plans
   where tier = any (array['roster_seat', 'fill_solo', 'fill_practice'])
     and not sellable;

  if v_blocked <> 3 then
    raise exception
      'sellability: % of the 3 undeliverable SKUs are blocked. A renamed tier would leave a priced row on sale.',
      v_blocked;
  end if;

  select count(*) into v_open from public.plans where sellable;
  if v_open < 1 then
    raise exception 'sellability: nothing is sellable any more. That is not the change this migration makes.';
  end if;
end $$;
