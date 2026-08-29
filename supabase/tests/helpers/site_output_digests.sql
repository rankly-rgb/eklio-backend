-- ============================================================================
-- Regenerate the snapshot digests in 20260829104000_site_output.test.sql
-- ============================================================================
-- The output is a pure function of (spec, target), so the test pins it by
-- digest. When a change to the renderer or to the catalog copy is INTENDED,
-- run this and paste the rows into the `expected` array of that test.
--
--   psql "$DB_URL" -At -f supabase/tests/helpers/site_output_digests.sql
--
-- ⚠ Read the diff before you paste. The digest is not the point of the test;
-- the moment of looking at what moved is.
--
-- The fixture below must stay IDENTICAL to the one in the test file.
-- ============================================================================
select format('    [%s %s],',
              rpad(quote_literal(bt.id) || ',', 16),
              quote_literal(md5(public.site_spec_output_render(
                bt.label, public.site_spec_output(f.s, bt.id), true))))
  from public.builder_targets bt
  cross join (
    select jsonb_build_object(
      'primary_hex','#3B2C3A','secondary_hex','#4A5361','accent_hex','#C08A3E',
      'light_neutral_hex','#F3EDE4','dark_neutral_hex','#241B23','paper_hex','#FAF7F2',
      'type_pairing_id','cormorant_source',
      'heading_font','Cormorant Garamond','body_font','Source Sans 3',
      'google_fonts_url','https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap',
      'hero', jsonb_build_object(
        'overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.',
        'subhead','Therapy for high-performing adults who cannot switch off.',
        'cta_label','Book a consult','cta_target_url','https://elmandember.clientsecure.me'),
      'about_excerpt','I work mostly with professionals who look fine from outside. Much of that work sits with anxiety and burnout.',
      'practice_details', jsonb_build_object(
        'practice_name','Elm & Ember Therapy','license_label','LCSW','license_number','LC61234',
        'city','Portland','state','OR','email','hello@elmandember.com','phone','(503) 555-0123'),
      'pages', public.site_spec_default_pages(
                 array['Anxiety','Burnout'],
                 array['Professionals who look fine from outside']),
      'extra_instructions','Please keep fees off the home page. Tuesday and Thursday are the only open hours right now.',
      'target','lovable') as s
  ) f
 order by bt.sort_order;
