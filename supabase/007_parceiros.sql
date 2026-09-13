-- =====================================================================
-- 007 — parceiros: rede por estado/cidade (corretor, imobiliária, drone,
-- arrendamento...). Cadastro manual pelo console, seção "Parceiros".
-- Mesma regra do resto do console: leitura para quem está ativo;
-- criar/editar para dono e corretor; apagar só o dono (evita acidente).
-- Rodar inteiro no SQL Editor do Supabase. Idempotente.
-- =====================================================================

create table if not exists public.parceiros (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  tipo text not null default 'corretor' check (tipo in ('corretor','imobiliaria','drone','arrendamento','outro')),
  uf char(2) not null,
  cidade text not null default '',
  telefone text not null default '',
  email text not null default '',
  observacao text not null default '',
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id)
);

alter table public.parceiros enable row level security;

drop policy if exists ler on public.parceiros;
create policy ler on public.parceiros
  for select to authenticated using (public.eu_ativo());

drop policy if exists criar on public.parceiros;
create policy criar on public.parceiros
  for insert to authenticated with check (public.posso_editar());

drop policy if exists editar on public.parceiros;
create policy editar on public.parceiros
  for update to authenticated using (public.posso_editar())
  with check (public.posso_editar());

drop policy if exists apagar on public.parceiros;
create policy apagar on public.parceiros
  for delete to authenticated using (public.sou_dono());
