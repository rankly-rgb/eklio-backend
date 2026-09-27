/*
 * ══════════════════════════════════════════════════════════════════════════
 * DEUX TICS DE MÉTIER REJOIGNENT LES TRENTE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Relevés sur trois sorties du chemin réel le 20 septembre. Ce ne sont pas des
 * clichés de MARKETING comme les trente premiers — « you deserve », « safe
 * space » — mais des clichés de MÉTIER : des tournures que toute thérapeute de
 * couple a déjà écrites, et qui sonnent d'autant plus fabriquées qu'elles
 * paraissent fines.
 *
 *   1. L'objet ménager qui tient lieu de conflit profond — « the argument
 *      about the dishwasher that isn't about the dishwasher ».
 *   2. L'arithmétique de l'heure de séance — « one hour out of a hundred and
 *      sixty-eight ». Revenue dans les TROIS sorties.
 *
 * ⚠ ELLES VONT ICI ET PAS DANS LE PROMPT, parce qu'ici elles portent à trois
 * niveaux d'un coup : `listBannedPhrases()` les écrit dans le prompt système,
 * le pré-scan de `generateDirectoryProfile` les attrape et déclenche une
 * reprise, et le trigger `directory_profiles_ethics_gate` refuse l'écriture.
 * Une ligne de prompt n'aurait eu que le premier.
 *
 * ⚠ ET CE SONT DES LITTÉRAUX, PAS DES FORMES. `usp_banned_phrases_check`
 * échappe les métacaractères puis encadre de `\y` : la table ne sait pas dire
 * « l'objet ménager qui tient lieu de conflit, QUEL QU'IL SOIT ». Les variantes
 * — les chaussettes, le thermostat — restent donc au niveau 1, dans la
 * prohibition de FORME écrite dans `directorySystemPrompt`. C'est une limite
 * de la table, elle est dite plutôt que contournée par un motif recopié
 * ailleurs.
 *
 * ⚠ ON RETIRE, ON NE REMPLACE PAS. Aucune de ces lignes ne prescrit de
 * substitut. Interdire un cliché ET prescrire son remplacement fabriquerait le
 * gabarit qu'on cherche à éviter : chaque profil porterait le remplacement au
 * même endroit.
 *
 * ⚠ L'IDEMPOTENCE DU BLOC MIROIR TIENT À `on conflict do nothing`, et elle
 * tient à un index, pas à une contrainte : `banned_phrases_lower_phrase_key`,
 * UNIQUE sur `lower(phrase)`. `pg_constraint` ne le montre pas — seul
 * `pg_indexes` le montre — et une lecture de la seule table des contraintes
 * fait conclure à tort qu'il n'y a aucune unicité ici. Le seed rejoue après
 * les migrations ; sans cette clause, il insérerait trois doublons.
 *
 * ⚠ ET C'EST L'INDEX QU'IL FAUT VISER, PAS L'ÉGALITÉ EXACTE. Un
 * `where not exists (… b.phrase = v.phrase)` serait idempotent lui aussi, mais
 * sensible à la casse : il laisserait entrer « About The Dishwasher » à côté
 * de « about the dishwasher », que l'index refuse. La clause `on conflict`
 * parle la même langue que la contrainte réelle.
 */

-- >>> TWO CRAFT CLICHES (mirrored verbatim in supabase/seed.sql) >>>

insert into public.banned_phrases (phrase, category, active)
values
  ('about the dishwasher',      'directory_cliche', true),
  ('a hundred and sixty-eight', 'directory_cliche', true),
  ('168 hours',                 'directory_cliche', true)
on conflict do nothing;

-- <<< TWO CRAFT CLICHES <<<

do $$
declare
  v_cas record;
  v_touche boolean;
begin
  for v_cas in
    select * from (values
      ('le lave-vaisselle',       'the argument about the dishwasher that is not about the dishwasher', true),
      ('l''arithmétique, en toutes lettres', 'one hour out of a hundred and sixty-eight', true),
      ('l''arithmétique, en chiffres',       'one hour out of the 168 hours in your week', true),
      ('⚠ une vraie mention d''horaire',     'I see clients on Tuesdays and Thursdays.', false),
      ('⚠ une vraie durée de séance',        'Sessions run fifty minutes.', false),
      ('⚠ un conflit domestique nommé autrement', 'You have the same argument every Sunday evening.', false)
    ) as t(quoi, texte, attendu)
  loop
    v_touche := coalesce(array_length(public.usp_banned_phrases_check(v_cas.texte), 1), 0) > 0;
    if v_touche is distinct from v_cas.attendu then
      raise exception 'clichés de métier, cas « % » : attendu %, obtenu %',
        v_cas.quoi, v_cas.attendu, v_touche;
    end if;
  end loop;

  /*
   * ⚠ ET LES TRENTE PREMIERS N'ONT PAS BOUGÉ. Un `insert` qui se serait
   * transformé en remplacement serait passé inaperçu : on compte. Cette garde
   * est aussi celle qui attrape un doublon inséré par un rejeu du seed.
   */
  if (select count(*) from public.banned_phrases where active) <> 33 then
    raise exception 'la liste active compte % phrases, 33 attendues',
      (select count(*) from public.banned_phrases where active);
  end if;
  if not exists (select 1 from public.banned_phrases where phrase = 'you deserve' and active) then
    raise exception 'un cliché existant a disparu';
  end if;
end $$;
