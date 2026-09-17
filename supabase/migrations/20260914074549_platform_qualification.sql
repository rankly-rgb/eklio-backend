-- ============================================================================
-- La qualification de plateforme
-- ============================================================================
-- L'offre promet des pages « publiées par Eklio sur son CMS ». On ne peut donc
-- vendre The Foundation qu'à quelqu'un dont le site tourne sur une plateforme
-- qu'on saura atteindre. Les autres sont refusées à l'inscription, avec une
-- phrase qui dit pourquoi.
--
-- ⚠ LA LISTE ACCEPTÉE EST UNE DONNÉE, PAS UNE CONSTANTE DE CODE, et ce n'est
-- pas du confort. La question « Squarespace expose-t-il une API de création de
-- pages » n'est PAS TRANCHÉE (GAP_PLAN.md, première page). Elle le sera par une
-- demi-journée de lecture de documentation, et ce jour-là la réponse doit
-- coûter un UPDATE — pas un déploiement de code, pas une revue, pas une
-- fenêtre de livraison. D'où `site_platforms.status`, qui porte trois états et
-- pas deux.
--
-- ── TROIS ÉTATS, ET LE TROISIÈME EST LE POINT ───────────────────────────────
--
--   accepted     on sait publier dessus. WordPress.
--   conditional  on ne sait pas encore. Squarespace, en attendant la réponse.
--   refused      on ne publiera pas dessus.
--
-- Deux états auraient forcé à ranger Squarespace du côté d'une réponse qu'on
-- n'a pas. `conditional` dit la vérité : on prend l'inscription, et on dit ce
-- qui n'est pas garanti. C'est une phrase honnête à écrire ; « accepté » puis
-- un remboursement six semaines plus tard ne l'est pas.
-- ============================================================================

create table if not exists public.site_platforms (
  id            text        not null,
  label         text        not null,
  status        text        not null,
  -- ⚠ La phrase que la visiteuse LIT quand sa plateforme n'est pas prise. Elle
  -- vit ici pour la même raison que la liste : changer d'avis sur Squarespace
  -- change aussi ce qu'on lui dit, et les deux doivent bouger ensemble.
  notice        text,
  sort_order    smallint    not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint site_platforms_pkey primary key (id),
  constraint site_platforms_id_check    check (id ~ '^[a-z][a-z0-9_]{1,30}$'),
  constraint site_platforms_label_check check (btrim(label) <> ''),
  constraint site_platforms_status_check
    check (status = any (array['accepted', 'conditional', 'refused'])),
  -- ⚠ `is null or`, PAS `btrim(notice) <> ''` SEUL. Sur une colonne nulle, ce
  -- dernier rend NULL et un CHECK ACCEPTE NULL : la contrainte laisserait
  -- passer la chaîne vide qu'elle prétend refuser, du moment qu'on la met à
  -- NULL d'abord. Premier des quatre défauts permissifs du README.
  constraint site_platforms_notice_check
    check (notice is null or btrim(notice) <> ''),
  -- Ce qui n'est pas accepté DOIT dire pourquoi. Une plateforme refusée sans
  -- phrase donne un écran qui refuse sans expliquer.
  constraint site_platforms_notice_where_needed
    check (status = 'accepted' or notice is not null)
);

comment on table public.site_platforms is
  'Which website platforms Eklio will publish to. DATA, not a code constant: whether Squarespace exposes a page-creation API is not settled, and the answer must cost an UPDATE rather than a deployment.';
comment on column public.site_platforms.status is
  'accepted: publishing is known to work. conditional: not yet known - the signup is taken and the uncertainty is stated. refused: publishing will not happen here. Three states rather than two, because filing an unanswered question under "accepted" is how a refund happens six weeks later.';
comment on column public.site_platforms.notice is
  'The sentence the visitor READS when her platform is not plainly accepted. Lives beside the status because changing one changes the other.';

alter table public.site_platforms enable row level security;

drop policy if exists site_platforms_select_all on public.site_platforms;
-- Catalogue de référence : lisible par tout le monde, y compris une visiteuse
-- anonyme, parce que la qualification a lieu AVANT le compte.
create policy site_platforms_select_all on public.site_platforms
  for select to anon, authenticated using (true);
drop policy if exists site_platforms_insert_denied on public.site_platforms;
create policy site_platforms_insert_denied on public.site_platforms for insert with check (false);
drop policy if exists site_platforms_update_denied on public.site_platforms;
create policy site_platforms_update_denied on public.site_platforms for update using (false);
drop policy if exists site_platforms_delete_denied on public.site_platforms;
create policy site_platforms_delete_denied on public.site_platforms for delete using (false);

grant select on public.site_platforms to anon, authenticated;

drop trigger if exists set_site_platforms_updated_at on public.site_platforms;
create trigger set_site_platforms_updated_at
  before update on public.site_platforms
  for each row execute function public.set_updated_at();

-- >>> SITE PLATFORM DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ CES TROIS STATUTS SONT LA DÉCISION, et `squarespace` est celui qui bougera.
-- Le jour où la question est tranchée, c'est UN UPDATE sur une ligne.
insert into public.site_platforms (id, label, status, notice, sort_order) values
  ('wordpress', 'WordPress', 'accepted', null, 1),

  ('squarespace', 'Squarespace', 'conditional',
   'We are still confirming what we can publish to Squarespace on your behalf. You can sign up, and we will tell you before you pay if anything has to be done by hand.',
   2),

  -- Les plateformes qu'on rencontre et qu'on ne sait pas atteindre. Nommées
  -- une par une plutôt que repliées sur « autre » : une visiteuse dont la
  -- plateforme est nommée comprend qu'on l'a envisagée.
  ('wix', 'Wix', 'refused',
   'We do not publish to Wix yet. Everything we write for you would still be yours to paste, but putting it in place is the part we could not do.',
   3),
  ('webflow', 'Webflow', 'refused',
   'We do not publish to Webflow yet. Everything we write for you would still be yours to paste, but putting it in place is the part we could not do.',
   4),
  ('other', 'Something else', 'refused',
   'We only publish to WordPress today. Everything we write for you would still be yours to paste, but putting it in place is the part we could not do.',
   5),
  ('none', 'I do not have a website yet', 'refused',
   'You will need a site before we can put anything on it. WordPress is the one we publish to today.',
   6)
on conflict (id) do update set
  label      = excluded.label,
  status     = excluded.status,
  notice     = excluded.notice,
  sort_order = excluded.sort_order;

-- <<< SITE PLATFORM DATA <<<

-- ── Ce que la praticienne a répondu ─────────────────────────────────────────

alter table public.project_briefs
  add column if not exists site_platform_id text,
  add column if not exists site_url         text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'project_briefs_site_platform_id_fkey') then
    alter table public.project_briefs add constraint project_briefs_site_platform_id_fkey
      foreign key (site_platform_id) references public.site_platforms (id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'project_briefs_site_url_check') then
    -- ⚠ `is null or`, encore, et une borne de longueur. On ne valide PAS la
    -- forme d'une URL en SQL au-delà du schéma : une expression régulière
    -- d'URL est un nid à faux négatifs, et refuser l'adresse réelle de
    -- quelqu'un coûte plus cher qu'accepter une faute de frappe qu'elle verra.
    alter table public.project_briefs add constraint project_briefs_site_url_check
      check (site_url is null
             or (site_url ~* '^https?://[^[:space:]]+$' and length(site_url) <= 500));
  end if;
end $$;

comment on column public.project_briefs.site_platform_id is
  'Which platform her site runs on, from site_platforms. NULL until she has been asked - existing briefs predate the question and are not retroactively unqualified.';
comment on column public.project_briefs.site_url is
  'Her site, as she typed it. Only the scheme and the absence of whitespace are checked: a stricter URL pattern refuses real addresses more often than it catches typos, and she can see a typo herself.';

-- ── Un refus se compte ──────────────────────────────────────────────────────
--
-- ⚠ POURQUOI UNE TABLE ET PAS `funnel_events`. Celle-ci est purgée à 180 jours
-- et n'est lisible que par `service_role` (GAP_AUDIT.md §I). La question à
-- laquelle ces lignes répondent — « combien de clientes refusons-nous, et pour
-- quelle plateforme » — est celle qui décide s'il faut écrire un client
-- Squarespace. Elle se pose sur des trimestres, pas sur des semaines, et une
-- réponse qui s'efface toute seule ne décide rien.

create table if not exists public.platform_refusals (
  id          bigint generated always as identity primary key,
  platform_id text        not null references public.site_platforms (id),
  -- Nullable : le refus arrive souvent AVANT qu'un projet existe.
  project_id  uuid        references public.projects (id) on delete set null,
  occurred_at timestamptz not null default clock_timestamp()
);

create index if not exists platform_refusals_platform_idx
  on public.platform_refusals (platform_id, occurred_at desc);

comment on table public.platform_refusals is
  'One row per visitor turned away because of her platform. NOT funnel_events: that table is purged at 180 days and unreadable by anyone but service_role, and the question these rows answer - how many customers are we turning away, and for which platform - is the one that decides whether to write a Squarespace client. It is asked over quarters.';

alter table public.platform_refusals enable row level security;

-- ⚠ AUCUNE POLICY PERMISSIVE. La RLS est activée et rien n'ouvre : personne ne
-- lit ni n'écrit cette table depuis un navigateur. L'écriture passe par la
-- RPC ci-dessous, la lecture est un compte agrégé.
drop policy if exists platform_refusals_denied on public.platform_refusals;
create policy platform_refusals_denied on public.platform_refusals
  for all using (false) with check (false);

create or replace function public.record_platform_refusal(
  p_platform_id text,
  p_project_id  uuid default null
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_status text;
begin
  -- ⚠ LA GARDE D'AUTORITÉ, DANS LE CORPS. Cette fonction est appelable par
  -- `anon`, et elle doit l'être : la visiteuse qu'on refuse est précisément
  -- celle qui n'a pas encore de compte. Ce qui n'est pas permis, c'est
  -- d'AGRAFER un refus au projet de quelqu'un d'autre — sans cette ligne,
  -- n'importe qui pouvait écrire une ligne qui dit « cette cliente-là a été
  -- refusée » sur le projet d'une autre.
  --
  -- `owns_project` porte les deux branches, utilisatrice et jeton anonyme, donc
  -- une visiteuse anonyme peut rattacher le refus à SON brief et à aucun autre.
  -- Un `p_project_id` nul reste permis : c'est le cas le plus fréquent, et une
  -- ligne sans projet ne prétend rien sur personne.
  --
  -- `20260911170458_function_surface.test.sql` a rougi avant que cette ligne
  -- existe : « A REVOKE is a fact about a moment; a check in the body is a fact
  -- about the function. »
  if p_project_id is not null and not public.owns_project(p_project_id) then
    return false;
  end if;

  select sp.status into v_status
    from public.site_platforms sp
   where sp.id = p_platform_id;

  -- ⚠ ON N'ENREGISTRE QUE DE VRAIS REFUS. Une plateforme inconnue, ou une
  -- plateforme acceptée, ne compte pas : sans ça le compteur qui doit décider
  -- s'il faut écrire un client Squarespace compterait aussi les gens à qui on
  -- n'a rien refusé, et il dirait n'importe quoi dans le sens qui pousse à
  -- construire.
  if v_status is distinct from 'refused' then
    return false;
  end if;

  insert into public.platform_refusals (platform_id, project_id)
  values (p_platform_id, p_project_id);
  return true;
end
$$;

revoke all on function public.record_platform_refusal(text, uuid) from public;
-- Une visiteuse anonyme est précisément celle qu'on refuse : elle n'a pas
-- encore de compte. `anon` doit pouvoir déclencher l'enregistrement.
grant execute on function public.record_platform_refusal(text, uuid) to anon, authenticated, service_role;

create or replace function public.platform_refusal_counts(p_since timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(jsonb_object_agg(platform_id, n), '{}'::jsonb)
    from (
      select r.platform_id, count(*) as n
        from public.platform_refusals r
       where p_since is null or r.occurred_at >= p_since
       group by r.platform_id
    ) counted
$$;

comment on function public.platform_refusal_counts(timestamptz) is
  'How many visitors each platform has cost us. The number that decides whether writing a client for it is worth it.';

revoke all on function public.platform_refusal_counts(timestamptz) from public, anon, authenticated;
grant execute on function public.platform_refusal_counts(timestamptz) to service_role;

-- ── Auto-contrôle ──────────────────────────────────────────────────────────

do $$
declare
  v_n      bigint;
  v_before bigint;
begin
  -- Le catalogue dit ce que la décision dit.
  if (select status from public.site_platforms where id = 'wordpress') <> 'accepted' then
    raise exception 'WordPress n''est pas accepté';
  end if;
  if (select status from public.site_platforms where id = 'squarespace') <> 'conditional' then
    raise exception 'Squarespace n''est pas en conditionnel — la question n''est pas tranchée';
  end if;
  if exists (select 1 from public.site_platforms
              where status <> 'accepted' and notice is null) then
    raise exception 'une plateforme non acceptée ne dit pas pourquoi';
  end if;

  -- ⚠ LE COMPTEUR EST PARCOURU, PAS RELU. Trois appels, trois résultats
  -- différents attendus, et le compte est comparé avant/après.
  select count(*) into v_before from public.platform_refusals;

  if public.record_platform_refusal('wordpress') then
    raise exception 'une plateforme acceptée a été comptée comme un refus';
  end if;
  if public.record_platform_refusal('squarespace') then
    raise exception 'une plateforme en conditionnel a été comptée comme un refus';
  end if;
  if public.record_platform_refusal('pas_une_plateforme') then
    raise exception 'une plateforme inconnue a été comptée comme un refus';
  end if;
  if not public.record_platform_refusal('wix') then
    raise exception 'un vrai refus n''a pas été enregistré';
  end if;

  select count(*) into v_n from public.platform_refusals;
  if v_n <> v_before + 1 then
    raise exception 'le compteur de refus a enregistré % lignes au lieu d''une', v_n - v_before;
  end if;
  if (public.platform_refusal_counts() ->> 'wix')::int < 1 then
    raise exception 'platform_refusal_counts ne voit pas le refus qui vient d''être écrit';
  end if;

  -- ⚠ ET LA GARDE D'AUTORITÉ EST PARCOURUE. Un projet qui n'appartient pas à
  -- l'appelante ne peut pas recevoir de refus. Ici l'appelante est la
  -- migration, qui n'a ni `auth.uid()` ni jeton : `owns_project` rend donc
  -- false pour n'importe quel projet, y compris un qui existe.
  if public.record_platform_refusal('wix', gen_random_uuid()) then
    raise exception 'un refus a pu être agrafé au projet de quelqu''un d''autre';
  end if;
  select count(*) into v_n from public.platform_refusals;
  if v_n <> v_before + 1 then
    raise exception 'le refus agrafé à un projet étranger a quand même été écrit';
  end if;

  -- La sonde ne laisse rien derrière elle : ce n'est pas une vraie refusée.
  delete from public.platform_refusals
   where platform_id = 'wix' and project_id is null
     and occurred_at >= (select max(occurred_at) from public.platform_refusals);

  -- Et l'URL : le schéma est exigé, une adresse réelle ne l'est pas.
  if 'ceci nest pas une url' ~* '^https?://[^[:space:]]+$' then
    raise exception 'le motif d''URL accepte une phrase';
  end if;
  if not ('https://example.com/mon-cabinet' ~* '^https?://[^[:space:]]+$') then
    raise exception 'le motif d''URL refuse une adresse valide';
  end if;
end $$;
