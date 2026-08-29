-- ============================================================================
-- Eklio — the entitlement RPCs, and who is allowed to dial them
-- ============================================================================
-- Follows `20260829123000_entitlement_and_generation_credits.sql`.
--
-- Nothing here changes an answer. It changes who may ask.
--
-- ⚠ `brand_kit_select_direction` is a WRITE, and it was executable by `anon`.
-- It refuses an anonymous caller — `auth.uid()` is NULL, so the gate returns
-- `unauthenticated` — but a write RPC that anonymous callers may invoke is a
-- write RPC in the anonymous OpenAPI surface, and "it refuses" is a property of
-- today's body rather than of the grant. The grant is the durable statement.
--
-- The same for the three entitlement readers: an anonymous caller can only ever
-- be told `false`, so nothing leaks, but nothing is served by offering it
-- either. These questions are about a signed-in person's own kit.
--
-- This is the default-privileges behaviour of a Supabase project, not an
-- oversight in the previous migration: `alter default privileges ... grant all
-- on functions to anon` applies to every function created afterwards. Any new
-- RPC in this repo inherits it and has to say otherwise on purpose.

revoke execute on function public.brand_kit_select_direction(uuid, text)  from public, anon;
revoke execute on function public.brand_kit_entitled(uuid)                from public, anon;
revoke execute on function public.brand_kit_is_owned(uuid)                from public, anon;
revoke execute on function public.site_spec_entitlement_error(uuid)       from public, anon;

grant execute on function public.brand_kit_select_direction(uuid, text)   to authenticated;
grant execute on function public.brand_kit_entitled(uuid)                 to authenticated, service_role;
grant execute on function public.brand_kit_is_owned(uuid)                 to authenticated, service_role;
grant execute on function public.site_spec_entitlement_error(uuid)        to authenticated, service_role;

comment on function public.brand_kit_entitled(uuid) is
  'THE definition of "this caller has paid for this brand kit", and the only correct way for a route that reads brand_kits directly — the PDF route, the kit page — to ask the question. Everything that gates on payment calls this and nothing re-states it. auth.uid()-scoped: false for a kit that is not the caller''s, false when there is no caller, false when it is hers and unbought. Those last two are deliberately the same answer, because telling a caller apart "not yours" from "yours, unpaid" is how id-probing learns which kits exist.';


-- ============================================================================
-- Guard rail
-- ============================================================================
do $$
declare fn text;
begin
  foreach fn in array array[
    'brand_kit_select_direction(uuid,text)', 'brand_kit_entitled(uuid)',
    'brand_kit_is_owned(uuid)', 'site_spec_entitlement_error(uuid)',
    'consume_generation_credit(uuid)'
  ] loop
    if has_function_privilege('anon', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'anon can still execute %', fn;
    end if;
    if not has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated can no longer execute %', fn;
    end if;
  end loop;

  -- ⚠ and the paywall is unmoved: the seven gated entries stay callable, since
  -- they are the ones that must answer `payment_required` rather than 404.
  foreach fn in array array[
    'site_spec_get(uuid)', 'site_output_get(uuid,text,text)',
    'site_spec_patch(uuid,jsonb)', 'site_spec_reset(uuid,text)',
    'site_spec_set_target(uuid,text)', 'site_spec_fix_contrast(uuid,text)',
    'site_output_mark_copied(uuid)'
  ] loop
    if not has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated can no longer execute %', fn;
    end if;
  end loop;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   grant execute on function public.brand_kit_select_direction(uuid, text) to anon;
--   grant execute on function public.brand_kit_entitled(uuid)               to anon;
--   grant execute on function public.brand_kit_is_owned(uuid)               to anon;
--   grant execute on function public.site_spec_entitlement_error(uuid)      to anon;
