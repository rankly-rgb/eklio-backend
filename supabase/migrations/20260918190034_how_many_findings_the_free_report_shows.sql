-- ============================================================================
-- Combien de constats le rapport gratuit montre — PROVISOIRE, décision en attente
-- ============================================================================
-- Dix règles peuvent mordre à la fois sur un profil médiocre. Son autrice l'a
-- écrit dans l'onglet « À trancher » : « Un rapport gratuit qui rend dix
-- reproches humilie au lieu de convaincre. »
--
-- ⚠ ET LA DÉCISION N'A PAS ÉTÉ PRISE. La consigne disait « Plafond
-- d'affichage : [MON CHOIX] » — le repère est resté vide. Le nombre ci-dessous
-- est donc PROVISOIRE et il n'engage personne : 3, parce que c'est le chiffre
-- que sa propriétaire a cité en exemple dans l'onglet (« les trois costly
-- d'abord, le reste replié »), et pour aucune autre raison.
--
-- Le mettre dans le code aurait été trancher à sa place en le cachant. Il est
-- donc une DONNÉE, comme les règles :
--
--   update public.app_settings set value = to_jsonb(5)
--    where key = 'first_line_findings_shown';
--
-- ── CE QUI N'EST PAS UNE DÉCISION DE PRODUIT, ET QUE LE CODE TRANCHE ────
--
-- L'ORDRE. Les `costly` passent avant les `minor`, puis `sort_order`. Ce n'est
-- pas un arbitrage : c'est la définition même de `costly` — « ceci seul
-- explique plausiblement qu'on ne lui écrive pas ». Montrer un `minor` avant un
-- `costly` contredirait la colonne.
--
-- ⚠ ET CE QUI EST MASQUÉ EST COMPTÉ, JAMAIS PERDU. La route rend le nombre de
-- constats repliés à côté de ceux qu'elle montre. Un rapport qui tronque en
-- silence ment par omission ; un rapport qui dit « et trois autres » laisse la
-- lectrice décider si elle veut les voir.
-- ============================================================================

-- >>> FIRST LINE FINDINGS SHOWN (mirrored verbatim in supabase/seed.sql) >>>

insert into public.app_settings (key, value) values
  ('first_line_findings_shown', to_jsonb(3))
on conflict (key) do update set value = excluded.value;

-- <<< FIRST LINE FINDINGS SHOWN <<<

do $$
declare v_n int;
begin
  select (value #>> '{}')::int into v_n
    from public.app_settings where key = 'first_line_findings_shown';

  if v_n is null then
    raise exception 'plafond: le réglage n''a pas été posé. Migration abandonnée.';
  end if;
  if v_n < 1 then
    raise exception
      'plafond: % — un rapport qui ne montre aucun constat n''est pas un rapport. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET IL EST SOUS LE NOMBRE DE RÈGLES, sinon il ne plafonne rien et la
  -- décision qu'il représente n'a pas été prise, seulement déplacée.
  if v_n >= (select count(*) from public.positioning_rules where active) then
    raise exception
      'plafond: % constats affichés pour % règles actives — cela ne plafonne rien. Migration abandonnée.',
      v_n, (select count(*) from public.positioning_rules where active);
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   delete from public.app_settings where key = 'first_line_findings_shown';
