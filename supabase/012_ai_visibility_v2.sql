-- 012_ai_visibility_v2.sql — painel "IA lendo o site" v2 (17/10/2026)
--
-- Rodar UMA vez no SQL Editor do Supabase, depois do 010 (e do 011). Idempotente:
-- rodar de novo não duplica nem reconta nada.
--
-- O que o primeiro mês de dado real mostrou (22/09 a 17/10/2026):
--  1. "Desconhecido" era o MAIOR balde (832 acessos em 28 dias) e quase metade era IA
--     sem regra: ExaSearchBot (384, índice que alimenta apps de IA), ExaUser, ShapBot,
--     SofyaBot, xAI-SearchBot, Meta-WebIndexer, DeepSeekBot, Gemini Deep Research e o
--     fetch do Claude Code. As regras novas estão em netlify/lib/agentes.mjs (site);
--     aqui o histórico é reclassificado com os MESMOS padrões — possível porque todo
--     acesso desconhecido tem linha bruta com o user-agent (conferido: 832 = 832).
--  2. O contador diário jogava fora a `empresa` que a Edge Function sempre mandou.
--     Sem ela o painel não agrupa OpenAI, Anthropic, Google... Coluna nova, preenchida
--     daqui para a frente pela ingestão e, para trás, pelo mapa agente -> empresa.
--  3. HTTP 499 (o robô fechou a conexão antes da resposta) contava como "4xx" e entrava
--     em "endereços que não existem". É outra coisa: o ChatGPT-User desistiu da home
--     63 vezes em 25 dias (29% das vezes que a abriu). Ganha classe própria 'abandono'.
--  4. Varredura de vulnerabilidade com nome de robô falsificado (10/10: um ator, 7 nomes,
--     60 caminhos tipo /.env, /.git/HEAD) poluía a lista de 404. Agora qualquer 4xx em
--     caminho de varredura, ou de acesso com IP falso, cai no balde "(erro 4xx — varredura)".
--
-- Quem lê: o console (RLS, usuário ativo). Quem escreve: a Edge Function (chave de serviço).

-- ------------------------------------------------------------ 1. empresa
alter table public.acesso_agente_dia add column if not exists empresa text;

-- ------------------------------------------------------------ 2. ingestão
create or replace function public.ingerir_acesso_agente(d jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fin text := coalesce(d->>'finalidade', 'bot_desconhecido');
  v_ver text := coalesce(d->>'verificacao', '');
  v_status int := coalesce((d->>'status')::int, 0);
  v_caminho text := left(coalesce(d->>'caminho', '/'), 300);
  v_agente text := left(coalesce(d->>'agente', 'desconhecido'), 120);
  v_empresa text := nullif(left(coalesce(d->>'empresa', ''), 60), '');
  v_ts timestamptz := coalesce((d->>'ts')::timestamptz, now());
  v_dia date := (v_ts at time zone 'America/Sao_Paulo')::date;
  -- 499 = o cliente fechou a conexão antes da resposta: não é erro nosso nem página inexistente
  v_classe text := case when v_status = 499 then 'abandono' when v_status >= 500 then '5xx' when v_status >= 400 then '4xx' when v_status >= 300 then '3xx' else '2xx' end;
  v_ia boolean := v_fin in ('leitura_ia', 'agente_ia', 'busca_ia');
  v_bruto boolean;
  v_chave_visto text;
  v_novo boolean := false;
  v_alertas text[] := '{}';
  v_hoje int;
begin
  -- Varredura de vulnerabilidade (/wp-login.php, /.env, /.git/HEAD...) chega aos milhares,
  -- muitas vezes com nome de robô famoso e IP falso: vira um balde só.
  if v_classe in ('4xx', '5xx') and (
       v_fin in ('script', 'bot_desconhecido', 'seo', 'monitor')
       or v_ver = 'falso'
       or v_caminho ~* '(^|/)(\.env|\.git|\.aws|\.netrc|\.npmrc|\.ssh|\.vscode|\.github|\.gitlab|wp-|xmlrpc|phpmyadmin|actuator|graphql|debug/|terraform|docker-compose|application\.(yml|properties)|config\.(yml|json|php)|local_settings|laravel|backend/|api/\.|\.php($|\?)|\.bak$|\.sql$)') then
    v_caminho := '(erro ' || v_classe || ' — varredura)';
  end if;

  insert into public.acesso_agente_dia as t (dia, caminho, agente, finalidade, verificacao, status_classe, n, empresa)
  values (v_dia, v_caminho, v_agente, v_fin, v_ver, v_classe, 1, v_empresa)
  on conflict (dia, caminho, agente, finalidade, verificacao, status_classe)
  do update set n = t.n + 1, empresa = coalesce(t.empresa, excluded.empresa);

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
            left(d->>'destino', 300), v_agente, v_empresa, v_fin, v_ver, left(d->>'pais', 2),
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

  -- IA pediu página que não existe: só 404 de verdade (varredura e abandono ficam fora)
  if v_ia and v_classe = '4xx' and v_ver <> 'falso' and v_caminho not like '(erro%'
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

-- ------------------------------------------------------------ 3. histórico
-- Mapa agente -> empresa, gerado de netlify/lib/agentes.mjs em 17/10/2026
-- (node: REGRAS.map(r => [r.agente, r.empresa])). Só preenche o que está vazio.
drop table if exists _mapa_empresa;
create temp table _mapa_empresa (agente text primary key, empresa text);
insert into _mapa_empresa (agente, empresa) values
    ('ChatGPT-User', 'OpenAI'),
    ('OAI-SearchBot', 'OpenAI'),
    ('OAI-AdsBot', 'OpenAI'),
    ('GPTBot', 'OpenAI'),
    ('Claude Code', 'Anthropic'),
    ('Claude-User', 'Anthropic'),
    ('Claude-SearchBot', 'Anthropic'),
    ('ClaudeBot', 'Anthropic'),
    ('Claude (legado)', 'Anthropic'),
    ('Perplexity-User', 'Perplexity'),
    ('PerplexityBot', 'Perplexity'),
    ('Google-Agent', 'Google'),
    ('Gemini Deep Research', 'Google'),
    ('Gemini Notebook', 'Google'),
    ('Google-CloudVertexBot', 'Google'),
    ('Google-Read-Aloud', 'Google'),
    ('Google-InspectionTool', 'Google'),
    ('Google-Site-Verification', 'Google'),
    ('Googlebot-Image', 'Google'),
    ('Googlebot-Video', 'Google'),
    ('Storebot-Google', 'Google'),
    ('GoogleOther', 'Google'),
    ('AdsBot-Google', 'Google'),
    ('FeedFetcher-Google', 'Google'),
    ('Googlebot', 'Google'),
    ('Bingbot', 'Microsoft'),
    ('Bing Preview', 'Microsoft'),
    ('msnbot', 'Microsoft'),
    ('Applebot-Extended', 'Apple'),
    ('Applebot', 'Apple'),
    ('Meta-WebIndexer', 'Meta'),
    ('Meta-ExternalFetcher', 'Meta'),
    ('Meta-ExternalAgent', 'Meta'),
    ('Facebook (prévia)', 'Meta'),
    ('FacebookBot', 'Meta'),
    ('WhatsApp (prévia)', 'Meta'),
    ('MistralAI-User', 'Mistral'),
    ('ExaSearchBot', 'Exa'),
    ('ExaUser', 'Exa'),
    ('ShapBot', 'Parallel'),
    ('SofyaBot', 'Sofya'),
    ('xAI-SearchBot', 'xAI'),
    ('DeepSeekBot', 'DeepSeek'),
    ('Reflectionbot', 'Reflection AI'),
    ('DuckAssistBot', 'DuckDuckGo'),
    ('YouBot', 'You.com'),
    ('PhindBot', 'Phind'),
    ('Amazonbot', 'Amazon'),
    ('Bytespider', 'ByteDance'),
    ('TikTokSpider', 'ByteDance'),
    ('CCBot', 'Common Crawl'),
    ('Cohere', 'Cohere'),
    ('AI2Bot', 'Allen Institute'),
    ('Diffbot', 'Diffbot'),
    ('Timpibot', 'Timpi'),
    ('ImagesiftBot', 'ImageSift'),
    ('Omgili', 'Webz.io'),
    ('PanguBot', 'Huawei'),
    ('Bravebot', 'Brave'),
    ('DuckDuckBot', 'DuckDuckGo'),
    ('YandexBot', 'Yandex'),
    ('Baiduspider', 'Baidu'),
    ('PetalBot', 'Huawei'),
    ('SeznamBot', 'Seznam'),
    ('Qwantbot', 'Qwant'),
    ('MojeekBot', 'Mojeek'),
    ('Yahoo Slurp', 'Yahoo'),
    ('Naver Yeti', 'Naver'),
    ('Internet Archive', 'Internet Archive'),
    ('Telegram (prévia)', 'Telegram'),
    ('X (prévia)', 'X'),
    ('LinkedIn (prévia)', 'LinkedIn'),
    ('Slack (prévia)', 'Slack'),
    ('Discord (prévia)', 'Discord'),
    ('Pinterest', 'Pinterest'),
    ('Reddit (prévia)', 'Reddit'),
    ('AhrefsBot', 'Ahrefs'),
    ('SemrushBot', 'Semrush'),
    ('MJ12bot', 'Majestic'),
    ('DotBot', 'Moz'),
    ('rogerbot', 'Moz'),
    ('DataForSeoBot', 'DataForSEO'),
    ('serpstatbot', 'Serpstat'),
    ('BLEXBot', 'WebMeUp'),
    ('Barkrowler', 'Babbar'),
    ('Screaming Frog', 'Screaming Frog'),
    ('Lighthouse', 'Google'),
    ('xcub (pesquisa de mercado)', 'Xcub'),
    ('SE Ranking', 'SE Ranking'),
    ('Kenlo (inteligência imobiliária)', 'Kenlo'),
    ('webXtrend', 'webXtrend'),
    ('GTmetrix', 'GTmetrix'),
    ('OpenINTEL (medição acadêmica)', 'OpenINTEL'),
    ('LeakIX (scanner)', 'LeakIX'),
    ('Censys (scanner)', 'Censys'),
    ('Modat (scanner)', 'Modat'),
    ('Recorded Future (scanner)', 'Recorded Future'),
    ('ChatGPT agent', 'OpenAI')
on conflict (agente) do nothing;

-- Padrões das regras NOVAS de agentes.mjs (mesma data), para os acessos já gravados
-- como desconhecidos. A ordem importa: a primeira que casa vence, como no módulo.
drop table if exists _reclass;
create temp table _reclass (ordem int, padrao text, agente text, empresa text, finalidade text);
insert into _reclass values
  (1,  'Claude-User \(claude-code/', 'Claude Code', 'Anthropic', 'leitura_ia'),
  (2,  'Gemini-Deep-Research', 'Gemini Deep Research', 'Google', 'leitura_ia'),
  (3,  'meta-webindexer', 'Meta-WebIndexer', 'Meta', 'busca_ia'),
  (4,  'ExaSearchBot', 'ExaSearchBot', 'Exa', 'busca_ia'),
  (5,  'ExaUser', 'ExaUser', 'Exa', 'leitura_ia'),
  (6,  'ShapBot', 'ShapBot', 'Parallel', 'busca_ia'),
  (7,  'SofyaBot', 'SofyaBot', 'Sofya', 'busca_ia'),
  (8,  'xAI-SearchBot', 'xAI-SearchBot', 'xAI', 'busca_ia'),
  (9,  'DeepSeekBot', 'DeepSeekBot', 'DeepSeek', 'treino'),
  (10, 'Reflectionbot', 'Reflectionbot', 'Reflection AI', 'treino'),
  (11, 'Bravebot', 'Bravebot', 'Brave', 'busca'),
  (12, 'SemrushBot', 'SemrushBot', 'Semrush', 'seo'),
  (13, 'SERankingBacklinksBot', 'SE Ranking', 'SE Ranking', 'seo'),
  (14, 'KenloSiteIntel', 'Kenlo (inteligência imobiliária)', 'Kenlo', 'seo'),
  (15, 'webXtrendBot', 'webXtrend', 'webXtrend', 'seo'),
  (16, 'ProspectorBot|DiagnosticoBot|MomentLeadsBot|DataSocioBot|KodaFinancial|company-db-worker|ApcosysBot|BidflowAdsTxtCrawler|TheWebReport', 'Prospecção comercial', null, 'seo'),
  (17, 'GSCWizard-Bot', 'GSC Wizard (plugin do dono)', null, 'seo'),
  (18, 'OI-Crawler', 'OpenINTEL (medição acadêmica)', 'OpenINTEL', 'monitor'),
  (19, 'l9scan|leakix', 'LeakIX (scanner)', 'LeakIX', 'script'),
  (20, 'CensysInspect', 'Censys (scanner)', 'Censys', 'script'),
  (21, 'ModatScanner', 'Modat (scanner)', 'Modat', 'script'),
  (22, 'RecordedFuture', 'Recorded Future (scanner)', 'Recorded Future', 'script'),
  (23, 'ForestEngine|DefaultsExposed|CMS-Checker|\mwpbot/|MochiImageCrawler', 'Scanner genérico', null, 'script');

do $$
declare
  v_daily bigint; v_raw bigint; v_reclass bigint;
begin
  -- Guarda: o contador diário de leitura_ia/agente_ia/busca_ia/bot_desconhecido só pode
  -- ser reconstruído se TODO acesso dele ainda está no bruto (faxina de 90 dias).
  select coalesce(sum(n), 0) into v_daily from public.acesso_agente_dia
   where finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'bot_desconhecido');
  select count(*) into v_raw from public.acesso_agente
   where finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'bot_desconhecido');
  if v_daily <> v_raw then
    raise exception 'contador diário (%) e bruto (%) não batem — reconstrução abortada, nada foi mudado', v_daily, v_raw;
  end if;

  -- ids das linhas brutas que entram na reconstrução (ANTES de reclassificar)
  drop table if exists _ids;
  create temp table _ids as
    select id from public.acesso_agente
     where finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'bot_desconhecido');

  -- reclassifica os desconhecidos pelo primeiro padrão que casa (case-insensitive, como /i)
  update public.acesso_agente a
     set agente = r.agente, empresa = r.empresa, finalidade = r.finalidade
    from (select distinct on (a2.id) a2.id, rc.agente, rc.empresa, rc.finalidade
            from public.acesso_agente a2
            join _reclass rc on a2.ua ~* rc.padrao
           where a2.finalidade = 'bot_desconhecido'
           order by a2.id, rc.ordem) r
   where a.id = r.id;
  get diagnostics v_reclass = row_count;

  -- empresa que faltava nas linhas brutas conhecidas
  update public.acesso_agente a set empresa = m.empresa from _mapa_empresa m
   where a.agente = m.agente and (a.empresa is null or a.empresa = '');

  -- 499 em linha bruta antiga vira classe 'abandono'; varredura antiga vira balde
  -- (os caminhos de varredura já tinham virado balde para script/desconhecido; aqui
  -- entram os que vieram com nome de robô falsificado)
  update public.acesso_agente
     set caminho = '(erro ' || case when status >= 500 then '5xx' else '4xx' end || ' — varredura)'
   where id in (select id from _ids) and status >= 400 and status <> 499 and caminho not like '(erro%'
     and (verificacao = 'falso'
          or caminho ~* '(^|/)(\.env|\.git|\.aws|\.netrc|\.npmrc|\.ssh|\.vscode|\.github|\.gitlab|wp-|xmlrpc|phpmyadmin|actuator|graphql|debug/|terraform|docker-compose|application\.(yml|properties)|config\.(yml|json|php)|local_settings|laravel|backend/|api/\.|\.php($|\?)|\.bak$|\.sql$)');

  -- reconstrói o contador diário dessas finalidades a partir do bruto já corrigido
  delete from public.acesso_agente_dia
   where finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'bot_desconhecido');
  insert into public.acesso_agente_dia as t (dia, caminho, agente, finalidade, verificacao, status_classe, n, empresa)
  select (a.ts at time zone 'America/Sao_Paulo')::date, a.caminho, a.agente, a.finalidade, a.verificacao,
         case when a.status = 499 then 'abandono' when a.status >= 500 then '5xx' when a.status >= 400 then '4xx' when a.status >= 300 then '3xx' else '2xx' end,
         count(*), max(a.empresa)
    from public.acesso_agente a join _ids i on i.id = a.id
   group by 1, 2, 3, 4, 5, 6
  on conflict (dia, caminho, agente, finalidade, verificacao, status_classe)
  do update set n = t.n + excluded.n, empresa = coalesce(t.empresa, excluded.empresa);

  -- fila de revisão: sai quem agora tem regra
  delete from public.agente_visto v
   where exists (select 1 from _reclass rc where v.ua_exemplo ~* rc.padrao);

  drop table if exists _ids;
  raise notice '012: % acessos reclassificados; contador diário reconstruído de % linhas brutas', v_reclass, v_raw;
end $$;

-- empresa nos contadores antigos de todos os agentes conhecidos
update public.acesso_agente_dia d set empresa = m.empresa from _mapa_empresa m
 where d.agente = m.agente and d.empresa is null;
drop table if exists _mapa_empresa;
drop table if exists _reclass;

-- ------------------------------------------------------------ 4. views
create or replace view public.v_ia_paginas with (security_invoker = true) as
with l as (
  select caminho,
         sum(n) filter (where finalidade in ('leitura_ia', 'agente_ia') and status_classe = '2xx') as leituras_ao_vivo,
         sum(n) filter (where finalidade = 'busca_ia' and status_classe = '2xx') as indice_ia,
         sum(n) filter (where finalidade = 'treino' and status_classe = '2xx') as treino,
         sum(n) filter (where finalidade = 'busca' and status_classe = '2xx') as buscadores,
         sum(n) filter (where finalidade in ('leitura_ia', 'agente_ia') and status_classe = 'abandono') as abandonos,
         max(dia) filter (where status_classe = '2xx') as ultimo_dia,
         min(dia) filter (where status_classe = '2xx') as primeiro_dia
  from public.acesso_agente_dia
  where dia > current_date - 28 and verificacao <> 'falso'
    and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml') and caminho not like '(erro%'
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
       l.ultimo_dia, l.primeiro_dia,
       coalesce(l.abandonos, 0) as abandonos
from l full join h on h.caminho = l.caminho
order by leituras_ao_vivo desc, visitantes_vindos_de_ia desc;

-- Totais do topo, contados UMA vez (não é soma das linhas de v_ia_paginas).
create or replace view public.v_ia_totais with (security_invoker = true) as
select
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
      and finalidade in ('leitura_ia', 'agente_ia') and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml')) as leituras_ao_vivo,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
      and finalidade = 'busca_ia' and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml')) as indice_ia,
  (select count(distinct visitante_id) from public.v_ia_eventos_validos where nome = 'pagina:view') as visitantes_vindos_de_ia,
  (select count(distinct pessoa_id) from public.v_ia_eventos_validos) as leads_vindos_de_ia,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao = 'falso') as falsos,
  (select min(dia) from public.acesso_agente_dia) as medindo_desde,
  -- colunas novas no fim (create or replace view não aceita coluna no meio)
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao <> 'falso' and status_classe = 'abandono'
      and finalidade in ('leitura_ia', 'agente_ia')) as abandonos,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and caminho like '(erro%') as varredura,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and finalidade = 'bot_desconhecido') as desconhecidos;

-- Quem leu, com empresa e confiança da identificação
create or replace view public.v_ia_agentes with (security_invoker = true) as
select agente, finalidade,
       sum(n) as total_28d,
       sum(n) filter (where verificacao = 'verificado') as verificados,
       sum(n) filter (where verificacao = 'falso') as falsos,
       max(dia) as ultimo_dia,
       max(empresa) as empresa,
       sum(n) filter (where status_classe = 'abandono') as abandonos
from public.acesso_agente_dia
where dia > current_date - 28
group by agente, finalidade order by total_28d desc;

-- Por empresa: o que cada uma faz no site (28 dias, sem falsos)
create or replace view public.v_ia_empresas with (security_invoker = true) as
select coalesce(nullif(empresa, ''), agente) as empresa,
       sum(n) as total_28d,
       sum(n) filter (where finalidade in ('leitura_ia', 'agente_ia') and status_classe = '2xx') as leituras_ao_vivo,
       sum(n) filter (where finalidade = 'busca_ia' and status_classe = '2xx') as indice_ia,
       sum(n) filter (where finalidade = 'treino' and status_classe = '2xx') as treino,
       sum(n) filter (where finalidade = 'busca' and status_classe = '2xx') as busca,
       sum(n) filter (where finalidade = 'previa') as previa,
       sum(n) filter (where finalidade in ('seo', 'monitor', 'script')) as ferramentas,
       sum(n) filter (where status_classe = 'abandono') as abandonos,
       sum(n) filter (where verificacao = 'verificado') as verificados,
       sum(n) filter (where verificacao = 'nao_verificavel' or verificacao = '') as nao_verificaveis,
       count(distinct caminho) filter (where status_classe = '2xx' and caminho not like '(erro%') as paginas,
       max(dia) as ultimo_dia, min(dia) as primeiro_dia,
       string_agg(distinct agente, ', ') as agentes,
       (array_agg(finalidade order by n desc))[1] as finalidade_principal
from public.acesso_agente_dia
where dia > current_date - 28 and verificacao <> 'falso' and finalidade <> 'bot_desconhecido'
group by 1 order by total_28d desc;

-- Quais IAs abriram cada página ao vivo (para a coluna "quem" da tabela de páginas)
create or replace view public.v_ia_pagina_agentes with (security_invoker = true) as
select caminho, agente, max(empresa) as empresa, sum(n) as n, max(dia) as ultimo_dia
from public.acesso_agente_dia
where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
  and finalidade in ('leitura_ia', 'agente_ia') and caminho not in ('/robots.txt', '/llms.txt', '/sitemap.xml')
group by 1, 2 order by n desc;

-- Endereços que robô de IA ou buscador pediu e deram erro de verdade: 404 de página que
-- não existe, 5xx nosso. Varredura e abandono (499) ficam fora — têm seção própria.
drop view if exists public.v_ia_erros;  -- muda a forma das colunas
create view public.v_ia_erros with (security_invoker = true) as
select caminho, status, string_agg(distinct agente, ', ') as agentes, count(*) as n, max(ts) as ultimo_em,
       case when status >= 500 then 'servidor'
            when caminho ~* '^/sitemap' then 'sitemap'
            when caminho ~ '^/[^/]+/.+' then 'pasta_adivinhada'
            else 'pagina' end as tipo
from public.acesso_agente
where status >= 400 and status <> 499 and finalidade in ('leitura_ia', 'agente_ia', 'busca_ia', 'treino', 'busca')
  and ts > now() - interval '28 days' and verificacao <> 'falso' and caminho not like '(erro%'
group by caminho, status order by n desc;

-- Leituras que a IA começou e abandonou (499), por página: quando é a home, é peso/tempo.
create or replace view public.v_ia_abandonos with (security_invoker = true) as
select caminho, agente,
       sum(n) filter (where status_classe = 'abandono') as abandonos,
       sum(n) filter (where status_classe = '2xx') as completas,
       max(dia) filter (where status_classe = 'abandono') as ultimo_dia
from public.acesso_agente_dia
where dia > current_date - 28 and verificacao <> 'falso' and finalidade in ('leitura_ia', 'agente_ia')
group by 1, 2 having sum(n) filter (where status_classe = 'abandono') > 0
order by abandonos desc;

-- Falsos agrupados por ator (dia + rede): "um ator em 10/10 usou 7 nomes de robô".
create or replace view public.v_ia_falsos_grupos with (security_invoker = true) as
select (ts at time zone 'America/Sao_Paulo')::date as dia, ip_rede, pais,
       count(*) as n, count(distinct agente) as nomes, string_agg(distinct agente, ', ') as agentes,
       bool_or(caminho like '(erro%') as varredura, count(distinct caminho) as caminhos
from public.acesso_agente
where verificacao = 'falso' and ts > now() - interval '28 days'
group by 1, 2, 3 order by n desc;

-- Fila de revisão: robôs que nenhuma regra reconhece (a chave é o UA sem versões)
create or replace view public.v_ia_desconhecidos with (security_invoker = true) as
select v.chave, v.ua_exemplo, v.n, v.primeiro_em, v.ultimo_em,
       (select count(distinct caminho) from public.acesso_agente a where a.finalidade = 'bot_desconhecido'
          and left(regexp_replace(coalesce(a.ua, ''), '[0-9]+(\.[0-9]+)*', 'N', 'g'), 200) = v.chave) as paginas,
       (select string_agg(distinct pais, ', ') from public.acesso_agente a where a.finalidade = 'bot_desconhecido'
          and left(regexp_replace(coalesce(a.ua, ''), '[0-9]+(\.[0-9]+)*', 'N', 'g'), 200) = v.chave) as paises
from public.agente_visto v
where exists (select 1 from public.acesso_agente a where a.finalidade = 'bot_desconhecido'
                and left(regexp_replace(coalesce(a.ua, ''), '[0-9]+(\.[0-9]+)*', 'N', 'g'), 200) = v.chave)
order by v.n desc;
