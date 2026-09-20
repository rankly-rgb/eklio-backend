/*
 * ══════════════════════════════════════════════════════════════════════════
 * UN TÉMOIGNAGE ANONYMISÉ RESTE UN TÉMOIGNAGE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Relevé sur trois sorties du chemin réel le 20 septembre : DEUX sur trois
 * portaient la même phrase.
 *
 *     « A colleague once described me as direct but not judgmental. »
 *
 * L'Ethics Guard l'a laissée passer parce que le locuteur n'est pas un client.
 * Mais la phrase affirme un ÉVÉNEMENT qui n'a pas eu lieu et prête un jugement
 * professionnel à un tiers qui n'existe pas. Ni l'un ni l'autre ne se vérifie,
 * et le second engage la réputation de quelqu'un d'autre.
 *
 * ⚠ ET CE N'EST PAS UNE LIGNE DE PROMPT. `ETHICS_SYSTEM_RULES` porte déjà sa
 * règle 3 — « never paraphrase one » — et elle n'a rien arrêté. Le pilotage de
 * modèle est le niveau 1 ; il ne suffit jamais. Ceci est le niveau 2, du même
 * genre que `clients_say` : une parole ATTRIBUÉE à un tiers non nommé.
 *
 * ── CE QUI SE DÉCLENCHE ET CE QUI SE TAIT, 27 CAS, DEUX MOTEURS, 0 ÉCART ──
 *
 *   « A colleague once described me as direct but not judgmental. »   BLOQUE
 *   « A former supervisor said I have a knack for this work. »        BLOQUE
 *   « Colleagues have described my style as direct. »                 BLOQUE
 *   « I am supervised by Dana Ruiz, LPC-S. »                          passe
 *   « I practice under the supervision of Dana Ruiz, LPC-S. »         passe
 *   « I trained under a colleague who specialises in EMDR. »          passe
 *   « I take referrals from colleagues across the county. »           passe
 *
 * ⚠ LES DEUX QUI PASSENT EN PREMIER SONT LES PLUS IMPORTANTES. Une associée
 * texane est TENUE d'écrire la mention de supervision — 22 TAC 681.91(m) — et
 * une garde qui la bloquerait reprocherait à quelqu'un d'obéir à la loi. Ce
 * qu'on attrape est une PAROLE attribuée, jamais la mention d'un tiers.
 *
 * ⚠ LA LISTE DE NOMS EST FERMÉE, comme celle de `clients_say` et pour la même
 * raison : un `\w+` générique bloquerait « families describe », qui nomme une
 * population.
 *
 * ⚠ LE DÉTERMINANT EST FACULTATIF, ET CE DESSERRAGE A UN COÛT MESURÉ. Sans
 * lui, « Colleagues have described my style as direct » — la même affirmation
 * au pluriel nu — passait. Avec lui, deux phrases où le nom précède un verbe
 * de parole dans un autre rôle grammatical se déclenchent aussi (« Teachers
 * call the school when something is wrong »). Le choix est asymétrique et
 * assumé : un faux positif coûte une réécriture, un faux négatif PUBLIE un
 * témoignage inventé.
 *
 * ── ET LE LIBELLÉ DE LA RÈGLE CHANGE, PARCE QU'IL MENTIRAIT SINON ────────
 *
 * Le motif s'attache à `client_voice` : le mécanisme est celui du témoignage,
 * seul le locuteur change. Mais « No client voice » ne décrit alors plus ce que
 * la règle bloque, et ce dépôt interdit que l'infobulle du badge BOARD-SAFE
 * COPY et le chemin d'application divergent (§7). Le libellé et la description
 * sont donc élargis — une ligne de données, pas une septième règle : une
 * septième rippler sur l'union `EthicsRuleId`, les deux listes de parité et le
 * badge, pour une distinction que la lectrice n'a pas besoin de lire.
 *
 * `example_forbidden` ne bouge PAS : « Clients often tell me... » reste le cas
 * canonique, et il est épinglé dans un fichier de test de chaque dépôt.
 *
 * ⚠ `sort_order` 20, EN APPEND. Renuméroter les dix-neuf autres pour glisser
 * celui-ci à côté de son frère `clients_say` changerait dix-neuf lignes pour
 * un ordre que personne ne lit.
 */

-- >>> THIRD PARTY SAYS (mirrored verbatim in supabase/seed.sql) >>>

insert into public.ethics_patterns (id, rule_id, pattern, severity, sort_order, active)
values (
  'third_party_says',
  'client_voice',
  '\y((a|an|one|my|our|her|his|their|another|the) +)?(former +|current +|past +|longtime +|long-time +)?(colleagues?|supervisors?|mentors?|peers?|co-?workers?|professors?|instructors?|teachers?) +((have|has|had) +)?(once|often|always|recently|sometimes|frequently|usually|more +than +once)? *(said|says|say|told|tells|tell|described|describes|describe|called|calls|call|remarked|observed|joked|puts? +it)\y',
  'block',
  20,
  true
)
on conflict (id) do update set
  rule_id    = excluded.rule_id,
  pattern    = excluded.pattern,
  severity   = excluded.severity,
  sort_order = excluded.sort_order,
  active     = excluded.active;

update public.ethics_rules
   set short_label = 'No borrowed voices',
       description = 'No quotes, paraphrases or reported praise attributed to anyone else — a client, a colleague, a supervisor or a mentor. "Clients often say", and equally "a colleague once described me as".'
 where id = 'client_voice';

-- <<< THIRD PARTY SAYS <<<

/*
 * ── LA GARDE, ET ELLE SE SABOTE ELLE-MÊME ───────────────────────────────
 *
 * Elle rejoue les cas contre `ethics_blocks()`, donc contre la ligne
 * RÉELLEMENT écrite et par le chemin que le trigger emprunte — pas contre la
 * chaîne ci-dessus.
 */
do $$
declare
  v_cas record;
  v_bloque boolean;
begin
  for v_cas in
    select * from (values
      ('la phrase relevée',          'A colleague once described me as direct but not judgmental.', true),
      ('un ancien superviseur',      'A former supervisor said I have a knack for this work.', true),
      ('le pluriel nu',              'Colleagues have described my style as direct.', true),
      ('un mentor',                  'A mentor put it better than I can.', true),
      ('⚠ 22 TAC 681.91(m)',         'I am supervised by Dana Ruiz, LPC-S.', false),
      ('⚠ la même, autrement',       'I practice under the supervision of Dana Ruiz, LPC-S.', false),
      ('⚠ une superviseuse',         'I provide clinical supervision to associates.', false),
      ('un tiers sans parole',       'I trained under a colleague who specialises in EMDR.', false),
      ('les renvois confraternels',  'I take referrals from colleagues across the county.', false),
      ('la voix de la praticienne',  'I tell clients what I think, even when it is awkward.', false)
    ) as t(quoi, texte, attendu)
  loop
    v_bloque := public.ethics_blocks(v_cas.texte) is not null;
    if v_bloque is distinct from v_cas.attendu then
      raise exception 'third_party_says, cas « % » : attendu %, obtenu % — %',
        v_cas.quoi, v_cas.attendu, v_bloque, coalesce(public.ethics_blocks(v_cas.texte), '(rien)');
    end if;
  end loop;

  -- ⚠ Le libellé doit décrire ce que la règle bloque VRAIMENT.
  if exists (
    select 1 from public.ethics_rules
     where id = 'client_voice' and short_label = 'No client voice'
  ) then
    raise exception 'le libellé de client_voice ne couvre plus ce que la règle bloque';
  end if;

  -- ⚠ Et l'exemple canonique reste bloqué : élargir n'est pas remplacer.
  if public.ethics_blocks('Clients often tell me...') is null then
    raise exception 'l''exemple montré à la praticienne n''est plus bloqué';
  end if;
end $$;
