-- ============================================================================
-- Eklio — asset_catalog / brand_assets: widen `kind` beyond svg/png (Lot 4.4)
-- ============================================================================
-- Everything shipped so far (wordmarks, palette sheet, og image, the
-- monogram family) is `svg` or `png`. The rest of the Lot 4.4 catalogue
-- is not an image at all: `manifest_values_json` (this migration's first
-- consumer), and — named in POST_PURCHASE_BRIEF.md, coming in the migrations
-- right after this one — `palette_ase`, `tokens_json`, `colors_css`,
-- `email_signature_html`, `site_setup_md`, `brand_kit_zip`.
--
-- Widening the CHECK constraint once, here, for every kind the rest of the
-- catalogue will need, rather than reopening this same constraint five more
-- times across the following migrations.
--
-- The brand-assets storage bucket's `allowed_mime_types` (set in
-- 20260903090000_brand_asset_storage.sql) gets the matching widen: a
-- kind this migration allows into asset_catalog but that Storage would
-- still reject on upload is a kind that can never actually ship.
--
-- `.ase` (Adobe Swatch Exchange) has no IANA-registered MIME type;
-- `application/octet-stream` is what browsers and Adobe's own tooling treat
-- it as in practice — not a real standard, just the honest "binary, no
-- better answer exists" type.
-- ============================================================================

alter table public.asset_catalog
  drop constraint asset_catalog_kind_check;
alter table public.asset_catalog
  add constraint asset_catalog_kind_check
  check (kind in ('svg', 'png', 'json', 'css', 'ase', 'html', 'zip'));

alter table public.brand_assets
  drop constraint brand_assets_kind_check;
alter table public.brand_assets
  add constraint brand_assets_kind_check
  check (kind in ('svg', 'png', 'json', 'css', 'ase', 'html', 'zip'));

update storage.buckets
   set allowed_mime_types = array[
     'image/svg+xml', 'image/png',
     'application/json', 'text/css', 'application/octet-stream',
     'text/html', 'application/zip'
   ]
 where id = 'brand-assets';


-- ============================================================================
-- DOWN
-- ============================================================================
--   update storage.buckets set allowed_mime_types = array['image/svg+xml', 'image/png'] where id = 'brand-assets';
--   alter table public.brand_assets drop constraint brand_assets_kind_check;
--   alter table public.brand_assets add constraint brand_assets_kind_check check (kind in ('svg', 'png'));
--   alter table public.asset_catalog drop constraint asset_catalog_kind_check;
--   alter table public.asset_catalog add constraint asset_catalog_kind_check check (kind in ('svg', 'png'));
-- ============================================================================
