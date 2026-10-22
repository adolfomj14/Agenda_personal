-- Migración v2: notas con lienzo (texto, código, imágenes, dibujos...).
-- Ejecútala UNA vez en Supabase → SQL Editor. Es segura de repetir.
alter table public.notes add column if not exists canvas text not null default '[]';
alter table public.notes add column if not exists color  text not null default '#FFF59D';
alter table public.notes add column if not exists pinned integer not null default 0;
