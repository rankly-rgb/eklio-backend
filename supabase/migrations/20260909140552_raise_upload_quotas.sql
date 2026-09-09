-- ============================================================================
-- Eklio — the upload quotas go up, and they stay global
-- ============================================================================
-- ⚠ THESE ARE NOT A TIER. `own_uploads` sits at the lowest tier in
-- `lib/billing/surfaces.ts` and stays there, by decision: her own files are
-- the substitute for the PORTRAIT Eklio refuses to generate — no faces, ever,
-- in `lib/images/config.ts`'s master constraints — and rationing a customer's
-- own photographs to sell her a bigger plan is petty.
--
-- What bounds them is a quota, one quota, the same for everyone:
--
--   user_uploads_kit_max_files    24 →  60
--   user_uploads_kit_max_bytes    50 MiB → 200 MiB   (52428800 → 209715200)
--   user_uploads_max_bytes        10 MiB, unchanged  (per FILE)
--
-- 24 files and 50 MiB was sized before anyone had used it. A therapist with a
-- headshot session, a few room photographs and a logo she already had is at
-- the old ceiling without doing anything unusual — and a 10 MiB per-file cap
-- means five photographs could reach half of it.
--
-- The per-file cap does NOT move. It is not about volume: it is what keeps a
-- single accidental upload of a 400 MiB video from being the thing that fills
-- her kit.
-- ============================================================================

update public.app_settings set value = '60'        where key = 'user_uploads_kit_max_files';
update public.app_settings set value = '209715200' where key = 'user_uploads_kit_max_bytes';

do $$
declare
  v_files integer;
  v_kit   bigint;
  v_file  bigint;
begin
  select (value #>> '{}')::integer into v_files from public.app_settings
   where key = 'user_uploads_kit_max_files';
  select (value #>> '{}')::bigint  into v_kit   from public.app_settings
   where key = 'user_uploads_kit_max_bytes';
  select (value #>> '{}')::bigint  into v_file  from public.app_settings
   where key = 'user_uploads_max_bytes';

  if v_files <> 60 or v_kit <> 209715200 then
    raise exception 'upload quotas did not land: files=%, kit_bytes=%', v_files, v_kit;
  end if;

  -- The per-file cap is unchanged, and it must stay well under the kit's.
  if v_file <> 10485760 then
    raise exception 'the per-file cap moved: %', v_file;
  end if;
  if v_file * 4 > v_kit then
    raise exception 'a kit can hold fewer than four files at the per-file cap';
  end if;
end $$;
