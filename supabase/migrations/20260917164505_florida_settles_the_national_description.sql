-- ============================================================================
-- La Floride tranche la description nationale, pas la Californie
-- ============================================================================
-- `DECISIONS_NEEDED` #21 : `license_types.description` vaut « Licensed
-- Psychologist », alors que la page du board californien nomme la licence
-- « Psychologist », sans le préfixe. Fallait-il suivre la Californie ?
--
--   NON. LA DESCRIPTION NATIONALE RESTE « LICENSED PSYCHOLOGIST ».
--
-- ⚠ ET C'EST LA FLORIDE QUI TRANCHE, PAS LA CALIFORNIE. §490.012(2)(b) des
-- Florida Statutes EXIGE les mots « licensed psychologist » EN TOUTES LETTRES
-- sur toute publicité. Or `description` est précisément ce qui s'imprime quand
-- `title_abbreviation()` rend NULL — c'est-à-dire en Californie, à New York, en
-- Pennsylvanie, et en Floride justement. Retirer « Licensed » pour coller à un
-- intitulé de page californien rendrait la seule chaîne que la Floride impose
-- littéralement inutilisable là-bas.
--
-- Le « Psychologist » de la page californienne est un INTITULÉ DE PAGE, pas un
-- titre réglementaire. Une psychologue licenciée en Californie est bien une
-- licensed psychologist : la description n'y est pas fausse, elle est
-- seulement plus longue que le titre de la page. L'écart est mince d'un côté
-- et interdit de l'autre — donc il n'y a pas de symétrie à arbitrer.
--
-- ⚠ CE QUI RENVERSERAIT LA DÉCISION : un État qui INTERDIRAIT « Licensed ». On
-- n'en connaît aucun. Le jour où il s'en trouve un, la formulation devient une
-- propriété du couple comme l'a été le sigle (`20260915125159`), et il faut une
-- colonne, pas un compromis sur la chaîne nationale.
-- ============================================================================

comment on column public.license_types.description is
  'The practice title in full words, true in every jurisdiction -- and what gets printed whenever title_abbreviation() returns NULL (CA, NY, PA, and FL). It stays "Licensed Psychologist" with the prefix because Florida Statutes 490.012(2)(b) REQUIRES the words "licensed psychologist" in full on all advertising; the California board page titled simply "Psychologist" is a page heading, not a regulatory title, and a licensed psychologist in California is still one. Decided 2026-09-17. Only a state that FORBIDS "Licensed" would overturn this -- and that would need a per-pair column, like the abbreviation before it, not a compromise on the national string.';

do $$
declare v_comment text;
begin
  select col_description('public.license_types'::regclass, a.attnum) into v_comment
    from pg_attribute a
   where a.attrelid = 'public.license_types'::regclass and a.attname = 'description';

  if v_comment is null or v_comment not like '%490.012%' then
    raise exception
      'floride: le commentaire de license_types.description ne cite pas la raison. Migration abandonnée.';
  end if;

  -- ⚠ ET LA CHAÎNE ELLE-MÊME N'A PAS BOUGÉ. Une décision « on garde » qui
  -- laisserait la valeur changer serait une décision sur rien.
  if (select description from public.license_types where id = 'licensed_psychologist')
       <> 'Licensed Psychologist' then
    raise exception
      'floride: la description du psychologue n''est plus « Licensed Psychologist ». Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Aucune : cette migration ne change qu'un commentaire, et le retirer
--   reperdrait la raison. C'est tout l'objet du lot.
