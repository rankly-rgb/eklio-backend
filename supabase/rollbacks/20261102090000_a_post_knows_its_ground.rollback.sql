-- Retour en arrière de 20261102090000_a_post_knows_its_ground.
--
-- ⚠ MÊME RÈGLE : la colonne naît avec l'aller, et le retour refuse de la retirer
-- si elle porte déjà une valeur.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'content_items' and column_name = 'card_ground'
  ) and exists (select 1 from public.content_items where card_ground is not null) then
    raise exception 'rollback 20261102090000 refusé : content_items.card_ground porte déjà des valeurs';
  end if;
end $$;

alter table public.content_items drop constraint if exists content_items_card_ground_known;
alter table public.content_items drop column if exists card_ground;
delete from supabase_migrations.schema_migrations where version = '20261102090000';
