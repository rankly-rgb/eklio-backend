-- ============================================================================
-- ⚠ « REVOKE … FROM PUBLIC » NE RETIRE RIEN À anon NI À authenticated
-- ============================================================================
--
-- Trouvé le 2026-09-27 : le test 20260911170458_function_surface échouait déjà
-- sur la fonction de trigger de 20260924150000, et s'arrêtait là. Débloqué, il
-- nomme quatre fonctions SECURITY DEFINER appelables par `anon` :
--
--   credit_remaining(uuid, text, date)   le quota de N'IMPORTE QUEL compte
--   drawable_count_for_kit(uuid)         la banque de N'IMPORTE QUEL kit
--   drawable_topics_for_kit(uuid, text)  idem, avec les sujets
--   release_stale_topic_assignments()    le balai, déclenchable par un anonyme
--
-- Les quatre migrations écrivaient `revoke all … from public`. Mais Supabase
-- accorde EXECUTE à `anon` et `authenticated` EXPLICITEMENT, par privilèges par
-- défaut : l'ACL portait `anon=X/postgres`, que révoquer PUBLIC ne touche pas.
-- La même leçon que 20260831090000, réapprise quatre fois en une semaine.
--
-- Les quatre appelants sont serveur, par la service_role : `lib/content/month/
-- server-ports.ts`, `draw-port.ts`, `app/api/cron/release-topics/route.ts`.
revoke all on function public.credit_remaining(uuid, text, date)    from public, anon, authenticated;
revoke all on function public.drawable_count_for_kit(uuid)          from public, anon, authenticated;
revoke all on function public.drawable_topics_for_kit(uuid, text)   from public, anon, authenticated;
revoke all on function public.release_stale_topic_assignments()     from public, anon, authenticated;

grant execute on function public.credit_remaining(uuid, text, date)  to service_role;
grant execute on function public.drawable_count_for_kit(uuid)        to service_role;
grant execute on function public.drawable_topics_for_kit(uuid, text) to service_role;
grant execute on function public.release_stale_topic_assignments()   to service_role;
