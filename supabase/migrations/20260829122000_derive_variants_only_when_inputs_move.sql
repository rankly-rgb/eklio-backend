-- ============================================================================
-- Eklio — stop re-deriving four colours on every write
-- ============================================================================
-- Follows `20260829121000_cta_size_floor_correction.sql`.
--
-- MEASURED FIRST. `site_spec_patch` sat at 137–144 ms against a 150 ms budget,
-- and the number did not move when the spec got six times bigger: a deliberately
-- heavy spec — four pages, all 26 allowed sections, every text field at its
-- 800-character limit, a 135 KB envelope — patched in the same 137–144 ms as a
-- four-page one. So the cost was never proportional to her content. It was flat.
--
-- `auto_explain` with nested statements found it: three ~39 ms executions of the
-- 91-candidate lightness walk in `site_spec_suggest_hex`, inside a PATCH that
-- only changed `about_excerpt`.
--
-- ⚠ `maintain_site_spec_text_variants` is a BEFORE trigger that recomputed
-- `primary_text_hex`, `secondary_text_hex`, `accent_text_hex` and `cta_ink_hex`
-- on EVERY update, whatever changed. Editing a headline re-ran four colour
-- searches whose inputs had not moved. On a family whose brand colours all need
-- a variant — four of the six shipped ones — that is ~120 ms of the 140.
--
-- This is the same shape as the voice section rendering twice per envelope:
-- derived work repeated because nothing said when to skip it. The fix is to say
-- when. Each variant is recomputed only when its own inputs changed; otherwise
-- the stored value is carried forward.
--
-- ⚠ IT IS STILL THE TRIGGER THAT DECIDES. The `else` branch assigns
-- `old.<column>`, it does not leave `new.<column>` alone — a client that tries
-- to write a variant directly still has it overwritten, which is the whole
-- reason these are trigger-maintained. The values are unchanged: same inputs,
-- same function, same result. The snapshot digests do not move.
-- ============================================================================

create or replace function public.maintain_site_spec_text_variants()
returns trigger
language plpgsql
set search_path = ''
set jit = 'off'
as $$
begin
  -- primary and accent and secondary all read against the page
  if tg_op = 'INSERT'
     or new.paper_hex is distinct from old.paper_hex
     or new.primary_hex is distinct from old.primary_hex
     or old.primary_text_hex is null then
    new.primary_text_hex := public.site_spec_text_variant(new.primary_hex, new.paper_hex);
  else
    new.primary_text_hex := old.primary_text_hex;
  end if;

  if tg_op = 'INSERT'
     or new.paper_hex is distinct from old.paper_hex
     or new.secondary_hex is distinct from old.secondary_hex
     or old.secondary_text_hex is null then
    new.secondary_text_hex := public.site_spec_text_variant(new.secondary_hex, new.paper_hex);
  else
    new.secondary_text_hex := old.secondary_text_hex;
  end if;

  if tg_op = 'INSERT'
     or new.paper_hex is distinct from old.paper_hex
     or new.accent_hex is distinct from old.accent_hex
     or old.accent_text_hex is null then
    new.accent_text_hex := public.site_spec_text_variant(new.accent_hex, new.paper_hex);
  else
    new.accent_text_hex := old.accent_text_hex;
  end if;

  -- measured against the primary fill, not the page: this one is a label
  if tg_op = 'INSERT'
     or new.primary_hex is distinct from old.primary_hex
     or new.dark_neutral_hex is distinct from old.dark_neutral_hex
     or old.cta_ink_hex is null then
    new.cta_ink_hex := public.site_spec_cta_ink(new.primary_hex, new.dark_neutral_hex);
  else
    new.cta_ink_hex := old.cta_ink_hex;
  end if;

  return new;
end
$$;

comment on function public.maintain_site_spec_text_variants() is
  'Derives the three text variants and the CTA ink. Each is recomputed only when its own inputs move; otherwise the stored value is carried forward. A client can never set one: the skip path assigns the OLD value, not whatever was submitted.';


-- ============================================================================
-- Guard rail — the values must not have changed, only the work
-- ============================================================================
do $$
declare
  n_wrong int;
begin
  -- every existing row still agrees with a full recompute
  select count(*) into n_wrong
    from public.site_specs s
   where s.primary_text_hex   is distinct from public.site_spec_text_variant(s.primary_hex,   s.paper_hex)
      or s.secondary_text_hex is distinct from public.site_spec_text_variant(s.secondary_hex, s.paper_hex)
      or s.accent_text_hex    is distinct from public.site_spec_text_variant(s.accent_hex,    s.paper_hex)
      or s.cta_ink_hex        is distinct from public.site_spec_cta_ink(s.primary_hex, s.dark_neutral_hex);
  if n_wrong > 0 then
    raise exception 'derived variants: % row(s) disagree with a full recompute; the skip logic is wrong.', n_wrong;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   create or replace function public.maintain_site_spec_text_variants()
--   returns trigger language plpgsql set search_path = '' set jit = 'off' as $$
--   begin
--     new.primary_text_hex   := public.site_spec_text_variant(new.primary_hex,   new.paper_hex);
--     new.secondary_text_hex := public.site_spec_text_variant(new.secondary_hex, new.paper_hex);
--     new.accent_text_hex    := public.site_spec_text_variant(new.accent_hex,    new.paper_hex);
--     new.cta_ink_hex        := public.site_spec_cta_ink(new.primary_hex, new.dark_neutral_hex);
--     return new;
--   end $$;
