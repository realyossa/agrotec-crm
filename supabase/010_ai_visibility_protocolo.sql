-- 010_ai_visibility_protocolo.sql — separa robots.txt/llms.txt/sitemap.xml e reconhece o xcub (23/09/2026)
--
-- Rodar no SQL Editor depois do 009. Idempotente.
--
-- 1. Antes de abrir uma página, a IA consulta o /robots.txt para saber se pode.
--    Isso NÃO é leitura de conteúdo, mas estava no topo de "Páginas que a IA abriu"
--    e inflava as leituras ao vivo. Agora esses três arquivos saem da tabela e dos
--    totais e aparecem à parte em v_ia_protocolo. Também não disparam mais o aviso
--    de "primeira leitura" no Telegram.
-- 2. O robô xcub-market-intel (coleta comercial brasileira, 25 acessos em 22-23/09)
--    ganhou regra no site. Aqui os acessos antigos dele saem de "desconhecido".

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
     and v_caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml')
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

create or replace view public.v_ia_paginas with (security_invoker = true) as
with l as (
  select caminho,
         sum(n) filter (where finalidade in ('leitura_ia', 'agente_ia')) as leituras_ao_vivo,
         sum(n) filter (where finalidade = 'busca_ia') as indice_ia,
         sum(n) filter (where finalidade = 'treino') as treino,
         sum(n) filter (where finalidade = 'busca') as buscadores,
         max(dia) as ultimo_dia,
         min(dia) as primeiro_dia
  from public.acesso_agente_dia
  where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
    and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml')
  group by caminho
), h as (
  select pagina as caminho,
         count(distinct visitante_id) filter (where nome = 'pagina:view') as visitantes_vindos_de_ia,
         count(distinct pessoa_id) as leads_vindos_de_ia
  from public.v_ia_eventos_validos
  group by pagina
)
select coalesce(l.caminho, h.caminho) as caminho,
       coalesce(l.leituras_ao_vivo, 0) as leituras_ao_vivo,
       coalesce(l.indice_ia, 0) as indice_ia,
       coalesce(l.treino, 0) as treino,
       coalesce(l.buscadores, 0) as buscadores,
       coalesce(h.visitantes_vindos_de_ia, 0) as visitantes_vindos_de_ia,
       coalesce(h.leads_vindos_de_ia, 0) as leads_vindos_de_ia,
       l.ultimo_dia, l.primeiro_dia
from l full join h on h.caminho = l.caminho
order by leituras_ao_vivo desc, visitantes_vindos_de_ia desc;

-- Totais do topo, contados UMA vez (não é soma das linhas de v_ia_paginas).
create or replace view public.v_ia_totais with (security_invoker = true) as
select
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
      and finalidade in ('leitura_ia', 'agente_ia') and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml'))                         as leituras_ao_vivo,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
      and finalidade = 'busca_ia' and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml'))                                           as indice_ia,
  (select count(distinct visitante_id) from public.v_ia_eventos_validos
    where nome = 'pagina:view')                                              as visitantes_vindos_de_ia,
  (select count(distinct pessoa_id) from public.v_ia_eventos_validos)       as leads_vindos_de_ia,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao = 'falso')                as falsos,
  (select min(dia) from public.acesso_agente_dia)                            as medindo_desde;

-- Consultas de permissão: quem checou robots.txt, llms.txt e sitemap.xml (28 dias).
create or replace view public.v_ia_protocolo with (security_invoker = true) as
select caminho, agente, finalidade, sum(n) as n, max(dia) as ultimo_dia
from public.acesso_agente_dia
where dia > current_date - 28 and verificacao <> 'falso' and caminho in ('/robots.txt', '/llms.txt', '/sitemap.xml')
group by 1, 2, 3 order by n desc;

-- Reclassifica o histórico do xcub.
update public.acesso_agente
   set agente = 'xcub (pesquisa de mercado)', empresa = 'Xcub', finalidade = 'seo'
 where ua ilike '%xcub-market-intel%' and finalidade = 'bot_desconhecido';
delete from public.agente_visto where chave ilike '%xcub-market-intel%';

-- Contadores: só reclassifica se TODO "desconhecido" registrado até agora for o xcub
-- (o contador diário não guarda o user-agent, então não dá para separar de outro jeito).
do $$
begin
  if not exists (select 1 from public.acesso_agente where finalidade = 'bot_desconhecido') then
    insert into public.acesso_agente_dia as t (dia, caminho, agente, finalidade, verificacao, status_classe, n)
    select dia, caminho, 'xcub (pesquisa de mercado)', 'seo', verificacao, status_classe, n
      from public.acesso_agente_dia where agente = 'desconhecido' and finalidade = 'bot_desconhecido'
    on conflict (dia, caminho, agente, finalidade, verificacao, status_classe) do update set n = t.n + excluded.n;
    delete from public.acesso_agente_dia where agente = 'desconhecido' and finalidade = 'bot_desconhecido';
  end if;
end $$;
