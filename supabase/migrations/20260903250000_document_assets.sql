-- ============================================================================
-- Eklio — asset_catalog: email signature, site setup, the whole-kit zip
-- (Lot 4.4, "Document" — the last group in the catalogue)
-- ============================================================================
-- `site_setup_md` needs a kind this schema doesn't have yet (`md`) — widened
-- here, same reasoning as 20260903210000's widen: cheaper to add the one
-- kind this lot actually needs than to leave the constraint half-done.
--
-- brand_kit_zip bundles every other key in the catalogue (rendered fresh
-- each time it's requested, per-key renderer functions, zipped together —
-- eklio-frontend's registry.ts) plus a README.txt. It is deliberately the
-- LAST sort_order: nothing else in the catalogue depends on it existing.
-- ============================================================================

alter table public.asset_catalog
  drop constraint asset_catalog_kind_check;
alter table public.asset_catalog
  add constraint asset_catalog_kind_check
  check (kind in ('svg', 'png', 'json', 'css', 'ase', 'html', 'zip', 'md'));

alter table public.brand_assets
  drop constraint brand_assets_kind_check;
alter table public.brand_assets
  add constraint brand_assets_kind_check
  check (kind in ('svg', 'png', 'json', 'css', 'ase', 'html', 'zip', 'md'));

update storage.buckets
   set allowed_mime_types = array[
     'image/svg+xml', 'image/png',
     'application/json', 'text/css', 'application/octet-stream',
     'text/html', 'application/zip', 'text/markdown'
   ]
 where id = 'brand-assets';

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values
  (
    'email_signature_html',
    'document',
    'Email signature (HTML)',
    'Paste this into your email client''s signature settings — Gmail and Outlook both take it.',
    'html',
    null,
    null,
    'starter',
    31
  ),
  (
    'email_signature_png',
    'document',
    'Email signature (image)',
    'A fallback image version, for an email client that won''t take HTML.',
    'png',
    640,
    220,
    'starter',
    32
  ),
  (
    'site_setup_md',
    'document',
    'Site setup instructions',
    'Step-by-step instructions for putting your site together, in Markdown.',
    'md',
    null,
    null,
    'starter',
    33
  ),
  (
    'brand_kit_zip',
    'document',
    'Everything, zipped',
    'Every file in your brand kit, in one download, with a README.',
    'zip',
    null,
    null,
    'starter',
    34
  );


-- ============================================================================
-- DOWN
-- ============================================================================
--   delete from public.asset_catalog where key in ('email_signature_html', 'email_signature_png', 'site_setup_md', 'brand_kit_zip');
--   update storage.buckets set allowed_mime_types = array['image/svg+xml', 'image/png', 'application/json', 'text/css', 'application/octet-stream', 'text/html', 'application/zip'] where id = 'brand-assets';
--   alter table public.brand_assets drop constraint brand_assets_kind_check;
--   alter table public.brand_assets add constraint brand_assets_kind_check check (kind in ('svg', 'png', 'json', 'css', 'ase', 'html', 'zip'));
--   alter table public.asset_catalog drop constraint asset_catalog_kind_check;
--   alter table public.asset_catalog add constraint asset_catalog_kind_check check (kind in ('svg', 'png', 'json', 'css', 'ase', 'html', 'zip'));
-- ============================================================================
