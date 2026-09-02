-- ============================================================================
-- Eklio — the button size floor was 0.66px short of the threshold it cited
-- ============================================================================
-- Follows `20260829120000_practitioner_name_and_voice_guide.sql`.
--
-- `20260829119000` put a size floor in the output because the deliverable makes
-- a claim the builder cannot check: `cta_label_on_primary` is measured at the
-- AA threshold for LARGE text, and large text is a size, not a colour. The
-- wording it shipped was `18px bold, or 24px if it is not bold`.
--
-- ⚠ WCAG's large-text threshold is 14pt bold — **18.66px**, not 18px. At 18px
-- bold the label is BELOW the threshold the contrast check assumed, so the
-- sentence asked a therapist to do something that does not produce the result
-- it implies. The frontend refused to tell her the instruction made her button
-- compliant, correctly.
--
-- The floor becomes `24px, or 19px if bold`. Nineteen clears 18.66 with a whole
-- pixel — a round number to type into Squarespace, and no rounding argument
-- about a fractional one. Regular text leads, because it is the case that does
-- not depend on remembering to set a weight.
--
-- Template rows only. Nothing in the logic changes: no function is replaced, no
-- pair is re-measured, no colour moves. The size floor was always a claim in
-- copy — which is exactly why it lives in `site_output_templates`.
-- ============================================================================

-- >>> CTA SIZE FLOOR CORRECTION (mirrored verbatim in supabase/seed.sql) >>>

update public.site_output_templates set body =
  'Do not set the call-to-action label below 24px, or 19px if it is bold. The button''s two colors were checked for text at that size; keep the label at or above it and the pair stays legible.'
 where id = 'all.constraint.cta_min_size';

update public.site_output_templates set body =
  '24px, or 19px if bold'
 where id = 'all.sheet.value_cta_min_size';

-- <<< CTA SIZE FLOOR CORRECTION <<<


-- ============================================================================
-- Guard rail
-- ============================================================================
do $$
declare f jsonb := public.site_output_fragments(null);
begin
  -- ⚠ the number that was wrong must not come back
  if (f->>'constraint.cta_min_size') like '%18px%'
     or (f->>'sheet.value_cta_min_size') like '%18px%' then
    raise exception 'cta size floor: 18px is below WCAG large-text (18.66px) and must not be cited.';
  end if;
  if (f->>'constraint.cta_min_size') not like '%24px%'
     or (f->>'constraint.cta_min_size') not like '%19px%' then
    raise exception 'cta size floor: the constraint no longer states both sizes.';
  end if;
  if (f->>'sheet.value_cta_min_size') <> '24px, or 19px if bold' then
    raise exception 'cta size floor: the sheet value reads "%"',
      f->>'sheet.value_cta_min_size';
  end if;
  -- and both numbers clear the thresholds they stand for
  if 19 < 18.66 or 24 < 24 then
    raise exception 'cta size floor: a stated size does not clear its threshold.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   update public.site_output_templates set body =
--     'Do not set the call-to-action label below 18px bold, or 24px if it is not bold. The button''s two colors were checked for text at that size; below it the same pair stops being legible enough.'
--    where id = 'all.constraint.cta_min_size';
--   update public.site_output_templates set body = '18px bold, or 24px if it is not bold'
--    where id = 'all.sheet.value_cta_min_size';
