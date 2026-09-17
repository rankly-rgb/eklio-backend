alter table public.plans
  add column if not exists requires_publishable_platform boolean not null default false;

comment on column public.plans.requires_publishable_platform is
  'True when this SKU promises that Eklio PUBLISHES pages on her own site, which we can only do where site_platforms.status is accepted. Read by the CHECKOUT PATH beside plans.sellable - the same single door, the second reason it can close. This is eligibility, NOT refusal: someone on an unreachable platform is still sold the previous offer, which promises files and copy to paste and never promised publication. False on every legacy tier for that reason, and on identity_addon, which delivers files.';

update public.plans set requires_publishable_platform = true
 where tier = any (array['foundation', 'roster', 'fill_solo', 'fill_practice']);

do $$
declare
  v_gated int;
  v_free  int;
  v_wp    text;
begin
  select count(*) into v_gated from public.plans where requires_publishable_platform;
  if v_gated <> 4 then
    raise exception
      'eligibility: % SKU conditionnés à la plateforme au lieu de 4.', v_gated;
  end if;

  select count(*) into v_free
    from public.plans
   where tier = any (array['starter', 'practice', 'signature', 'free', 'identity_addon'])
     and requires_publishable_platform;
  if v_free <> 0 then
    raise exception
      'eligibility: % ligne(s) de l''ancienne offre conditionnée(s) à la plateforme.', v_free;
  end if;

  select string_agg(id, ', ') into v_wp
    from public.site_platforms where status = 'accepted';
  if v_wp is null then
    raise exception 'eligibility: aucune plateforme acceptée dans site_platforms.';
  end if;
  raise notice 'eligibility: plateformes acceptées = %', v_wp;
end $$;
