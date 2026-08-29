-- ============================================================================
-- Eklio — the paywall, in the one place every route already goes through
-- ============================================================================
-- Follows `20260829122000_derive_variants_only_when_inputs_move.sql`.
--
-- MEASURED, NOT ASSUMED: `paid` was a client-side branch. No route read
-- `purchases`, and everything downstream hung off `selected_direction_id`. A
-- signed-in account got the kit, the PDF and the site editor for nothing, with
-- unlimited generations at $0.09–$1.80 each.
--
-- The decision: **the reveal stays free** — three directions are the sales
-- pitch. Everything from choosing one onward is paid. Free generation is capped.
--
-- The barrier goes here rather than in the Next routes because there are seven
-- routes today, more tomorrow, and one that forgets undoes all of them. These
-- RPCs are already scoped by `auth.uid()`; entitlement belongs beside it.
--
-- ⚠ THE SENTENCE IS WRITTEN ONCE. `brand_kit_entitled` is the only definition of
-- "she has paid for this kit". Everything else calls it. A second copy in a
-- route, or in a policy, is a copy that drifts — and a paywall that drifts is a
-- paywall that is open on one path.
-- ============================================================================


-- ============================================================================
-- 1. Purchases can express what Stripe can actually do to a charge
-- ============================================================================
-- `pending|paid|refunded|failed` cannot say "disputed", and a dispute is not a
-- refund. A partial refund is neither. And `dispute.closed: won` has to restore
-- what was there before — which one mutable column cannot do, because it does
-- not remember what was there before.

alter table public.purchases drop constraint if exists purchases_status_check;
alter table public.purchases add constraint purchases_status_check
  check (status = any (array['pending', 'paid', 'partially_refunded',
                             'refunded', 'disputed', 'failed']));

-- ⚠ `paid_at` was `(status = 'paid') = (paid_at is not null)`. Under the new
-- statuses that is wrong in both directions: a partially refunded charge WAS
-- paid and must keep its timestamp, and a disputed one likewise. Money that was
-- captured stays captured in the record even when it is later given back.
do $$
declare n_backfilled int; n_bad int;
begin
  update public.purchases
     set paid_at = coalesce(paid_at, updated_at, created_at)
   where status in ('paid', 'partially_refunded', 'refunded', 'disputed')
     and paid_at is null;
  get diagnostics n_backfilled = row_count;

  select count(*) into n_bad from public.purchases
   where status in ('pending', 'failed') and paid_at is not null;

  if n_backfilled > 0 then
    raise notice 'purchases: back-filled paid_at on % captured row(s) that had none.', n_backfilled;
  end if;
  -- ⚠ STOP rather than widen the constraint to fit bad data. A pending purchase
  -- with a payment timestamp is a bug upstream, not a shape to accommodate.
  if n_bad > 0 then
    raise exception 'purchases: % row(s) are pending or failed but carry a paid_at.', n_bad;
  end if;
end
$$;

alter table public.purchases drop constraint if exists purchases_paid_at_check;
alter table public.purchases add constraint purchases_paid_at_check
  check (
    case
      when status in ('pending', 'failed') then paid_at is null
      else paid_at is not null
    end);

comment on column public.purchases.status is
  'Current status only. The history that produced it is in purchase_status_events, which is what makes a won dispute restorable.';


-- ============================================================================
-- 2. purchase_status_events — append-only history
-- ============================================================================

create table if not exists public.purchase_status_events (
  id              uuid        not null default gen_random_uuid(),
  purchase_id     uuid        not null,
  stripe_event_id text        not null,
  previous_status text,
  new_status      text        not null,
  amount_cents    integer,
  occurred_at     timestamptz not null,
  event_type      text        not null,
  created_at      timestamptz not null default now(),
  constraint purchase_status_events_pkey primary key (id),
  -- ⚠ idempotency. Stripe retries; a retry must not write a second row and must
  -- not move the status a second time.
  constraint purchase_status_events_stripe_event_id_key unique (stripe_event_id),
  constraint purchase_status_events_purchase_id_fkey foreign key (purchase_id)
    references public.purchases (id) on delete cascade,
  constraint purchase_status_events_new_status_check
    check (new_status = any (array['pending', 'paid', 'partially_refunded',
                                   'refunded', 'disputed', 'failed'])),
  constraint purchase_status_events_previous_status_check
    check (previous_status is null
           or previous_status = any (array['pending', 'paid', 'partially_refunded',
                                           'refunded', 'disputed', 'failed'])),
  constraint purchase_status_events_amount_check
    check (amount_cents is null or amount_cents >= 0),
  constraint purchase_status_events_event_type_check
    check (btrim(event_type) <> '')
);

comment on table public.purchase_status_events is
  'Append-only record of every Stripe event that moved a purchase''s status. Insert-only from trusted contexts; a client may read its own and nothing more.';

create index if not exists purchase_status_events_purchase_id_occurred_at_idx
  on public.purchase_status_events (purchase_id, occurred_at, created_at);

alter table public.purchase_status_events enable row level security;

drop policy if exists purchase_status_events_select_own on public.purchase_status_events;
create policy purchase_status_events_select_own
  on public.purchase_status_events for select
  using (exists (select 1 from public.purchases p
                  where p.id = purchase_status_events.purchase_id
                    and p.user_id = (select auth.uid())));

drop policy if exists purchase_status_events_insert_denied on public.purchase_status_events;
create policy purchase_status_events_insert_denied
  on public.purchase_status_events for insert with check (false);

drop policy if exists purchase_status_events_update_denied on public.purchase_status_events;
create policy purchase_status_events_update_denied
  on public.purchase_status_events for update using (false);

drop policy if exists purchase_status_events_delete_denied on public.purchase_status_events;
create policy purchase_status_events_delete_denied
  on public.purchase_status_events for delete using (false);

-- ⚠ APPEND-ONLY IS A TRIGGER, NOT A POLICY. The table owner and any
-- SECURITY DEFINER function bypass RLS; only a trigger refuses everyone. The
-- one exception is a caller with no JWT — a migration, a cascade from account
-- deletion — because a person who deletes their account must actually leave.
create or replace function public.purchase_status_events_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null then
    raise exception 'purchase_status_events is append-only: % is not allowed.', tg_op
      using errcode = '42501';
  end if;
  return case tg_op when 'DELETE' then old else new end;
end
$$;

drop trigger if exists purchase_status_events_no_rewrite on public.purchase_status_events;
create trigger purchase_status_events_no_rewrite
  before update or delete on public.purchase_status_events
  for each row execute function public.purchase_status_events_append_only();

-- The event carries the status forward; `purchases.status` stays the current
-- value, derived from the history rather than written beside it.
create or replace function public.purchase_status_events_apply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_prev text;
begin
  select p.status into v_prev from public.purchases p where p.id = new.purchase_id;
  -- ⚠ previous_status is RECORDED, never accepted. A caller that guessed wrong
  -- would otherwise write a history that never happened.
  new.previous_status := v_prev;
  return new;
end
$$;

drop trigger if exists purchase_status_events_capture_previous on public.purchase_status_events;
create trigger purchase_status_events_capture_previous
  before insert on public.purchase_status_events
  for each row execute function public.purchase_status_events_apply();

create or replace function public.purchase_status_events_advance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.purchases
     set status  = new.new_status,
         paid_at = case
                     when new.new_status in ('pending', 'failed') then null
                     else coalesce(paid_at, new.occurred_at)
                   end
   where id = new.purchase_id;
  return null;
end
$$;

drop trigger if exists purchase_status_events_advance_status on public.purchase_status_events;
create trigger purchase_status_events_advance_status
  after insert on public.purchase_status_events
  for each row execute function public.purchase_status_events_advance();

grant select on public.purchase_status_events to authenticated;
grant select, insert on public.purchase_status_events to service_role;
revoke update, delete on public.purchase_status_events from authenticated, service_role, anon;

-- Recording one, idempotently. Returns true when this event was new and applied,
-- false when Stripe was retrying and it had already been recorded.
create or replace function public.record_purchase_status_event(
  p_purchase_id     uuid,
  p_stripe_event_id text,
  p_new_status      text,
  p_event_type      text,
  p_amount_cents    integer     default null,
  p_occurred_at     timestamptz default now())
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  insert into public.purchase_status_events
    (purchase_id, stripe_event_id, new_status, event_type, amount_cents, occurred_at)
  values
    (p_purchase_id, p_stripe_event_id, p_new_status, p_event_type, p_amount_cents,
     coalesce(p_occurred_at, now()))
  on conflict (stripe_event_id) do nothing
  returning id into v_id;

  return v_id is not null;
end
$$;

revoke execute on function public.record_purchase_status_event(uuid, text, text, text, integer, timestamptz)
  from public, anon, authenticated;
grant execute on function public.record_purchase_status_event(uuid, text, text, text, integer, timestamptz)
  to service_role;

-- ⚠ What a won dispute restores. Not "paid" — whatever the charge actually was
-- before the dispute opened, which may have been `partially_refunded`. This is
-- the question a single mutable column could not answer.
create or replace function public.purchase_status_before(p_purchase_id uuid, p_status text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select e.previous_status
    from public.purchase_status_events e
   where e.purchase_id = p_purchase_id
     and e.new_status = p_status
   order by e.occurred_at desc, e.created_at desc
   limit 1
$$;

comment on function public.purchase_status_before(uuid, text) is
  'The status a purchase held immediately before it most recently entered p_status. Restores a won dispute to what the charge actually was, which may not be "paid".';

grant execute on function public.purchase_status_before(uuid, text) to authenticated, service_role;


-- ============================================================================
-- 3. brand_kit_entitled — the sentence, written once
-- ============================================================================
-- ⚠ `paid` and `partially_refunded` entitle. `refunded`, `disputed`, `failed`
-- and `pending` do not. A partial refund is a discount after the fact, not a
-- withdrawal of the thing she bought; a dispute is money in escrow and the
-- deliverable comes back until it is resolved.

create or replace function public.brand_kit_entitling_statuses()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['paid', 'partially_refunded']
$$;

grant execute on function public.brand_kit_entitling_statuses() to authenticated, service_role;

create or replace function public.brand_kit_is_owned(p_brand_kit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = p_brand_kit_id
       and pr.user_id = (select auth.uid()))
$$;

comment on function public.brand_kit_is_owned(uuid) is
  'Whether this kit exists AND belongs to the caller. Separates "no such kit" from "not paid for" so the two never get the same answer.';

grant execute on function public.brand_kit_is_owned(uuid) to authenticated, service_role;

create or replace function public.brand_kit_entitled(p_brand_kit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- ⚠ NOT `coalesce(..., false)` by accident: `exists` never returns NULL, and
  -- the auth.uid() comparison is inside it, so an unauthenticated caller gets
  -- FALSE rather than NULL. A NULL here would be read as "not entitled" by an
  -- `if not` and as "entitled" by a `check`, which is how paywalls leak.
  select exists (
    select 1
      from public.brand_kits bk
      join public.projects  pr on pr.id = bk.project_id
      join public.purchases pu on pu.project_id = pr.id
     where bk.id = p_brand_kit_id
       and pr.user_id = (select auth.uid())
       and pu.user_id = (select auth.uid())
       and pu.status = any (public.brand_kit_entitling_statuses()))
$$;

comment on function public.brand_kit_entitled(uuid) is
  'THE definition of "this caller has paid for this brand kit". Everything that gates on payment calls this and nothing re-states it. auth.uid()-scoped: false for a kit that is not the caller''s, and false when there is no caller.';

grant execute on function public.brand_kit_entitled(uuid) to authenticated, service_role;

-- ⚠ `generation_credits.has_paid` is a SECOND COPY of that sentence, and it has
-- always been false because nothing writes it. It is not the source of truth and
-- must not become one.
comment on column public.generation_credits.has_paid is
  'DEAD. Nothing writes it and nothing may read it. Entitlement is brand_kit_entitled(); this column is a stale duplicate kept only because dropping a column is not this migration''s job.';


-- ============================================================================
-- 4. The guard, and the new error code
-- ============================================================================
-- Returns NULL when the call may proceed, or the envelope to return.
--
-- ⚠ ORDER MATTERS AND IT IS A DISCLOSURE QUESTION. Ownership is tested BEFORE
-- entitlement, so `payment_required` never confirms that someone else's kit id
-- exists. And "she has a kit she has not paid for" is a different sentence from
-- "there is no such kit" — the UI opens checkout on one and apologises on the
-- other, so they must never collapse into each other.

create or replace function public.site_spec_entitlement_error(p_brand_kit_id uuid)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select case
    when (select auth.uid()) is null then
      public.site_spec_error('unauthenticated', 'Sign in to open your site spec.')
    when not public.brand_kit_is_owned(p_brand_kit_id) then
      public.site_spec_error('not_found', 'No brand kit here.')
    when not public.brand_kit_entitled(p_brand_kit_id) then
      public.site_spec_error('payment_required',
        'Your three directions are yours to look at. Choosing one, and everything that comes with it, is part of the paid kit.')
    else null
  end
$$;

grant execute on function public.site_spec_entitlement_error(uuid) to authenticated, service_role;


-- ============================================================================
-- 5. The writes refuse, and so do the two reads
-- ============================================================================
-- The reads refuse because the output IS the deliverable. `site_catalog` is
-- untouched: it is public catalog data and describes the product she is being
-- asked to buy.
--
-- ⚠ Every one of these already had a `unauthenticated` check and nothing else.
-- The gate REPLACES that check rather than sitting beside it, so there is one
-- ladder — signed in, owns it, paid for it — and not two that can disagree.

-- ---- site_spec_patch(uuid,jsonb) ----
CREATE OR REPLACE FUNCTION public.site_spec_patch(p_brand_kit_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  v_gate jsonb;
  s        public.site_specs%rowtype;
  n        public.site_specs%rowtype;
  k        text;
  v_marks  jsonb := '{}'::jsonb;
  v_hero   jsonb;
  v_det    jsonb;
  v_len    int;
  v_path   text;
  v_next   int;
begin
  v_gate := public.site_spec_entitlement_error(p_brand_kit_id);
  if v_gate is not null then return v_gate; end if;

  select * into s
    from public.site_specs
   where brand_kit_id = p_brand_kit_id
     and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return public.site_spec_error('invalid_body', 'The update must be a JSON object.');
  end if;

  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (public.site_spec_patchable_keys())) then
      return public.site_spec_error('unknown_field',
        format('"%s" is not a field of the site spec.', k), k);
    end if;
  end loop;

  n := s;

  for k in select unnest(array['primary', 'secondary', 'accent',
                               'light_neutral', 'dark_neutral', 'paper']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string'
         or (p_patch->>k) !~ '^#[0-9A-Fa-f]{6}$' then
        return public.site_spec_error('invalid_field',
          'A color must be a hex value like #3B2C3A.', k);
      end if;
      case k
        when 'primary'       then n.primary_hex       := upper(p_patch->>k);
        when 'secondary'     then n.secondary_hex     := upper(p_patch->>k);
        when 'accent'        then n.accent_hex        := upper(p_patch->>k);
        when 'light_neutral' then n.light_neutral_hex := upper(p_patch->>k);
        when 'dark_neutral'  then n.dark_neutral_hex  := upper(p_patch->>k);
        when 'paper'         then n.paper_hex         := upper(p_patch->>k);
      end case;
    end if;
  end loop;

  if p_patch ? 'type_pairing_id' then
    if jsonb_typeof(p_patch->'type_pairing_id') = 'null' then
      n.type_pairing_id := null;
    elsif jsonb_typeof(p_patch->'type_pairing_id') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The type pairing must be a catalog id.', 'type_pairing_id');
    else
      if not exists (select 1 from public.type_pairings tp
                      where tp.id = p_patch->>'type_pairing_id') then
        return public.site_spec_error('invalid_field',
          format('"%s" is not a type pairing we carry.', p_patch->>'type_pairing_id'),
          'type_pairing_id');
      end if;
      n.type_pairing_id := p_patch->>'type_pairing_id';
      select tp.heading_font, tp.body_font, tp.google_fonts_url
        into n.heading_font, n.body_font, n.google_fonts_url
        from public.type_pairings tp where tp.id = n.type_pairing_id;
    end if;
  end if;

  for k in select unnest(array['heading_font', 'body_font', 'google_fonts_url']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string' or btrim(p_patch->>k) = '' then
        return public.site_spec_error('invalid_field',
          'This must be a font name we can render.', k);
      end if;
      case k
        when 'heading_font'     then n.heading_font     := btrim(p_patch->>k);
        when 'body_font'        then n.body_font        := btrim(p_patch->>k);
        when 'google_fonts_url' then n.google_fonts_url := btrim(p_patch->>k);
      end case;
    end if;
  end loop;

  if p_patch ? 'hero' then
    if jsonb_typeof(p_patch->'hero') <> 'object' then
      return public.site_spec_error('invalid_field', 'The hero must be an object.', 'hero');
    end if;
    v_hero := n.hero;
    for k in select jsonb_object_keys(p_patch->'hero') loop
      if not (k = any (array['overline', 'headline', 'subhead',
                             'cta_label', 'cta_target_url'])) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a field of the hero.', k), 'hero.' || k);
      end if;
      v_hero := jsonb_set(v_hero, array[k], p_patch->'hero'->k);
    end loop;

    if not public.site_spec_hero_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'Every hero field must be text.', 'hero');
    end if;
    if not public.site_spec_hero_lengths_valid(v_hero) then
      for k, v_len in select * from (values ('overline', 48), ('headline', 90),
                                            ('subhead', 220), ('cta_label', 28)) x(a, b) loop
        if coalesce(char_length(v_hero->>k), 0) > v_len then
          return public.site_spec_error('too_long',
            format('This is %s characters. The limit is %s.',
                   char_length(v_hero->>k), v_len), 'hero.' || k);
        end if;
      end loop;
    end if;
    if not public.site_spec_cta_target_url_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'The button link must start with https://, http://, mailto: or tel:.',
        'hero.cta_target_url');
    end if;
    n.hero := v_hero;
  end if;

  if p_patch ? 'about_excerpt' then
    if jsonb_typeof(p_patch->'about_excerpt') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The About text must be text.', 'about_excerpt');
    end if;
    if char_length(p_patch->>'about_excerpt') > 600 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 600.',
               char_length(p_patch->>'about_excerpt')), 'about_excerpt');
    end if;
    n.about_excerpt := p_patch->>'about_excerpt';
  end if;

  if p_patch ? 'extra_instructions' then
    if jsonb_typeof(p_patch->'extra_instructions') = 'null' then
      n.extra_instructions := null;
    elsif jsonb_typeof(p_patch->'extra_instructions') <> 'string' then
      return public.site_spec_error('invalid_field',
        'Your notes must be text.', 'extra_instructions');
    elsif char_length(p_patch->>'extra_instructions') > 2000 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 2000.',
               char_length(p_patch->>'extra_instructions')), 'extra_instructions');
    else
      n.extra_instructions := p_patch->>'extra_instructions';
    end if;
  end if;

  if p_patch ? 'pages' then
    if not public.site_spec_pages_valid(p_patch->'pages') then
      return public.site_spec_error('invalid_field',
        'Each page needs a known key, a label, an enabled flag and a list of sections with unique keys.',
        'pages');
    end if;
    if not public.site_spec_pages_lengths_valid(p_patch->'pages') then
      v_path := public.site_spec_first_overlong_field(p_patch->'pages');
      return public.site_spec_error('too_long',
        'This is over 800 characters, which is the limit for a section field.',
        coalesce(v_path, 'pages'));
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_patch->'pages') pg
      cross join lateral jsonb_array_elements(pg.value->'sections') sc
      join public.section_types st on st.id = sc.value->>'type'
       where not (pg.value->>'key' = any (st.allowed_pages))
    ) then
      return public.site_spec_error('invalid_field',
        'One of these sections is not allowed on the page it was put on.', 'pages');
    end if;
    n.pages := p_patch->'pages';
  end if;

  if p_patch ? 'practice_details' then
    if jsonb_typeof(p_patch->'practice_details') <> 'object' then
      return public.site_spec_error('invalid_field',
        'The practice details must be an object.', 'practice_details');
    end if;
    v_det := n.practice_details;
    for k in select jsonb_object_keys(p_patch->'practice_details') loop
      if not (k = any (public.site_spec_practice_detail_keys())) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a practice detail.', k), 'practice_details.' || k);
      end if;
      v_det := jsonb_set(v_det, array[k], p_patch->'practice_details'->k);
    end loop;
    if not public.site_spec_practice_details_valid(v_det) then
      return public.site_spec_error('invalid_field',
        'The state must be a two-letter code, and every other detail must be text.',
        'practice_details');
    end if;
    n.practice_details := v_det;
  end if;

  if p_patch ? 'target' then
    if jsonb_typeof(p_patch->'target') <> 'string'
       or not exists (select 1 from public.builder_targets bt
                       where bt.id = p_patch->>'target') then
      return public.site_spec_error('invalid_field',
        'Pick one of the website builders we support.', 'target');
    end if;
    n.target := p_patch->>'target';
  end if;

  v_next := s.spec_version + 1;

  if n.primary_hex is distinct from s.primary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Primary color changed', v_next); end if;
  if n.secondary_hex is distinct from s.secondary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Secondary color changed', v_next); end if;
  if n.accent_hex is distinct from s.accent_hex then
    v_marks := v_marks || jsonb_build_object('colors|Accent color changed', v_next); end if;
  if n.paper_hex is distinct from s.paper_hex then
    v_marks := v_marks || jsonb_build_object('colors|Page background changed', v_next); end if;
  if n.light_neutral_hex is distinct from s.light_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Section background changed', v_next); end if;
  if n.dark_neutral_hex is distinct from s.dark_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Body text color changed', v_next); end if;

  if n.heading_font is distinct from s.heading_font then
    v_marks := v_marks || jsonb_build_object('typography|Heading font changed', v_next); end if;
  if n.body_font is distinct from s.body_font then
    v_marks := v_marks || jsonb_build_object('typography|Body font changed', v_next); end if;
  if n.google_fonts_url is distinct from s.google_fonts_url then
    v_marks := v_marks || jsonb_build_object('typography|Font stylesheet changed', v_next); end if;

  if n.hero is distinct from s.hero then
    v_marks := v_marks || jsonb_build_object('copy|Hero copy edited', v_next); end if;
  if n.about_excerpt is distinct from s.about_excerpt then
    v_marks := v_marks || jsonb_build_object('copy|About text edited', v_next); end if;
  if n.practice_details is distinct from s.practice_details then
    v_marks := v_marks || jsonb_build_object('copy|Practice details edited', v_next); end if;

  if n.pages is distinct from s.pages then
    if public.site_spec_pages_skeleton(n.pages)
       is distinct from public.site_spec_pages_skeleton(s.pages) then
      v_marks := v_marks || jsonb_build_object('structure|Page structure changed', v_next);
    end if;
    if public.site_spec_pages_copy(n.pages)
       is distinct from public.site_spec_pages_copy(s.pages) then
      v_marks := v_marks || jsonb_build_object('copy|Section copy edited', v_next);
    end if;
  end if;

  if n.extra_instructions is distinct from s.extra_instructions then
    v_marks := v_marks || jsonb_build_object('instructions|Your own notes edited', v_next); end if;

  if n.target is distinct from s.target then
    v_marks := v_marks || jsonb_build_object('structure|Website builder changed', v_next); end if;

  if v_marks = '{}'::jsonb then
    return public.site_spec_envelope(to_jsonb(s));
  end if;

  update public.site_specs
     set primary_hex        = n.primary_hex,
         secondary_hex      = n.secondary_hex,
         accent_hex         = n.accent_hex,
         light_neutral_hex  = n.light_neutral_hex,
         dark_neutral_hex   = n.dark_neutral_hex,
         paper_hex          = n.paper_hex,
         type_pairing_id    = n.type_pairing_id,
         heading_font       = n.heading_font,
         body_font          = n.body_font,
         google_fonts_url   = n.google_fonts_url,
         hero               = n.hero,
         about_excerpt      = n.about_excerpt,
         pages              = n.pages,
         practice_details   = n.practice_details,
         extra_instructions = n.extra_instructions,
         target             = n.target,
         spec_version       = v_next,
         change_marks       = coalesce(change_marks, '{}'::jsonb) || v_marks
   where id = s.id
   returning * into n;

  return public.site_spec_envelope(to_jsonb(n));
end
$function$;

-- ---- site_spec_reset(uuid,text) ----
CREATE OR REPLACE FUNCTION public.site_spec_reset(p_brand_kit_id uuid, p_scope text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  v_gate jsonb;
  s      public.site_specs%rowtype;
  v      jsonb;
  patch  jsonb := '{}'::jsonb;
  pages  jsonb;
begin
  v_gate := public.site_spec_entitlement_error(p_brand_kit_id);
  if v_gate is not null then return v_gate; end if;
  if not (coalesce(p_scope, '') = any (array['all', 'colors', 'typography',
                                             'copy', 'structure'])) then
    return public.site_spec_error('invalid_scope',
      'Reset all, colors, typography, copy or structure.', 'scope');
  end if;

  select * into s from public.site_specs
   where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  v := public.site_spec_seed_values(p_brand_kit_id);
  if v is null then
    return public.site_spec_error('no_direction',
      'This brand kit has no chosen direction to reset to.');
  end if;

  if p_scope in ('all', 'colors') then
    patch := patch || jsonb_build_object(
      'primary',       v->>'primary',
      'secondary',     v->>'secondary',
      'accent',        v->>'accent',
      'light_neutral', v->>'light_neutral',
      'dark_neutral',  v->>'dark_neutral',
      'paper',         v->>'paper');
  end if;

  if p_scope in ('all', 'typography') then
    patch := patch || jsonb_build_object(
      'type_pairing_id',  v->'type_pairing_id',
      'heading_font',     v->>'heading_font',
      'body_font',        v->>'body_font',
      'google_fonts_url', v->>'google_fonts_url');
  end if;

  if p_scope in ('all', 'copy') then
    patch := patch || jsonb_build_object(
      'hero', jsonb_set(v->'hero', '{cta_target_url}',
                        coalesce(s.hero->'cta_target_url', 'null'::jsonb)),
      'about_excerpt',    v->>'about_excerpt',
      'practice_details', v->'practice_details');

    select jsonb_agg(
             pg.value || jsonb_build_object('sections', coalesce((
               select jsonb_agg(sc.value || jsonb_build_object(
                        'fields', coalesce(d.fields, '{}'::jsonb)) order by sc.ord)
                 from jsonb_array_elements(pg.value->'sections') with ordinality as sc(value, ord)
                 left join lateral (
                   select ds.value->'fields' as fields
                     from jsonb_array_elements(v->'pages') as dp
                     cross join lateral jsonb_array_elements(dp.value->'sections') as ds
                    where dp.value->>'key' = pg.value->>'key'
                      and ds.value->>'key' = sc.value->>'key'
                    limit 1) d on true), '[]'::jsonb))
             order by pg.ord)
      into pages
      from jsonb_array_elements(s.pages) with ordinality as pg(value, ord);
    patch := patch || jsonb_build_object('pages', pages);
  end if;

  if p_scope in ('all', 'structure') then
    select jsonb_agg(
             dp.value || jsonb_build_object('sections', coalesce((
               select jsonb_agg(ds.value || jsonb_build_object(
                        'fields', case when p_scope = 'all' then ds.value->'fields'
                                       else coalesce(m.fields, ds.value->'fields') end)
                      order by ds.ord)
                 from jsonb_array_elements(dp.value->'sections') with ordinality as ds(value, ord)
                 left join lateral (
                   select cs.value->'fields' as fields
                     from jsonb_array_elements(s.pages) as cp
                     cross join lateral jsonb_array_elements(cp.value->'sections') as cs
                    where cp.value->>'key' = dp.value->>'key'
                      and cs.value->>'key' = ds.value->>'key'
                    limit 1) m on true), '[]'::jsonb))
             order by dp.ord)
      into pages
      from jsonb_array_elements(v->'pages') with ordinality as dp(value, ord);
    patch := patch || jsonb_build_object('pages', pages);
  end if;

  if p_scope = 'all' then
    patch := patch || jsonb_build_object('extra_instructions', null);
  end if;

  return public.site_spec_patch(p_brand_kit_id, patch);
end
$function$;

-- ---- site_spec_fix_contrast(uuid,text) ----
CREATE OR REPLACE FUNCTION public.site_spec_fix_contrast(p_brand_kit_id uuid, p_pair_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  v_gate jsonb;
  s    public.site_specs%rowtype;
  pair jsonb;
begin
  v_gate := public.site_spec_entitlement_error(p_brand_kit_id);
  if v_gate is not null then return v_gate; end if;

  select * into s from public.site_specs
   where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  select p.value into pair
    from jsonb_array_elements(public.site_spec_contrast(to_jsonb(s))->'pairs') as p
   where p.value->>'pair_id' = p_pair_id;

  if pair is null then
    return public.site_spec_error('invalid_field',
      format('"%s" is not a contrast pair we report.', p_pair_id), 'pair_id');
  end if;

  if pair->'suggested_fix' = 'null'::jsonb or pair->'suggested_fix' is null then
    -- Already readable, so there is nothing to apply. Not an error the user
    -- caused, and the envelope she gets back proves the pair passes.
    return public.site_spec_error('no_fix_needed',
      format('%s already reaches AA contrast.', pair->>'label'), 'pair_id');
  end if;

  return public.site_spec_patch(
    p_brand_kit_id,
    jsonb_build_object(pair->'suggested_fix'->>'token', pair->'suggested_fix'->>'hex'));
end
$function$;

-- ---- site_output_mark_copied(uuid) ----
CREATE OR REPLACE FUNCTION public.site_output_mark_copied(p_brand_kit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  v_gate jsonb;
  s public.site_specs%rowtype;
begin
  v_gate := public.site_spec_entitlement_error(p_brand_kit_id);
  if v_gate is not null then return v_gate; end if;

  update public.site_specs
     set last_copied_spec_version = spec_version
   where brand_kit_id = p_brand_kit_id
     and user_id = (select auth.uid())
     and last_copied_spec_version is distinct from spec_version
   returning * into s;

  if not found then
    -- Either it is already marked at this version, or it is not hers. The
    -- second case has to answer exactly like a kit that does not exist.
    select * into s from public.site_specs
     where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
    if not found then
      return public.site_spec_error('not_found', 'No site spec for this brand kit.');
    end if;
  end if;

  return public.site_spec_envelope(to_jsonb(s));
end
$function$;

-- ---- site_spec_set_target: gated in its own right ----
-- It delegates to `site_spec_patch`, so it would refuse anyway. The guard is
-- repeated because a later edit that stops delegating must not silently open a
-- hole, and because the caller deserves the refusal before any work is done.
create or replace function public.site_spec_set_target(p_brand_kit_id uuid, p_target text)
returns jsonb
language sql
security definer
set search_path = ''
set jit = 'off'
as $$
  select coalesce(
    public.site_spec_entitlement_error(p_brand_kit_id),
    public.site_spec_patch(p_brand_kit_id, jsonb_build_object('target', p_target)))
$$;

grant execute on function public.site_spec_set_target(uuid, text) to authenticated;

-- ---- site_spec_get ----
create or replace function public.site_spec_get(p_brand_kit_id uuid)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select coalesce(
    public.site_spec_entitlement_error(p_brand_kit_id),
    (select public.site_spec_envelope(to_jsonb(s))
       from public.site_specs s where s.brand_kit_id = p_brand_kit_id),
    public.site_spec_error('not_found', 'No site spec for this brand kit.'))
$$;

grant execute on function public.site_spec_get(uuid) to authenticated;

-- ---- site_output_get ----
create or replace function public.site_output_get(
  p_brand_kit_id uuid, p_target text default null, p_format text default 'json')
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select case
    -- the format complaint comes first: it is about the request, not the buyer
    when not (coalesce(p_format, 'json') = any (array['json', 'md', 'txt'])) then
      public.site_spec_error('invalid_format',
        'Ask for json, md or txt.', 'format')
    when public.site_spec_entitlement_error(p_brand_kit_id) is not null then
      public.site_spec_entitlement_error(p_brand_kit_id)
    else coalesce((
      select case
        when o.out ? 'error' then o.out
        when coalesce(p_format, 'json') = 'json' then
          jsonb_build_object('target', o.target, 'format', 'json', 'output', o.out)
        else
          jsonb_build_object('target', o.target, 'format', coalesce(p_format, 'json'),
            'text', public.site_spec_output_render(
                      bt.label, o.out, coalesce(p_format, 'json') = 'md'))
      end
      from public.site_specs s
      cross join lateral (
        select coalesce(p_target, s.target) as target,
               public.site_spec_output(to_jsonb(s), coalesce(p_target, s.target)) as out
      ) o
      left join public.builder_targets bt on bt.id = o.target
      where s.brand_kit_id = p_brand_kit_id),
      public.site_spec_error('not_found', 'No site spec for this brand kit.'))
  end
$$;

grant execute on function public.site_output_get(uuid, text, text) to authenticated;


-- ============================================================================
-- 6. Choosing a direction is the moment she crosses the line
-- ============================================================================
-- Everything downstream hangs off `selected_direction_id`, so this is the write
-- that has to be refused. It is refused twice on purpose.
--
-- ⚠ The RPC gives the frontend the same JSON envelope as everything else, so it
-- can open checkout. The TRIGGER is what actually holds, because the barrier
-- must not depend on the caller choosing the polite door.

create or replace function public.brand_kit_select_direction(
  p_brand_kit_id uuid, p_direction_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_gate jsonb;
  v_ok   boolean;
begin
  v_gate := public.site_spec_entitlement_error(p_brand_kit_id);
  if v_gate is not null then return v_gate; end if;

  select exists (
    select 1 from public.brand_kits bk
    cross join lateral jsonb_array_elements(coalesce(bk.directions, '[]'::jsonb)) d
     where bk.id = p_brand_kit_id and d.value->>'id' = p_direction_id)
    into v_ok;
  if not coalesce(v_ok, false) then
    return public.site_spec_error('invalid_field',
      'That is not one of the directions on this kit.', 'direction_id');
  end if;

  update public.brand_kits set selected_direction_id = p_direction_id
   where id = p_brand_kit_id;

  return public.site_spec_get(p_brand_kit_id);
end
$$;

grant execute on function public.brand_kit_select_direction(uuid, text) to authenticated;

create or replace function public.enforce_direction_selection_entitlement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_before text;
begin
  -- ⚠ Only a caller carrying a JWT is a client. A migration, the Stripe webhook
  -- on service_role, a cascade — none of them have `auth.uid()`, and none of
  -- them should be told they have not paid. A browser can never reach here
  -- without one.
  if (select auth.uid()) is null then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    v_before := old.selected_direction_id;
  end if;
  if new.selected_direction_id is not null
     and new.selected_direction_id is distinct from v_before
     and not public.brand_kit_entitled(new.id) then
    raise exception
      'payment_required: choosing a direction is part of the paid kit.'
      using errcode = '42501';
  end if;
  return new;
end
$$;

drop trigger if exists enforce_direction_selection_entitlement on public.brand_kits;
create trigger enforce_direction_selection_entitlement
  before insert or update of selected_direction_id on public.brand_kits
  for each row execute function public.enforce_direction_selection_entitlement();


-- ============================================================================
-- 7. Generation credits — metering the frontend cannot do safely
-- ============================================================================
-- `generation_credits` and `regenerations_used` have existed since the schema
-- was imported and nothing has ever written them.
--
-- ⚠ AND THE CLIENT COULD WRITE THEM. The policy was `for all` with ownership in
-- both USING and WITH CHECK, so a signed-in owner could
-- `update generation_credits set regenerations_used = 0` and mint herself an
-- unlimited allowance. A meter the metered party can reset is not a meter. The
-- policy becomes select-only and the privileges go with it.

drop policy if exists "generation_credits_all_own" on public.generation_credits;

drop policy if exists generation_credits_select_own on public.generation_credits;
create policy generation_credits_select_own
  on public.generation_credits for select
  using (exists (select 1 from public.projects p
                  where p.id = generation_credits.project_id
                    and p.user_id = (select auth.uid())));

drop policy if exists generation_credits_insert_denied on public.generation_credits;
create policy generation_credits_insert_denied
  on public.generation_credits for insert with check (false);

drop policy if exists generation_credits_update_denied on public.generation_credits;
create policy generation_credits_update_denied
  on public.generation_credits for update using (false);

drop policy if exists generation_credits_delete_denied on public.generation_credits;
create policy generation_credits_delete_denied
  on public.generation_credits for delete using (false);

revoke insert, update, delete on public.generation_credits from authenticated, anon;
grant select on public.generation_credits to authenticated;

-- ⚠ ONE BRAND KIT PER PROJECT (`brand_kits_project_id_key`), so the per-project
-- credits row IS the per-kit allowance. Nothing here assumes otherwise, and if
-- that uniqueness is ever dropped this function is the first thing to revisit.
comment on column public.generation_credits.directions_generated is
  'Number of direction-generation RUNS taken, not directions produced. One run produces three directions.';
comment on column public.generation_credits.directions_limit is
  'Cap on generation runs for an ENTITLED owner. An unentitled owner is capped at one run regardless of what this says — see consume_generation_credit.';
comment on column public.generation_credits.regenerations_used is
  'Number of regeneration runs taken after the first generation.';
comment on column public.generation_credits.regenerations_limit is
  'Cap on regeneration runs for an ENTITLED owner. An unentitled owner is capped at one.';

create or replace function public.consume_generation_credit(p_brand_kit_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project     uuid;
  v_entitled    boolean;
  v_dir_limit   smallint;
  v_regen_limit smallint;
  v_consumed    boolean;
begin
  -- fail closed. Every reason to refuse — not signed in, not her kit, allowance
  -- spent — is the same answer to the only question the caller is asking:
  -- may I spend a model call?
  if (select auth.uid()) is null then
    return false;
  end if;

  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return false;
  end if;

  -- a project created before the credits trigger, or one whose row was lost,
  -- gets its allowance rather than an unlimited one
  insert into public.generation_credits (project_id) values (v_project)
  on conflict (project_id) do nothing;

  v_entitled := public.brand_kit_entitled(p_brand_kit_id);

  select case when v_entitled then gc.directions_limit    else 1::smallint end,
         case when v_entitled then gc.regenerations_limit else 1::smallint end
    into v_dir_limit, v_regen_limit
    from public.generation_credits gc
   where gc.project_id = v_project;

  -- ⚠ ONE STATEMENT. The UPDATE takes the row lock, and under READ COMMITTED a
  -- concurrent caller that was waiting re-evaluates this WHERE against the row
  -- as the winner left it. Two simultaneous POSTs cannot both pass: the second
  -- finds the allowance spent and updates nothing.
  --
  -- Reading the counters and then deciding — in SQL or in a Next route — is the
  -- race this exists to remove.
  update public.generation_credits gc
     set directions_generated =
           gc.directions_generated
           + case when gc.directions_generated < v_dir_limit then 1 else 0 end,
         regenerations_used =
           gc.regenerations_used
           + case when gc.directions_generated < v_dir_limit then 0 else 1 end
   where gc.project_id = v_project
     and (gc.directions_generated < v_dir_limit
          or gc.regenerations_used < v_regen_limit)
  returning true into v_consumed;

  return coalesce(v_consumed, false);
end
$$;

comment on function public.consume_generation_credit(uuid) is
  'Atomically spends one generation credit, or returns false having spent nothing. The first run draws on the generation allowance, later runs on the regeneration allowance. Calling this is the ONLY correct way to check: reading the counters and deciding is a race two concurrent requests both win.';

revoke execute on function public.consume_generation_credit(uuid) from public, anon;
grant execute on function public.consume_generation_credit(uuid) to authenticated, service_role;


-- ============================================================================
-- 8. Guard rails
-- ============================================================================
do $$
declare
  v_pol int;
begin
  -- the credits row can no longer be rewritten by the party being metered
  select count(*) into v_pol from pg_policies
   where schemaname = 'public' and tablename = 'generation_credits'
     and cmd <> 'SELECT' and qual is distinct from 'false'
     and coalesce(with_check, 'false') is distinct from 'false';
  if v_pol > 0 then
    raise exception 'generation_credits: % writable policy(ies) remain.', v_pol;
  end if;

  -- entitlement is written once
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.prosrc like '%''paid''%'
         and p.proname not in ('brand_kit_entitling_statuses')) > 0 then
    raise exception 'entitlement: a second function names the paid status literally.';
  end if;

  -- and it is never NULL, which is how a paywall leaks
  if public.brand_kit_entitled(null) is not false then
    raise exception 'brand_kit_entitled: a null kit id did not answer false.';
  end if;
  if public.brand_kit_is_owned(null) is not false then
    raise exception 'brand_kit_is_owned: a null kit id did not answer false.';
  end if;
  if public.consume_generation_credit(null) is not false then
    raise exception 'consume_generation_credit: a null kit id did not answer false.';
  end if;

  -- the append-only table refuses a client rewrite
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.purchase_status_events'::regclass
                    and tgname = 'purchase_status_events_no_rewrite') then
    raise exception 'purchase_status_events: the append-only trigger is missing.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger if exists enforce_direction_selection_entitlement on public.brand_kits;
--   drop function if exists public.enforce_direction_selection_entitlement();
--   drop function if exists public.brand_kit_select_direction(uuid, text);
--   drop function if exists public.consume_generation_credit(uuid);
--   drop policy if exists generation_credits_select_own    on public.generation_credits;
--   drop policy if exists generation_credits_insert_denied on public.generation_credits;
--   drop policy if exists generation_credits_update_denied on public.generation_credits;
--   drop policy if exists generation_credits_delete_denied on public.generation_credits;
--   create policy "generation_credits_all_own" on public.generation_credits for all
--     using (exists (select 1 from public.projects where projects.id = generation_credits.project_id
--                     and projects.user_id = auth.uid()))
--     with check (exists (select 1 from public.projects where projects.id = generation_credits.project_id
--                          and projects.user_id = auth.uid()));
--   grant insert, update, delete on public.generation_credits to authenticated;
--   -- restore site_spec_get, site_output_get, site_spec_set_target, site_spec_patch,
--   -- site_spec_reset, site_spec_fix_contrast and site_output_mark_copied from
--   -- 20260829120000 and earlier, each WITH its `set jit = 'off'` clause;
--   drop function if exists public.site_spec_entitlement_error(uuid);
--   drop function if exists public.brand_kit_entitled(uuid);
--   drop function if exists public.brand_kit_is_owned(uuid);
--   drop function if exists public.brand_kit_entitling_statuses();
--   drop function if exists public.purchase_status_before(uuid, text);
--   drop function if exists public.record_purchase_status_event(uuid, text, text, text, integer, timestamptz);
--   drop table if exists public.purchase_status_events;
--   drop function if exists public.purchase_status_events_append_only();
--   drop function if exists public.purchase_status_events_apply();
--   drop function if exists public.purchase_status_events_advance();
--   alter table public.purchases drop constraint purchases_status_check;
--   alter table public.purchases add constraint purchases_status_check
--     check (status = any (array['pending','paid','refunded','failed']));
--   alter table public.purchases drop constraint purchases_paid_at_check;
--   alter table public.purchases add constraint purchases_paid_at_check
--     check ((status = 'paid') = (paid_at is not null));
