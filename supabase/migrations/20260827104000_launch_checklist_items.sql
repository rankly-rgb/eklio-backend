-- ============================================================================
-- Eklio — launch checklist
-- ============================================================================
-- The six steps between "the brand kit is ready" and "the brand is actually
-- out there", rendered on the retention home (Screen 7) as `3 OF 6` over a
-- progress bar. Six rows per brand kit, seeded at creation.
--
-- WHY ROWS AND NOT A jsonb COLUMN ON brand_kits
-- ---------------------------------------------
-- Unlike the directions or the voice guide, this is not a generated document
-- read whole: each item is ticked independently, at different times, by the
-- user. Rows give per-item timestamps, a `done_at is null` filter for the
-- progress count, and an UPDATE that touches one item instead of rewriting a
-- document. It is also the only client-writable thing in the whole deliverable.
--
-- OWNERSHIP IS DENORMALISED ON PURPOSE
-- ------------------------------------
-- `user_id` is carried here even though it is reachable through
-- `brand_kit_id -> brand_kits.project_id -> projects.user_id`. Every other
-- table in this schema resolves ownership through that chain in its policies,
-- which means a two-join EXISTS on every row read. The home screen reads this
-- table on every visit, and it is the one place where the direct column is
-- worth the duplication. The trigger fills it, no client ever supplies it, and
-- the FK below keeps it honest.
-- ============================================================================


-- ============================================================================
-- 1. Table
-- ============================================================================
-- `user_id` references `profiles(id)`, not `auth.users(id)`: that is the
-- convention `projects`, `subscriptions` and `purchases` all follow, and the
-- README records it as a deliberate choice. ON DELETE CASCADE on both keys —
-- a checklist is meaningless without the kit it belongs to.

create table if not exists public.launch_checklist_items (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id)    on delete cascade,
  brand_kit_id uuid not null references public.brand_kits (id)  on delete cascade,
  key          text not null,
  label        text not null,
  description  text,
  done_at      timestamptz,
  sort_order   int  not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- The idempotence guarantee, and it is a constraint rather than a convention:
  -- re-running the seeder must never produce a seventh item.
  constraint launch_checklist_items_brand_kit_id_key_key unique (brand_kit_id, key)
);

alter table public.launch_checklist_items drop constraint if exists launch_checklist_items_key_check;
alter table public.launch_checklist_items
  add constraint launch_checklist_items_key_check check (
    key = any (array['choose_direction'::text, 'paste_site_prompt'::text,
                     'update_directory'::text, 'first_post'::text,
                     'email_signature'::text, 'google_profile'::text])
  );

create index if not exists launch_checklist_items_user_id_idx
  on public.launch_checklist_items (user_id);
create index if not exists launch_checklist_items_brand_kit_id_idx
  on public.launch_checklist_items (brand_kit_id);
-- The home screen's read: this kit's items, in render order.
create index if not exists launch_checklist_items_brand_kit_id_sort_order_idx
  on public.launch_checklist_items (brand_kit_id, sort_order);

drop trigger if exists set_launch_checklist_items_updated_at on public.launch_checklist_items;
create trigger set_launch_checklist_items_updated_at
  before update on public.launch_checklist_items
  for each row execute function public.set_updated_at();

comment on table public.launch_checklist_items is
  'Six post-delivery steps per brand kit, rendered on the retention home. Seeded by trigger at kit creation; the only column a client may write is done_at.';


-- ============================================================================
-- 2. RLS — the one table in the deliverable a client may write to
-- ============================================================================
-- Deny-all baseline first, then per-operation policies on `auth.uid()`. Under
-- RLS the absence of a policy already refuses, but this schema writes its
-- refusals explicitly (see `profiles` after the cleanup migration, and every
-- billing table): an implicit refusal reads like an oversight six months later.
--
-- SELECT and UPDATE are owner-scoped. INSERT and DELETE are refused outright:
-- the six items are the product's definition of "launched", not a list the user
-- curates. Seeding goes through the SECURITY DEFINER trigger below, which is
-- not subject to these policies.

alter table public.launch_checklist_items enable row level security;

drop policy if exists "launch_checklist_items_select_own"    on public.launch_checklist_items;
drop policy if exists "launch_checklist_items_update_own"    on public.launch_checklist_items;
drop policy if exists "launch_checklist_items_insert_denied" on public.launch_checklist_items;
drop policy if exists "launch_checklist_items_delete_denied" on public.launch_checklist_items;

create policy "launch_checklist_items_select_own"
  on public.launch_checklist_items for select
  using (user_id = (select auth.uid()));

create policy "launch_checklist_items_update_own"
  on public.launch_checklist_items for update
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "launch_checklist_items_insert_denied"
  on public.launch_checklist_items for insert with check (false);

create policy "launch_checklist_items_delete_denied"
  on public.launch_checklist_items for delete using (false);

-- ⚠ RLS decides WHICH ROWS, column privileges decide WHICH COLUMNS, and only
-- the second one can stop a user rewriting their own checklist copy. Ticking an
-- item is `done_at`; `label`, `key` and `sort_order` are product content that
-- happens to sit in a user-owned row. Granting UPDATE on the single column is
-- the mechanism built for this, it is independent of the policy above, and it
-- leaves `service_role` (which needs to correct copy) untouched.
revoke update on table public.launch_checklist_items from anon, authenticated;
grant  update (done_at) on table public.launch_checklist_items to authenticated;


-- ============================================================================
-- 3. Seeding — idempotent, by trigger
-- ============================================================================
-- SECURITY DEFINER for the same reason `handle_new_user` and
-- `handle_new_project` are: the trigger inserts into a table whose INSERT is
-- refused to every client. It takes no caller input — the brand kit id comes
-- from the row being inserted and the user id is resolved through the FK chain
-- — so there is no argument to smuggle a foreign id in through.
--
-- Exposed as a callable function as well as a trigger: re-seeding a kit whose
-- checklist was damaged should not require deleting and recreating the kit.
--
-- ⚠ THE SIX LABELS ARE RENDERED VERBATIM on Screen 7. They are product copy,
-- not descriptions of product copy. Do not reword them here.

create or replace function public.seed_launch_checklist(p_brand_kit_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_count   int;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null then
    raise exception
      'seed_launch_checklist: brand kit % does not exist, or its project has no owner.', p_brand_kit_id;
  end if;

  insert into public.launch_checklist_items (user_id, brand_kit_id, key, label, description, sort_order)
  values
    (v_user_id, p_brand_kit_id, 'choose_direction',
     'Choose your creative direction',
     'Pick the one of the three that sounds like you. You can change it later.', 1),
    (v_user_id, p_brand_kit_id, 'paste_site_prompt',
     'Paste your site prompt into your website builder',
     'Copy the prompt from your brand kit and paste it into Squarespace, Framer, Webflow or Lovable.', 2),
    (v_user_id, p_brand_kit_id, 'update_directory',
     'Update your Psychology Today profile',
     'Same headline, same photo, same words as your site. One practice, one voice.', 3),
    (v_user_id, p_brand_kit_id, 'first_post',
     'Post your introduction on Instagram',
     'Use the signature template from your kit. One post is enough to start.', 4),
    (v_user_id, p_brand_kit_id, 'email_signature',
     'Update your email signature',
     'Your name, your credential, and the link to your new site.', 5),
    (v_user_id, p_brand_kit_id, 'google_profile',
     'Refresh your Google Business Profile',
     'The description and the photos, so search results match the site.', 6)
  -- The idempotence itself. A kit regenerated in place keeps the items it has,
  -- and the done_at values the user has already earned with them.
  on conflict (brand_kit_id, key) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

comment on function public.seed_launch_checklist(uuid) is
  'Insert the six launch checklist items for a brand kit. Idempotent: returns the number of rows actually inserted, 0 on re-run.';

create or replace function public.handle_new_brand_kit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.seed_launch_checklist(new.id);
  -- A kit created with a direction already chosen (regeneration, import) must
  -- not land with an unticked first item that is in fact done.
  if new.selected_direction_id is not null then
    perform public.complete_choose_direction(new.id);
  end if;
  return new;
end
$$;


-- ============================================================================
-- 4. Auto-completion of `choose_direction`
-- ============================================================================
-- The first item is the only one the product can observe directly: choosing a
-- direction IS setting `selected_direction_id`. Leaving the user to tick a box
-- for something they demonstrably just did makes the checklist feel like
-- paperwork rather than a guide.
--
-- `done_at is null` in the WHERE clause: re-selecting a direction must not
-- move a timestamp that already exists. The item records when the step was
-- first completed, not when it was last touched.

create or replace function public.complete_choose_direction(p_brand_kit_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.launch_checklist_items
     set done_at = now()
   where brand_kit_id = p_brand_kit_id
     and key = 'choose_direction'
     and done_at is null
$$;

create or replace function public.handle_brand_kit_direction_selected()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.complete_choose_direction(new.id);
  return new;
end
$$;

drop trigger if exists on_brand_kit_created on public.brand_kits;
create trigger on_brand_kit_created
  after insert on public.brand_kits
  for each row execute function public.handle_new_brand_kit();

drop trigger if exists on_brand_kit_direction_selected on public.brand_kits;
create trigger on_brand_kit_direction_selected
  after update of selected_direction_id on public.brand_kits
  for each row
  when (new.selected_direction_id is not null
        and new.selected_direction_id is distinct from old.selected_direction_id)
  execute function public.handle_brand_kit_direction_selected();


-- ============================================================================
-- 5. Backfill — kits that already exist
-- ============================================================================
-- The trigger only fires for kits created from now on. The US project carries
-- one kit today and it would otherwise show an empty checklist forever.

do $$
declare
  k record;
begin
  for k in select id from public.brand_kits loop
    perform public.seed_launch_checklist(k.id);
  end loop;
end
$$;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
declare
  n int;
begin
  -- Every kit has exactly six items, and the backfill is idempotent.
  select count(*) into n
    from public.brand_kits bk
   where (select count(*) from public.launch_checklist_items i where i.brand_kit_id = bk.id) <> 6;
  if n > 0 then
    raise exception 'launch_checklist_items: % brand kit(s) do not have exactly 6 checklist items.', n;
  end if;

  if not (select relrowsecurity from pg_class where oid = 'public.launch_checklist_items'::regclass) then
    raise exception 'launch_checklist_items: RLS is off. Migration aborted.';
  end if;

  -- A client must not be able to grant itself an item, or delete one it has
  -- not done. Both refusals are policies, and both must be present.
  if not exists (select 1 from pg_policies where schemaname='public'
                  and tablename='launch_checklist_items' and cmd='INSERT' and with_check = 'false') then
    raise exception 'launch_checklist_items: the INSERT refusal is missing.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public'
                  and tablename='launch_checklist_items' and cmd='DELETE' and qual = 'false') then
    raise exception 'launch_checklist_items: the DELETE refusal is missing.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger if exists on_brand_kit_direction_selected on public.brand_kits;
--   drop trigger if exists on_brand_kit_created on public.brand_kits;
--   drop function if exists public.handle_brand_kit_direction_selected();
--   drop function if exists public.handle_new_brand_kit();
--   drop function if exists public.complete_choose_direction(uuid);
--   drop function if exists public.seed_launch_checklist(uuid);
--   drop table if exists public.launch_checklist_items;
