alter table public.plans
  add column if not exists sellable boolean not null default true;

comment on column public.plans.sellable is
  'False when this SKU cannot be delivered yet, read by the CHECKOUT PATH before any call to Stripe - not by the display, which may still show a price, and not by a CHECK on purchases, which would arrive after the money moved and would lose the record rather than refuse the sale. Three rows are false today: roster_seat, which a bought seat delivers nothing for until the arrival of a clinician triggers her pack (flipped back to true by L21); fill_solo, which sells a monthly content cycle that does not exist (L18); and fill_practice, which needs that cycle AND per-seat quantity on the subscription line (L18 and L20, both). The owning lot flips it back to true in its own migration.';

update public.plans set sellable = false
 where tier = any (array['roster_seat', 'fill_solo', 'fill_practice']);

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
