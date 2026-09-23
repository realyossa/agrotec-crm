-- 008_ai_visibility.sql — robôs e agentes de IA que leem o site (22/09/2026)
--
-- Rodar UMA vez no SQL Editor do Supabase, depois de 001 a 007. Idempotente:
-- rodar de novo não duplica nada.
--
-- Quem escreve: a Edge Function do site (netlify/edge-functions/agentes.js),
-- com a chave de serviço, pela função ingerir_acesso_agente(d jsonb).
-- Só escreve se AGENTES_GRAVAR=1 estiver nas variáveis do Netlify do SITE.
-- Quem lê: o console (RLS, usuário ativo) e o resumo das 19h (chave de serviço).
--
-- Duas camadas, para o banco não crescer à toa:
--   acesso_agente      linha por acesso, SÓ do que vale decisão: leitura ao vivo
--                      de IA, agente de IA, índice de IA, robô desconhecido,
--                      leitura do llms.txt, e erro (4xx/5xx) pedido por IA ou
--                      buscador. 90 dias.
--   acesso_agente_dia  contador por dia/página/agente para TODO o resto
--                      (Googlebot, treino, prévias, SEO, scripts). Sem prazo.
-- Nenhum dado de pessoa: só robô chega aqui, e o IP vem reduzido (/24, /48).

-- ------------------------------------------------------------------ tabelas
create table if not exists public.acesso_agente (
  id bigserial primary key,
  ts timestamptz not null default now(),
  host text, caminho text not null, tem_query boolean not null default false,
  metodo text, status int, destino text,
  agente text not null, empresa text, finalidade text not null, verificacao text,
  pais text, ip_rede text, ua text, assinatura text
);
create index if not exists acesso_agente_ts on public.acesso_agente(ts desc);
create index if not exists acesso_agente_fin_ts on public.acesso_agente(finalidade, ts desc);
create index if not exists acesso_agente_caminho on public.acesso_agente(caminho, ts desc);

create table if not exists public.acesso_agente_dia (
  dia date not null,
  caminho text not null,
  agente text not null,
  finalidade text not null,
  verificacao text not null,
  status_classe text not null,           -- 2xx | 3xx | 4xx | 5xx
  n int not null default 0,
  primary key (dia, caminho, agente, finalidade, verificacao, status_classe)
);

-- Robôs já vistos (para o aviso de "robô novo") e avisos já dados (limite diário).
create table if not exists public.agente_visto (
  chave text primary key,                 -- nome do agente, ou o UA normalizado do desconhecido
  primeiro_em timestamptz not null default now(),
  ultimo_em timestamptz not null default now(),
  n int not null default 1,
  ua_exemplo text
);
create table if not exists public.alerta_agente (
  id bigserial primary key,
  ts timestamptz not null default now(),
  tipo text not null,
  chave text not null
);
create index if not exists alerta_agente_tipo on public.alerta_agente(tipo, chave, ts desc);

-- ------------------------------------------------------------------ ingestão
-- Devolve { alertas: [...] } com no máximo os eventos raros que valem aviso:
--   primeira_leitura_ia  primeira vez que uma IA abre ESTA página ao vivo
--   agente_novo          robô desconhecido nunca visto
--   ia_404               IA pediu página que não existe (1 aviso por página a cada 7 dias)
-- Teto: 10 avisos por dia no total. Acesso com verificação 'falso' nunca avisa
-- (não se comemora um ChatGPT-User falsificado).
create or replace function public.ingerir_acesso_agente(d jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fin text := coalesce(d->>'finalidade', 'bot_desconhecido');
  v_ver text := coalesce(d->>'verificacao', '');
  v_status int := coalesce((d->>'status')::int, 0);
  v_caminho text := left(coalesce(d->>'caminho', '/'), 300);
  v_agente text := left(coalesce(d->>'agente', 'desconhecido'), 120);
  v_ts timestamptz := coalesce((d->>'ts')::timestamptz, now());
  v_dia date := (v_ts at time zone 'America/Sao_Paulo')::date;
  v_classe text := case when v_status >= 500 then '5xx' when v_status >= 400 then '4xx' when v_status >= 300 then '3xx' else '2xx' end;
  v_ia boolean := v_fin in ('leitura_ia', 'agente_ia', 'busca_ia');
  v_bruto boolean;
  v_chave_visto text;
  v_novo boolean := false;
  v_alertas text[] := '{}';
  v_hoje int;
begin
  -- Varredura de vulnerabilidade (/wp-login.php, /.env...) chega como script
  -- com 404 aos milhares: vira um balde só, para não explodir o contador.
  if v_classe in ('4xx', '5xx') and v_fin in ('script', 'bot_desconhecido', 'seo', 'monitor') then
    v_caminho := '(erro ' || v_classe || ' — varredura)';
  end if;

  insert into public.acesso_agente_dia as t (dia, caminho, agente, finalidade, verificacao, status_classe, n)
  values (v_dia, v_caminho, v_agente, v_fin, v_ver, v_classe, 1)
  on conflict (dia, caminho, agente, finalidade, verificacao, status_classe) do update set n = t.n + 1;

  v_bruto := v_ia
          or v_fin = 'bot_desconhecido'
          or v_caminho = '/llms.txt'
          or (v_classe in ('4xx', '5xx') and v_fin in ('treino', 'busca'));

  -- aviso: primeira leitura de IA nesta página (checado ANTES de inserir)
  if v_fin in ('leitura_ia', 'agente_ia') and v_ver <> 'falso' and v_classe = '2xx'
     and not exists (select 1 from public.acesso_agente where caminho = v_caminho and finalidade in ('leitura_ia', 'agente_ia') and verificacao <> 'falso') then
    v_alertas := array_append(v_alertas, 'primeira_leitura_ia');
  end if;

  if v_bruto then
    insert into public.acesso_agente (ts, host, caminho, tem_query, metodo, status, destino, agente, empresa, finalidade, verificacao, pais, ip_rede, ua, assinatura)
    values (v_ts, left(d->>'host', 120), v_caminho, coalesce((d->>'tem_query')::boolean, false), left(d->>'metodo', 8), v_status,
            left(d->>'destino', 300), v_agente, left(d->>'empresa', 60), v_fin, v_ver, left(d->>'pais', 2),
            left(d->>'ip_rede', 60), left(d->>'ua', 400), left(d->>'assinatura', 120));
  end if;

  -- robô visto: o desconhecido é identificado pelo UA sem números de versão
  v_chave_visto := case when v_fin = 'bot_desconhecido'
                        then left(regexp_replace(coalesce(d->>'ua', ''), '[0-9]+(\.[0-9]+)*', 'N', 'g'), 200)
                        else v_agente end;
  insert into public.agente_visto (chave, ua_exemplo) values (v_chave_visto, left(d->>'ua', 400))
  on conflict (chave) do update set ultimo_em = now(), n = public.agente_visto.n + 1
  returning (xmax = 0) into v_novo;
  if v_novo and v_fin = 'bot_desconhecido' then v_alertas := array_append(v_alertas, 'agente_novo'); end if;

  if v_ia and v_classe = '4xx' and v_ver <> 'falso'
     and not exists (select 1 from public.alerta_agente where tipo = 'ia_404' and chave = v_caminho and ts > now() - interval '7 days') then
    v_alertas := array_append(v_alertas, 'ia_404');
  end if;

  -- teto diário e registro dos avisos entregues
  if array_length(v_alertas, 1) > 0 then
    select count(*) into v_hoje from public.alerta_agente
     where ts >= (now() at time zone 'America/Sao_Paulo')::date::timestamp at time zone 'America/Sao_Paulo';
    if v_hoje >= 10 then v_alertas := '{}';
    else
      insert into public.alerta_agente (tipo, chave)
      select a, case when a = 'agente_novo' then v_chave_visto else v_caminho end from unnest(v_alertas) a;
    end if;
  end if;

  -- faxina de 1 em cada 200 chamadas: dado bruto vale 90 dias, aviso 30
  if random() < 0.005 then
    delete from public.acesso_agente where ts < now() - interval '90 days';
    delete from public.alerta_agente where ts < now() - interval '30 days';
  end if;

  return jsonb_build_object('alertas', to_jsonb(v_alertas));
end $$;

-- --------------------------------------------------------- resumo das 19h
create or replace function public.agentes_resumo_dia()
returns jsonb language sql security definer set search_path = public as $$
  with d as (select * from public.acesso_agente_dia where dia = (now() at time zone 'America/Sao_Paulo')::date and verificacao <> 'falso'),
       b as (select * from public.acesso_agente
              where ts >= (now() at time zone 'America/Sao_Paulo')::date::timestamp at time zone 'America/Sao_Paulo'
                and verificacao <> 'falso')
  select jsonb_build_object(
    'leituras_ia',   (select coalesce(sum(n), 0) from d where finalidade in ('leitura_ia', 'agente_ia') and status_classe = '2xx'),
    'indice_ia',     (select coalesce(sum(n), 0) from d where finalidade = 'busca_ia'),
    'treino',        (select coalesce(sum(n), 0) from d where finalidade = 'treino'),
    'buscadores',    (select coalesce(sum(n), 0) from d where finalidade = 'busca'),
    'previas',       (select coalesce(sum(n), 0) from d where finalidade = 'previa'),
    'falsos',        (select coalesce(sum(n), 0) from public.acesso_agente_dia where dia = (now() at time zone 'America/Sao_Paulo')::date and verificacao = 'falso'),
    'paginas_lidas', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select caminho, count(*) as n, string_agg(distinct agente, ', ') as agentes
        from b where finalidade in ('leitura_ia', 'agente_ia') and status < 400 group by 1 order by 2 desc limit 5) t),
    'ia_404',        (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select caminho, count(*) as n from b
        where status >= 400 and finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'treino', 'busca')
        group by 1 order by 2 desc limit 5) t),
    'desconhecidos', (select count(*) from public.agente_visto
        where primeiro_em >= (now() at time zone 'America/Sao_Paulo')::date::timestamp at time zone 'America/Sao_Paulo'
          and chave not in (select distinct agente from public.acesso_agente_dia))
  );
$$;

revoke all on function public.ingerir_acesso_agente(jsonb) from public, anon, authenticated;
revoke all on function public.agentes_resumo_dia() from public, anon, authenticated;
grant execute on function public.ingerir_acesso_agente(jsonb) to service_role;
grant execute on function public.agentes_resumo_dia() to service_role;

-- ---------------------------------------------------------------------- RLS
do $$
declare t text;
begin
  foreach t in array array['acesso_agente', 'acesso_agente_dia', 'agente_visto', 'alerta_agente'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists ler on public.%I', t);
    execute format('create policy ler on public.%I for select to authenticated using (public.eu_ativo())', t);
  end loop;
end $$;

-- ------------------------------------------------------------------- views
-- Aba "IA" do console. security_invoker: quem lê passa pela RLS acima.

-- Por página, 28 dias: a IA leu -> a IA mandou gente -> virou lead.
-- A ponta "gente vinda de IA" já existia (eventos.origem_tipo = 'ia', gravado
-- pelo captacao.js/rastro.js desde agosto). Aqui ela só encontra a leitura.
create or replace view public.v_ia_paginas with (security_invoker = true) as
with l as (
  select caminho,
         sum(n) filter (where finalidade in ('leitura_ia', 'agente_ia')) as leituras_ao_vivo,
         sum(n) filter (where finalidade = 'busca_ia') as indice_ia,
         sum(n) filter (where finalidade = 'treino') as treino,
         sum(n) filter (where finalidade = 'busca') as buscadores,
         max(dia) as ultimo_dia
  from public.acesso_agente_dia
  where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
  group by caminho
), h as (
  select pagina as caminho,
         count(distinct visitante_id) filter (where nome = 'pagina:view') as visitantes_vindos_de_ia,
         count(distinct pessoa_id) as leads_vindos_de_ia
  from public.eventos
  where ts > now() - interval '28 days' and origem_tipo = 'ia'
  group by pagina
)
select coalesce(l.caminho, h.caminho) as caminho,
       coalesce(l.leituras_ao_vivo, 0) as leituras_ao_vivo,
       coalesce(l.indice_ia, 0) as indice_ia,
       coalesce(l.treino, 0) as treino,
       coalesce(l.buscadores, 0) as buscadores,
       coalesce(h.visitantes_vindos_de_ia, 0) as visitantes_vindos_de_ia,
       coalesce(h.leads_vindos_de_ia, 0) as leads_vindos_de_ia,
       l.ultimo_dia
from l full join h on h.caminho = l.caminho
order by leituras_ao_vivo desc, visitantes_vindos_de_ia desc;

-- Série diária por finalidade (gráfico de colunas do console)
create or replace view public.v_ia_serie with (security_invoker = true) as
select dia, finalidade, sum(n) as n
from public.acesso_agente_dia
where dia > current_date - 28 and verificacao <> 'falso'
group by 1, 2 order by 1, 2;

-- Quem mais leu, com a confiança da identificação
create or replace view public.v_ia_agentes with (security_invoker = true) as
select agente, finalidade,
       sum(n) as total_28d,
       sum(n) filter (where verificacao = 'verificado') as verificados,
       sum(n) filter (where verificacao = 'falso') as falsos,
       max(dia) as ultimo_dia
from public.acesso_agente_dia
where dia > current_date - 28
group by 1, 2 order by total_28d desc;

-- Endereços que robô de IA ou buscador pediu e não existem: candidatos a
-- redirect em _redirects (cada um é uma IA tentando usar um link nosso).
create or replace view public.v_ia_erros with (security_invoker = true) as
select caminho, string_agg(distinct agente, ', ') as agentes, count(*) as n, max(ts) as ultimo_em
from public.acesso_agente
where status >= 400 and finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'treino', 'busca')
  and ts > now() - interval '28 days' and verificacao <> 'falso'
group by caminho order by n desc;

-- Fila de revisão: robôs que nenhuma regra reconhece
create or replace view public.v_ia_desconhecidos with (security_invoker = true) as
select v.chave, v.ua_exemplo, v.n, v.primeiro_em, v.ultimo_em
from public.agente_visto v
where exists (select 1 from public.acesso_agente a where a.finalidade = 'bot_desconhecido' and a.ua = v.ua_exemplo)
order by v.ultimo_em desc;
