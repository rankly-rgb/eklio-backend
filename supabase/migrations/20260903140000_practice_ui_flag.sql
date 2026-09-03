-- ============================================================================
-- Eklio — lot D1: practice_ui_enabled flag row
-- ============================================================================
-- app_settings already exists (RLS on, zero policy, anon/authenticated
-- revoked — service_role only, same lockdown as usp_similarity_threshold).
-- This migration adds exactly one row: the kill switch every D-lot route
-- reads server-side before rendering anything.
-- ============================================================================

insert into public.app_settings (key, value)
values ('practice_ui_enabled', 'false'::jsonb)
on conflict (key) do nothing;
