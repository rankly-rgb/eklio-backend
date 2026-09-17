-- La qualification de plateforme. Fichier complet :
-- supabase/migrations/20260914120000_platform_qualification.sql
create table if not exists public.site_platforms (
  id            text        not null,
  label         text        not null,
  status        text        not null,
  notice        text,
  sort_order    smallint    not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint site_platforms_pkey primary key (id),
  constraint site_platforms_id_check    check (id ~ '^[a-z][a-z0-9_]{1,30}$'),
  constraint site_platforms_label_check check (btrim(label) <> ''),
  constraint site_platforms_status_check
    check (status = any (array['accepted', 'conditional', 'refused'])),
  constraint site_platforms_notice_check
    check (notice is null or btrim(notice) <> ''),
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
insert into public.site_platforms (id, label, status, notice, sort_order) values
  ('wordpress', 'WordPress', 'accepted', null, 1),
  ('squarespace', 'Squarespace', 'conditional',
   'We are still confirming what we can publish to Squarespace on your behalf. You can sign up, and we will tell you before you pay if anything has to be done by hand.',
   2),
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
  label = excluded.label, status = excluded.status,
  notice = excluded.notice, sort_order = excluded.sort_order;
-- <<< SITE PLATFORM DATA <<<

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
    alter table public.project_briefs add constraint project_briefs_site_url_check
      check (site_url is null
             or (site_url ~* '^https?://[^[:space:]]+$' and length(site_url) <= 500));
  end if;
end $$;

comment on column public.project_briefs.site_platform_id is
  'Which platform her site runs on, from site_platforms. NULL until she has been asked - existing briefs predate the question and are not retroactively unqualified.';
comment on column public.project_briefs.site_url is
  'Her site, as she typed it. Only the scheme and the absence of whitespace are checked: a stricter URL pattern refuses real addresses more often than it catches typos, and she can see a typo herself.';

create table if not exists public.platform_refusals (
  id          bigint generated always as identity primary key,
  platform_id text        not null references public.site_platforms (id),
  project_id  uuid        references public.projects (id) on delete set null,
  occurred_at timestamptz not null default clock_timestamp()
);

create index if not exists platform_refusals_platform_idx
  on public.platform_refusals (platform_id, occurred_at desc);

comment on table public.platform_refusals is
  'One row per visitor turned away because of her platform. NOT funnel_events: that table is purged at 180 days and unreadable by anyone but service_role, and the question these rows answer - how many customers are we turning away, and for which platform - is the one that decides whether to write a Squarespace client. It is asked over quarters.';

alter table public.platform_refusals enable row level security;
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
  if p_project_id is not null and not public.owns_project(p_project_id) then
    return false;
  end if;

  select sp.status into v_status
    from public.site_platforms sp
   where sp.id = p_platform_id;

  if v_status is distinct from 'refused' then
    return false;
  end if;

  insert into public.platform_refusals (platform_id, project_id)
  values (p_platform_id, p_project_id);
  return true;
end
$$;

revoke all on function public.record_platform_refusal(text, uuid) from public;
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

do $$
declare
  v_n      bigint;
  v_before bigint;
begin
  if (select status from public.site_platforms where id = 'wordpress') <> 'accepted' then
    raise exception 'WordPress n''est pas accepté';
  end if;
  if (select status from public.site_platforms where id = 'squarespace') <> 'conditional' then
    raise exception 'Squarespace n''est pas en conditionnel — la question n''est pas tranchée';
  end if;
  if exists (select 1 from public.site_platforms where status <> 'accepted' and notice is null) then
    raise exception 'une plateforme non acceptée ne dit pas pourquoi';
  end if;

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

  if public.record_platform_refusal('wix', gen_random_uuid()) then
    raise exception 'un refus a pu être agrafé au projet de quelqu''un d''autre';
  end if;
  select count(*) into v_n from public.platform_refusals;
  if v_n <> v_before + 1 then
    raise exception 'le refus agrafé à un projet étranger a quand même été écrit';
  end if;

  delete from public.platform_refusals
   where platform_id = 'wix' and project_id is null
     and occurred_at >= (select max(occurred_at) from public.platform_refusals);

  if 'ceci nest pas une url' ~* '^https?://[^[:space:]]+$' then
    raise exception 'le motif d''URL accepte une phrase';
  end if;
  if not ('https://example.com/mon-cabinet' ~* '^https?://[^[:space:]]+$') then
    raise exception 'le motif d''URL refuse une adresse valide';
  end if;
end $$;
