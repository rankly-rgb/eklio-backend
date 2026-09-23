-- ============================================================================
-- Eklio — la banque ne détient jamais les lignes d'une praticienne
-- ============================================================================
--
-- ⚠ MESURÉ, PAS SUPPOSÉ : 36 APPELS PAYÉS SUR 260 ONT ÉTÉ JETÉS.
--
-- Le 2026-09-23, un remplissage de banque a écrit 224 sujets pour 260 appels.
-- Les 36 manquants étaient TOUS des `practitioner_card`, et tous refusés sur
-- « schema: a required field is missing ». Pas un ne l'a dit à l'écran : le
-- script comptait ses échecs pour la fin, et la fin n'est jamais venue.
--
-- La cause est une moitié de correction. Depuis l'interdiction d'inventer une
-- identité, on ne demande plus au modèle le CONTENU d'une carte praticienne :
-- ses lignes viennent du brief à la composition — modalité, ville,
-- disponibilité — et de nulle part ailleurs. Mais la contrainte de la banque,
-- elle, exigeait toujours un `lines` de deux à quatre phrases. On a donc
-- continué à PAYER pour des lignes qu'on refusait ensuite d'écrire.
--
-- ── LE DÉFAUT N'EST PAS SEULEMENT COMPTABLE ─────────────────────────────
--
-- Les 39 lignes déjà en banque portent des phrases écrites par un modèle pour
-- une praticienne qui n'existe pas — c'est exactement la matière dont
-- « Rowan Mercier Therapy » était faite. Elles ne sont plus lues par personne
-- depuis que la composition prend le brief, mais elles sont LÀ, et une banque
-- qui détient des lignes de praticienne est une banque d'où une identité peut
-- ressortir.
--
-- On ne les répare pas, on les vide : `{}`, et la contrainte exige désormais
-- `{}`.
--
-- ⚠ LA CONTRAINTE DE `content_items` NE BOUGE PAS. Une carte PUBLIÉE doit
-- toujours porter ses deux à quatre lignes : sinon on imprime une carte vide.
-- Ce qui change est la seule banque, d'où le validateur séparé — les deux
-- tables partageaient une fonction et n'ont pas la même exigence.
-- ============================================================================

create or replace function public.content_topic_bank_payload_valid(p_archetype text, p jsonb)
returns boolean
language sql
stable
set search_path to ''
as $$
  select case
    when p_archetype is null or p is null then false
    when jsonb_typeof(p) <> 'object' then false
    -- ⚠ LE SUJET D'UNE CARTE PRATICIENNE N'A PAS DE CORPS. Son titre et son
    -- accroche restent du modèle : « Where to start », « How I work » ne
    -- nomment personne. Ses lignes, elles, viennent du brief à la composition.
    when p_archetype = 'practitioner_card' then p = '{}'::jsonb
    else public.content_topic_payload_valid(p_archetype, p)
  end;
$$;

comment on function public.content_topic_bank_payload_valid(text, jsonb) is
  'Bank-side payload validation. Identical to content_topic_payload_valid except for practitioner_card, whose bank payload must be empty: a practitioner card''s lines come from her own brief at composition time, never from a model, so the bank has nothing to hold. content_items keeps the strict rule -- a published card still needs its lines.';

-- ⚠ DÉTACHER, VIDER, PUIS RECONTRAINDRE — ET DANS CET ORDRE. L'ancienne
-- contrainte exige `lines` : un `update` qui met `{}` alors qu'elle est encore
-- posée est refusé par la contrainte qu'on est en train de remplacer. Mesuré
-- au premier rejeu de cette migration, sur la ligne « The Cost of Looking
-- Composed ».
alter table public.content_topics drop constraint if exists content_topics_payload_check;

-- Rien n'est perdu : ces lignes ne sont plus lues depuis que la composition
-- prend le brief.
update public.content_topics
   set payload = '{}'::jsonb
 where archetype_key = 'practitioner_card'
   and payload <> '{}'::jsonb;

alter table public.content_topics
  add constraint content_topics_payload_check
  check (public.content_topic_bank_payload_valid(archetype_key, payload));
