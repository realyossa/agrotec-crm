-- =====================================================================
-- Console de Leads v2 — esquema inicial (Agrotec)
-- Rodar inteiro no SQL Editor do Supabase. Idempotente onde possível.
--
-- Seis entidades (proposta, seção 5): visitantes, sessoes, eventos,
-- pessoas, negocios, atividades. Mais perfis (quem usa o console) e
-- config (funis/etapas/corretores lidos pelo console).
--
-- Regra que vale em tudo: o SITE só ESCREVE via função da Netlify com a
-- chave de serviço (service_role). O CONSOLE lê e edita autenticado, com
-- RLS. Ninguém anônimo lê nada.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- perfis: um por usuário do Auth. Criado por gatilho no primeiro login.
-- papel: dono (tudo), corretor (fila, pipeline, pessoa), leitura (só vê).
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null default '',
  email text not null default '',
  papel text not null default 'corretor' check (papel in ('dono','corretor','leitura')),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create or replace function public.criar_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, email, nome)
  values (new.id, coalesce(new.email,''), coalesce(new.raw_user_meta_data->>'nome', split_part(coalesce(new.email,''),'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.criar_perfil();

-- ---------------------------------------------------------------------
-- config: chave/valor lido pelo console (funis, etapas, motivos de perda,
-- horário de atendimento, SLA). Editável só pelo dono.
-- ---------------------------------------------------------------------
create table if not exists public.config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);

insert into public.config (chave, valor) values
 ('cliente', '{"nome":"Agrotec Imobiliária","curto":"Agrotec","site":"https://agrotecimobiliarianoagro.com.br"}'),
 ('funis', '{
   "compra":  {"rotulo":"Compra",  "etapas":["Novo","Em contato","Visita agendada","Proposta enviada","Fechado","Perdido"]},
   "venda":   {"rotulo":"Venda",   "etapas":["Novo","Em contato","Visita a propriedade","Documentacao","Em divulgacao","Vendido","Perdido"]},
   "servico": {"rotulo":"Serviço", "etapas":["Novo","Em contato","Orcamento enviado","Agendado","Executado","Perdido"]}
 }'),
 ('etapas_finais', '{"ganhou":["Fechado","Vendido","Executado"],"perdeu":["Perdido"]}'),
 ('motivos_perda', '["Sem resposta","Preço","Região","Já comprou / vendeu","Não era o serviço","Dado inválido","Outro"]'),
 ('tipos', '["Sitio","Chacara","Fazenda","Arrendamento","Avaliacao","Pericia","Georreferenciamento","Drone","Regularizacao","Venda","Outro"]'),
 ('sla', '{"minutos":30,"horario":{"inicio":"08:00","fim":"18:30","dias":[1,2,3,4,5,6]},"fuso":"America/Sao_Paulo"}')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- visitantes: quem esteve no site, identificado ou não.
-- id = visitante_id gerado no navegador (localStorage, 90 dias como hoje).
-- ---------------------------------------------------------------------
create table if not exists public.visitantes (
  id text primary key,
  criado_em timestamptz not null default now(),
  ultima_visita timestamptz not null default now(),
  visitas int not null default 1,
  pessoa_id uuid,
  primeira_origem jsonb,          -- {tipo, motor, via, referrer, utm_source, utm_medium, campanha, landing}
  dispositivo text,
  navegador text,
  sistema text,
  idioma text,
  fuso text,
  tela text,
  cidade_ip text, uf_ip text, pais_ip text,
  ua text
);

create table if not exists public.sessoes (
  id text primary key,
  visitante_id text not null references public.visitantes(id) on delete cascade,
  iniciada_em timestamptz not null default now(),
  ultima_em timestamptz not null default now(),
  origem jsonb,                    -- origem desta sessão (pode diferir da primeira)
  landing text,
  paginas int not null default 0,
  cliques_contato int not null default 0,
  dispositivo text
);
create index if not exists sessoes_visitante on public.sessoes(visitante_id);

-- ---------------------------------------------------------------------
-- eventos: cada clique, view, submit. Nome vem do registro eventos.json
-- (superficie:objeto_acao). Tabela maior e mais barata.
-- ---------------------------------------------------------------------
create table if not exists public.eventos (
  id bigserial primary key,
  ts timestamptz not null default now(),
  nome text not null,
  visitante_id text,
  sessao_id text,
  pessoa_id uuid,
  pagina text,
  secao text,
  rotulo text,
  interesse text,
  funil text,
  cidade_pagina text,
  origem_tipo text,                -- ia | busca | social | direto | referencia | campanha | interno
  origem_motor text,               -- ChatGPT, Perplexity, Google, Bing, ...
  origem_via text,                 -- referrer | utm | ambos
  dispositivo text,
  props jsonb not null default '{}'::jsonb
);
create index if not exists eventos_ts on public.eventos(ts desc);
create index if not exists eventos_nome_ts on public.eventos(nome, ts desc);
create index if not exists eventos_visitante on public.eventos(visitante_id, ts);
create index if not exists eventos_pessoa on public.eventos(pessoa_id) where pessoa_id is not null;

-- ---------------------------------------------------------------------
-- pessoas: quem se identificou. Chave natural: telefone (dígitos).
-- ---------------------------------------------------------------------
create table if not exists public.pessoas (
  id uuid primary key default gen_random_uuid(),
  codigo text unique,                       -- LEAD-0001 (compat com a planilha)
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  nome text not null default '',
  telefone text,                            -- só dígitos, com 55
  telefone_fmt text,
  email text,
  cidade text, regiao text,
  cidade_ip text, uf_ip text,
  visitante_id text,
  esteve_no_site boolean not null default false,   -- tinha eventos ANTES de se identificar
  origem_primeira jsonb,                    -- primeira visita conhecida
  origem_conversao jsonb,                   -- a sessão em que se identificou
  visitas int, tempo_site text, leitura int,
  trajeto text[],
  cidades_vistas text[],
  aceite_lgpd_em timestamptz, aceite_texto text,
  observacoes text,
  legado jsonb                              -- linha original da planilha, quando migrado
);
create unique index if not exists pessoas_telefone on public.pessoas(telefone) where telefone is not null and telefone <> '';
create index if not exists pessoas_criado on public.pessoas(criado_em desc);

-- código sequencial LEAD-0001 sem repetir mesmo depois de apagar
create sequence if not exists public.seq_codigo_pessoa;
create or replace function public.proximo_codigo()
returns text language sql as $$
  select 'LEAD-' || lpad(nextval('public.seq_codigo_pessoa')::text, 4, '0');
$$;

-- ---------------------------------------------------------------------
-- negocios: o que a pessoa quer AGORA. É o cartão do pipeline.
-- ---------------------------------------------------------------------
create table if not exists public.negocios (
  id uuid primary key default gen_random_uuid(),
  pessoa_id uuid not null references public.pessoas(id) on delete cascade,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  funil text not null default 'compra' check (funil in ('compra','venda','servico')),
  etapa text not null default 'Novo',
  tipo text,                                -- Sitio, Chacara, Fazenda, Georreferenciamento...
  interesse text,                           -- texto livre declarado
  cidade text, regiao text,
  faixa_valor text, area_ha numeric,
  descricao text,
  corretor_id uuid references public.perfis(id),
  motivo_perda text,
  valor numeric, comissao numeric,
  fechado_em timestamptz,
  primeiro_contato_em timestamptz,          -- primeira atividade humana
  ultima_atividade_em timestamptz,
  proximo_passo text, vence_em timestamptz,
  origem_evento text,                       -- nome do evento que criou (cta:hero_whatsapp_click)
  origem_pagina text, origem_rotulo text,
  pontuacao int not null default 0,
  legado jsonb
);
create index if not exists negocios_pessoa on public.negocios(pessoa_id);
create index if not exists negocios_etapa on public.negocios(funil, etapa);
create index if not exists negocios_criado on public.negocios(criado_em desc);

-- ---------------------------------------------------------------------
-- atividades: tudo que um humano fez ou vai fazer sobre um negócio.
-- tipo: ligacao | whatsapp | visita | nota | repasse | etapa | tarefa | sistema
-- ---------------------------------------------------------------------
create table if not exists public.atividades (
  id bigserial primary key,
  negocio_id uuid references public.negocios(id) on delete cascade,
  pessoa_id uuid references public.pessoas(id) on delete cascade,
  em timestamptz not null default now(),
  tipo text not null,
  quem uuid references public.perfis(id),
  texto text,
  resultado text,
  meta jsonb not null default '{}'::jsonb
);
create index if not exists atividades_negocio on public.atividades(negocio_id, em desc);
create index if not exists atividades_pessoa on public.atividades(pessoa_id, em desc);

create table if not exists public.fotos (
  id bigserial primary key,
  negocio_id uuid references public.negocios(id) on delete cascade,
  pessoa_id uuid references public.pessoas(id) on delete cascade,
  em timestamptz not null default now(),
  drive_id text, arquivo text, tipo text, tamanho_kb int, dimensoes text
);

-- ---------------------------------------------------------------------
-- gatilhos de manutenção
-- ---------------------------------------------------------------------
create or replace function public.tocar_atualizado()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end $$;

drop trigger if exists negocios_tocar on public.negocios;
create trigger negocios_tocar before update on public.negocios
  for each row execute function public.tocar_atualizado();
drop trigger if exists pessoas_tocar on public.pessoas;
create trigger pessoas_tocar before update on public.pessoas
  for each row execute function public.tocar_atualizado();

-- Toda atividade humana atualiza o negócio: primeiro contato e última atividade.
create or replace function public.apos_atividade()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.negocio_id is not null and new.tipo in ('ligacao','whatsapp','visita','nota','repasse') then
    update public.negocios
       set ultima_atividade_em = greatest(coalesce(ultima_atividade_em, new.em), new.em),
           primeiro_contato_em = coalesce(primeiro_contato_em, new.em)
     where id = new.negocio_id;
  end if;
  return new;
end $$;
drop trigger if exists atividades_apos on public.atividades;
create trigger atividades_apos after insert on public.atividades
  for each row execute function public.apos_atividade();

-- Mudança de etapa vira atividade automática (auditoria de quem moveu).
create or replace function public.registrar_etapa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.etapa is distinct from old.etapa then
    insert into public.atividades (negocio_id, pessoa_id, tipo, quem, texto, meta)
    values (new.id, new.pessoa_id, 'etapa', auth.uid(),
            old.etapa || ' → ' || new.etapa,
            jsonb_build_object('de', old.etapa, 'para', new.etapa, 'motivo', new.motivo_perda));
    if new.etapa in (select jsonb_array_elements_text(valor->'ganhou') from public.config where chave='etapas_finais')
       or new.etapa in (select jsonb_array_elements_text(valor->'perdeu') from public.config where chave='etapas_finais') then
      new.fechado_em = coalesce(new.fechado_em, now());
    else
      new.fechado_em = null;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists negocios_etapa on public.negocios;
create trigger negocios_etapa before update on public.negocios
  for each row execute function public.registrar_etapa();

-- ---------------------------------------------------------------------
-- RLS: só usuário autenticado com perfil ativo lê; corretor edita
-- negocios/atividades/pessoas; dono edita config e perfis. O site grava
-- pela chave de serviço, que ignora RLS.
-- ---------------------------------------------------------------------
create or replace function public.eu_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo);
$$;
create or replace function public.sou_dono()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo and papel = 'dono');
$$;
create or replace function public.posso_editar()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo and papel in ('dono','corretor'));
$$;

do $$
declare t text;
begin
  foreach t in array array['perfis','config','visitantes','sessoes','eventos','pessoas','negocios','atividades','fotos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists ler on public.%I', t);
    execute format('create policy ler on public.%I for select to authenticated using (public.eu_ativo())', t);
  end loop;
end $$;

drop policy if exists editar on public.negocios;
create policy editar on public.negocios for update to authenticated using (public.posso_editar()) with check (public.posso_editar());
drop policy if exists criar on public.negocios;
create policy criar on public.negocios for insert to authenticated with check (public.posso_editar());
drop policy if exists editar on public.pessoas;
create policy editar on public.pessoas for update to authenticated using (public.posso_editar()) with check (public.posso_editar());
drop policy if exists criar on public.pessoas;
create policy criar on public.pessoas for insert to authenticated with check (public.posso_editar());
drop policy if exists criar on public.atividades;
create policy criar on public.atividades for insert to authenticated with check (public.posso_editar() and (quem is null or quem = auth.uid()));
drop policy if exists editar on public.config;
create policy editar on public.config for all to authenticated using (public.sou_dono()) with check (public.sou_dono());
drop policy if exists editar on public.perfis;
create policy editar on public.perfis for update to authenticated using (public.sou_dono() or id = auth.uid()) with check (public.sou_dono() or id = auth.uid());

-- ---------------------------------------------------------------------
-- Views para o console (todas respeitam RLS por security_invoker)
-- ---------------------------------------------------------------------

-- Série diária: cliques de contato, formulários enviados, pessoas novas.
-- "Clique de contato" = todo evento cujo nome termina em _click nas
-- superfícies de contato, ou submit de formulário/portão/popup.
create or replace view public.v_serie_diaria with (security_invoker = true) as
select d::date as dia,
  count(e.id) filter (where e.nome ~ '^(cta|rodape|menu|flutuante|card|tel|mail|mapa):.*_click$') as cliques_contato,
  count(e.id) filter (where e.nome ~ '^(form|portao|popup):.*_submit$') as formularios,
  count(e.id) filter (where e.nome = 'pagina:view') as visualizacoes,
  count(distinct e.visitante_id) filter (where e.nome = 'pagina:view') as visitantes,
  count(e.id) filter (where e.origem_tipo = 'ia' and e.nome ~ '_click$|_submit$') as cliques_ia
from generate_series(now()::date - interval '59 days', now()::date, interval '1 day') d
left join public.eventos e on e.ts::date = d::date
group by d order by d;

create or replace view public.v_pessoas_por_dia with (security_invoker = true) as
select criado_em::date as dia, count(*) as pessoas,
       count(*) filter (where esteve_no_site) as com_historico,
       count(*) filter (where (origem_conversao->>'tipo') = 'ia') as via_ia
from public.pessoas group by 1 order by 1;

-- Fila: cada negócio aberto com relógio de SLA e quem cuida.
create or replace view public.v_fila with (security_invoker = true) as
select n.*, p.nome as pessoa_nome, p.telefone, p.telefone_fmt, p.codigo, p.cidade as pessoa_cidade,
       p.cidade_ip, p.esteve_no_site, p.origem_conversao, p.origem_primeira, p.visitas, p.leitura,
       pr.nome as corretor_nome,
       extract(epoch from (coalesce(n.primeiro_contato_em, now()) - n.criado_em))/60 as minutos_ate_contato,
       (n.primeiro_contato_em is null) as sem_contato,
       extract(epoch from (now() - coalesce(n.ultima_atividade_em, n.criado_em)))/3600 as horas_parado
from public.negocios n
join public.pessoas p on p.id = n.pessoa_id
left join public.perfis pr on pr.id = n.corretor_id;

-- Origens: funil por evento (registro + banco)
create or replace view public.v_origens_evento with (security_invoker = true) as
select nome,
       count(*) as total,
       count(*) filter (where ts > now() - interval '14 days') as ultimos_14d,
       count(*) filter (where ts > now() - interval '30 days') as ultimos_30d,
       count(distinct visitante_id) as visitantes,
       count(*) filter (where pessoa_id is not null) as identificados,
       max(ts) as ultimo_em
from public.eventos group by nome;

-- Motores: de onde vieram, primeira visita vs conversão
create or replace view public.v_motores with (security_invoker = true) as
select coalesce(origem_motor,'(direto)') as motor, origem_tipo,
       count(distinct visitante_id) filter (where nome='pagina:view') as visitantes_30d,
       count(*) filter (where nome ~ '_click$|_submit$') as cliques_30d,
       count(distinct pessoa_id) filter (where pessoa_id is not null) as pessoas_30d
from public.eventos where ts > now() - interval '30 days'
group by 1,2 order by visitantes_30d desc;

-- KPIs do topo
create or replace view public.v_kpis with (security_invoker = true) as
select
  (select count(*) from public.pessoas where criado_em > now() - interval '14 days') as pessoas_14d,
  (select count(*) from public.pessoas where criado_em > now() - interval '28 days' and criado_em <= now() - interval '14 days') as pessoas_14d_anterior,
  (select count(*) from public.eventos where ts > now() - interval '14 days' and nome ~ '^(cta|rodape|menu|flutuante|card|tel|mail|mapa):.*_click$') as cliques_14d,
  (select count(*) from public.eventos where ts > now() - interval '28 days' and ts <= now() - interval '14 days' and nome ~ '^(cta|rodape|menu|flutuante|card|tel|mail|mapa):.*_click$') as cliques_14d_anterior,
  (select count(*) from public.pessoas where criado_em > now() - interval '14 days' and ((origem_conversao->>'tipo')='ia' or (origem_primeira->>'tipo')='ia')) as pessoas_ia_14d,
  (select count(*) from public.negocios where primeiro_contato_em is null and etapa not in ('Perdido','Fechado','Vendido','Executado')) as sem_contato,
  (select percentile_cont(0.5) within group (order by extract(epoch from (primeiro_contato_em - criado_em))/60)
     from public.negocios where primeiro_contato_em is not null and criado_em > now() - interval '30 days') as mediana_min_contato,
  (select count(*) from public.pessoas where esteve_no_site) as com_historico;

-- Realtime no que o corretor olha
do $$ begin
  begin alter publication supabase_realtime add table public.negocios; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.atividades; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.pessoas; exception when duplicate_object then null; end;
end $$;
