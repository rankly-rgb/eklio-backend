-- Retour en arrière de 20261101090000_a_post_knows_its_drawing.
--
-- ⚠ IL NE DÉTRUIT RIEN QUI EXISTAIT AVANT L'ALLER. La colonne et sa contrainte
-- naissent avec la migration ; le retour les retire. Et il REFUSE de le faire si
-- la colonne porte déjà une valeur : ce serait alors une perte de données, et
-- la décision revient à quelqu'un, pas à un script.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'content_items' and column_name = 'illustration_key'
  ) and exists (select 1 from public.content_items where illustration_key is not null) then
    raise exception 'rollback 20261101090000 refusé : content_items.illustration_key porte déjà des valeurs';
  end if;
end $$;

alter table public.content_items drop constraint if exists content_items_illustration_key_shape;
alter table public.content_items drop column if exists illustration_key;
delete from supabase_migrations.schema_migrations where version = '20261101090000';
