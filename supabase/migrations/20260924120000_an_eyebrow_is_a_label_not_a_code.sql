-- ============================================================================
-- Eklio — un surtitre est un libellé, pas un code
-- ============================================================================
--
-- ⚠ « ONLY ONE » A ÉTÉ IMPRIMÉ SUR UNE CARTE PUBLIABLE, AU-DESSUS D'UN
-- DIAGRAMME À QUATRE BLOCS.
--
-- Une notation indépendante l'a lu comme un drapeau de pagination interne.
-- Ce n'en était pas un, et la vérité est pire : `content_intents.label` porte
-- « You are not the only one » pour `normalise`, et `eyebrowFor` en retirait
-- les mots outils — you, are, not, the — avant de garder les trois premiers
-- restants. Il restait « ONLY ONE », qui dit le CONTRAIRE de la phrase dont il
-- vient, sur la carte d'une clinicienne.
--
-- ── ⚠ LA BANDE MONO TIENT VINGT-DEUX CARACTÈRES ────────────────────────
--
-- « You are not the only one » en fait vingt-quatre, et six mots pour un
-- plafond de quatre. Le libellé ne tenait pas, et c'est le CODE qui le
-- rabotait au lieu du catalogue d'être juste.
--
-- Les cinq libellés, mesurés :
--
--   behind_the_practice  « Behind the practice »     19 car., 3 mots  ✓
--   correct_a_myth       « Myth, gently corrected »  22 car., 3 mots  ✓
--   educate              « How the work works »      18 car., 4 mots  ✓
--   invite               « A soft invitation »       17 car., 3 mots  ✓
--   normalise            « You are not the only one » 24 car., 6 mots ✗
--
-- Un seul dépasse. Il est raccourci ici, dans la table où quelqu'un l'a
-- écrit — pas dans une fonction qui le découpe à la volée.
-- ============================================================================

update public.content_intents
   set label = 'Not the only one'
 where id = 'normalise'
   and label = 'You are not the only one';

-- ── ⚠ ET AUCUN LIBELLÉ NE PEUT PLUS DÉPASSER LA BANDE ───────────────────
--
-- Sans cette contrainte, la sixième intention arrive avec une phrase et se
-- fait raboter en silence, exactement comme la cinquième. La borne est celle
-- du rendu : `EYEBROW_MAX_WORDS = 4`, `EYEBROW_MAX_CHARS = 22`.
--
-- ⚠ LES DEUX BORNES VIVENT DANS DEUX DÉPÔTS, et c'est assumé : le rendu les
-- applique, la base les garantit. Une seule des deux suffirait à refuser, mais
-- seule celle-ci empêche la donnée fautive d'exister.

alter table public.content_intents drop constraint if exists content_intents_label_fits_band;
alter table public.content_intents
  add constraint content_intents_label_fits_band
  check (
    length(btrim(label)) between 1 and 22
    and array_length(regexp_split_to_array(btrim(label), '\s+'), 1) between 1 and 4
  );

comment on constraint content_intents_label_fits_band on public.content_intents is
  'An eyebrow label has to fit the mono band as written: at most four words and twenty-two characters. "You are not the only one" fit neither, and the renderer shortened it to "ONLY ONE" -- printed above a four-block diagram on a clinician''s card, saying the opposite of the sentence it came from. A label that does not fit is refused here rather than trimmed there.';
