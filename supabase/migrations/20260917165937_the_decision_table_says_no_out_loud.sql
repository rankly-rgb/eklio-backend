-- ============================================================================
-- La table des décisions dit « non » à voix haute
-- ============================================================================
-- `20260917164434` a posé `sellability_decisions` avec RLS activée et AUCUNE
-- politique. L'effet voulu est bon — aucun navigateur ne lit pourquoi un
-- palier est fermé — mais `20260911180620_tenancy_layer.test.sql` l'a refusé,
-- et son message dit exactement pourquoi :
--
--   « L'effet (tout refuser au navigateur) est peut-être juste, mais il se lit
--     exactement comme une politique oubliée. Écris-le : for all using (false)
--     with check (false). »
--
-- ⚠ C'EST LA MÊME RÈGLE QUE TOUT LE RESTE DE CE DÉPÔT, APPLIQUÉE À MOI. Un
-- refus qui tient à une ABSENCE est indistinguable d'un oubli : le prochain
-- qui lit la table voit « RLS on, zéro politique » et ne peut pas savoir si
-- quelqu'un a décidé ça ou si quelqu'un n'a pas fini. La différence entre une
-- décision et un oubli n'est pas dans l'effet, elle est dans ce qui est écrit.
--
-- Donc on l'écrit. Le comportement ne change pas d'un bit — `using (false)`
-- refuse ce que zéro politique refusait déjà. Ce qui change, c'est qu'on peut
-- désormais le LIRE.
--
-- ⚠ ET LA SONDE A TROUVÉ AUTRE CHOSE, qu'il faut écrire aussi : le premier jet
-- de ce fichier interrogeait la table en `set role authenticated` et attendait
-- ZÉRO ligne. Il a reçu `42501 permission denied` — parce que `20260917164434`
-- avait aussi RÉVOQUÉ le GRANT. Le refus arrive donc UN CRAN PLUS TÔT que la
-- RLS, au privilège. Les deux verrous sont voulus et ils ne font pas double
-- emploi : le GRANT protège tant que personne ne le rouvre, la politique
-- protège le jour où quelqu'un le rouvre. La sonde ci-dessous accepte les deux
-- formes de refus et REFUSE de passer si aucune n'arrive.
-- ============================================================================

drop policy if exists sellability_decisions_no_browser on public.sellability_decisions;

create policy sellability_decisions_no_browser
  on public.sellability_decisions
  for all
  using (false)
  with check (false);

comment on policy sellability_decisions_no_browser on public.sellability_decisions is
  'Deny everything, written out. Why a plan is open or closed is an operational decision about the PRODUCT, not a row any browser session has business reading -- and service_role bypasses RLS, so the test that reads this table is unaffected. Spelled out rather than left to an absent policy: RLS with no policy at all reads identically to one somebody forgot. The SELECT grant is revoked as well, so a browser role is refused one step earlier still; the two are not redundant -- the grant holds until someone reopens it, the policy holds after they do.';

do $$
declare v_n int; v_refuse boolean := false;
begin
  -- La politique existe, elle couvre tout, et elle refuse.
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'sellability_decisions'
     and cmd = 'ALL' and qual = 'false' and with_check = 'false';
  if v_n <> 1 then
    raise exception
      'politique: % politique(s) « refuse tout » sur sellability_decisions, attendu 1. Migration abandonnée.', v_n;
  end if;

  -- ⚠ ET ELLE REFUSE VRAIMENT. On se met dans la peau d'une session de
  -- navigateur et on regarde. Deux refus acceptables : zéro ligne (la
  -- politique), ou 42501 (le grant révoqué, qui mord plus tôt).
  begin
    set local role authenticated;
    select count(*) into v_n from public.sellability_decisions;
    v_refuse := (v_n = 0);
  exception when insufficient_privilege then
    v_refuse := true;
  end;
  reset role;

  if not v_refuse then
    raise exception
      'politique: une session authentifiée lit les décisions de vendabilité. Migration abandonnée.';
  end if;

  -- Et le rôle qui a posé cette migration, lui, voit les deux décisions :
  -- refuser à tout le monde aurait aussi rendu le test aveugle.
  select count(*) into v_n from public.sellability_decisions;
  if v_n <> 2 then
    raise exception
      'politique: le rôle privilégié ne voit que % décision(s), attendu 2. Migration abandonnée.', v_n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop policy if exists sellability_decisions_no_browser on public.sellability_decisions;
