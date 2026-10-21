-- =====================================================================
-- 014 — Clique no WhatsApp do site ligado à conversa do 2460 (21/10/2026)
--
-- POR QUE
-- O 013 só liga a conversa a quem já deixou o telefone num formulário ou no
-- popup. Quem clica no botão do WhatsApp sem se identificar e escreve para o
-- 2460 chegava ao console como "WhatsApp 2460", sem página, sem origem e sem
-- trajeto — o clique ficava num visitante anônimo e a conversa numa pessoa
-- nova, sem nada que os unisse. Este SQL une os dois.
--
-- COMO RECONHECE (sem código de referência na mensagem: regra do dono)
-- O site grava, no evento do clique, o número de destino e o texto que já
-- vai escrito na conversa (props wa_numero e wa_texto; rastro.js e
-- portoes.js). Quando chega a PRIMEIRA mensagem de um número (nenhuma antes,
-- nem do cliente nem do Jonas), ao vivo, cuja pessoa ainda não tem visitante
-- ligado, procura cliques de WhatsApp anônimos para o 2460 recebidos pelo
-- servidor nos 30 minutos anteriores (2 min de folga depois, pelo atraso da
-- rede). Clique seguido de popup fechado no X não conta: essa pessoa não foi
-- ao WhatsApp.
--   certeza   um único visitante cujo texto pré-preenchido é o começo da
--             mensagem (espaços, acentos, maiúsculas e caracteres invisíveis
--             não contam). Liga na hora.
--   provável  ninguém bate pelo texto e há um único visitante no horário.
--             NÃO liga: deixa a sugestão na ficha e na linha do tempo; o
--             corretor confirma (whatsapp_clique_confirmar, botão
--             "confirmar") ou descarta (whatsapp_clique_descartar, "não é").
--             Ligar sem confirmar levaria o formulário que o visitante
--             preenchesse depois para a ficha de outra pessoa (o ingerir_lead
--             do 002 acha a pessoa pelo visitante).
--   ambíguo   mais de um visitante possível: não liga, registra e avisa na
--             linha do tempo.
--
-- O QUE FAZ AO LIGAR (certeza, ou provável confirmado)
--   visitantes.pessoa_id e eventos.pessoa_id (o histórico do navegador cola
--   na ficha, como no ingerir_lead do 002); na pessoa: trajeto, cidades
--   vistas, visitas, etiquetas (veio do site, motor da origem, funil, cidade
--   da página) e vinculo_site; a origem só é trocada em quem nasceu da
--   conversa do 013 (origem 'whatsapp') — pessoa de outra origem a mantém;
--   no cartão aberto pelo WhatsApp: página e botão do clique; na linha do
--   tempo: "Veio do clique em <botão> na <página>".
--
-- O QUE CRIA
--   pessoas.etiquetas text[], pessoas.vinculo_site jsonb
--   eventos.recebido_em   hora do servidor (a do clique vem do celular de
--                         quem clicou e não é conferida)
--   whatsapp_cliques_ligacao   uma linha por decisão quando houve candidato
--                              (certeza, provável, ambíguo, erro; 'nenhum'
--                              quando o visitante foi levado no meio)
--   gatilho whatsapp_clique em whatsapp_mensagens, depois de o 013 ligar a
--   mensagem à pessoa. Não substitui nenhuma função do 013.
--
-- SEGURANÇA DA CAPTURA
-- Erro aqui dentro é engolido e registrado (resultado 'erro'): a mensagem do
-- cliente é gravada de qualquer jeito.
--
-- Exige o 013. Só aditivo e idempotente: pode rodar duas vezes.
-- Aplicar pelo SQL Editor do Supabase (projeto agrotec-crm).
-- Testado em PGlite (Postgres 17) com 001–013 aplicados:
-- agrotec/ferramentas/testar_whatsapp.mjs (seção 13).
-- =====================================================================

begin;

-- 0. TRAVA: o gatilho fica na tabela do 013.
do $$
begin
  if to_regclass('public.whatsapp_mensagens') is null then
    raise exception 'PAROU: o 013 (WhatsApp 2460) nao esta aplicado. Rode o 013 antes. Nada foi alterado.';
  end if;
end $$;

-- 1. colunas -----------------------------------------------------------------
alter table public.pessoas add column if not exists etiquetas text[] not null default '{}';
alter table public.pessoas add column if not exists vinculo_site jsonb;
-- os eventos que já existem ficam sem hora do servidor (vale a do clique)
alter table public.eventos add column if not exists recebido_em timestamptz;
alter table public.eventos alter column recebido_em set default now();

-- 2. registro de cada decisão -----------------------------------------------
create table if not exists public.whatsapp_cliques_ligacao (
  id bigserial primary key,
  em timestamptz not null default now(),
  wamid text not null unique,
  pessoa_id uuid references public.pessoas(id) on delete cascade,
  resultado text not null check (resultado in ('certeza','provavel','ambiguo','nenhum','erro')),
  visitante_id text,
  evento_id bigint,
  candidatos jsonb not null default '[]'::jsonb,
  detalhe text
);
create index if not exists whatsapp_cliques_ligacao_pessoa on public.whatsapp_cliques_ligacao(pessoa_id);
alter table public.whatsapp_cliques_ligacao enable row level security;
drop policy if exists ler on public.whatsapp_cliques_ligacao;
create policy ler on public.whatsapp_cliques_ligacao for select to authenticated using (public.eu_ativo());

-- 3. texto comparável --------------------------------------------------------
-- espaço especial vira espaço; acento (decomposto) e caractere invisível
-- somem; minúscula; espaços em um só
create or replace function public.whatsapp_normalizar(t text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(lower(regexp_replace(
           normalize(regexp_replace(coalesce(t, ''), '[\u00a0\u2007\u202f]', ' ', 'g'), NFD),
           '[\u0300-\u036f\u200b-\u200d\u2060\ufeff]', '', 'g')), '\s+', ' ', 'g'));
$$;

-- número para onde o clique mandou: o campo novo do site ou, nos eventos de
-- antes dele, o href guardado em `destino`
create or replace function public.whatsapp_clique_destino(p jsonb)
returns text language sql immutable set search_path = public as $$
  select coalesce(nullif(regexp_replace(coalesce(p->>'wa_numero', ''), '\D', '', 'g'), ''),
                  substring(coalesce(p->>'destino', '') from '(?:wa\.me/|[?&]phone=)\+?(\d{8,15})'));
$$;

-- 4. ligar de fato (certeza, ou provável confirmado) -------------------------
create or replace function public.whatsapp_clique_aplicar(p_pessoa uuid, p_evento bigint, p_negocio uuid,
                                                          p_certeza text, p_wamid text, p_em timestamptz, p_quem uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  c record; v_vis record; p record;
  v_origem jsonb; v_motor text; v_funil text; v_novas text[]; v_trajeto text[]; v_cidades text[];
  v_pag text; v_botao text; v_troca_origem boolean;
begin
  select e.*, s.origem as sessao_origem into c
    from public.eventos e left join public.sessoes s on s.id = e.sessao_id
   where e.id = p_evento;
  if not found then return false; end if;
  select * into p from public.pessoas where id = p_pessoa;
  if not found then return false; end if;

  -- o visitante é tomado de uma vez: se já é de outra pessoa, desiste
  update public.visitantes set pessoa_id = p_pessoa where id = c.visitante_id and pessoa_id is null;
  if not found then return false; end if;
  update public.eventos set pessoa_id = p_pessoa where visitante_id = c.visitante_id and pessoa_id is null;

  select * into v_vis from public.visitantes where id = c.visitante_id;
  v_origem := case when jsonb_typeof(c.sessao_origem) = 'object' then c.sessao_origem
                   else jsonb_strip_nulls(jsonb_build_object('tipo', c.origem_tipo, 'motor', c.origem_motor, 'via', c.origem_via)) end
              || jsonb_build_object('canal', 'whatsapp');
  v_motor := case when coalesce(v_origem->>'tipo', 'direto') in ('direto', 'interno', '') then 'direto'
                  when v_origem->>'tipo' = 'ia' then 'IA (' || coalesce(nullif(v_origem->>'motor', ''), '?') || ')'
                  else coalesce(nullif(v_origem->>'motor', ''), v_origem->>'tipo') end;
  v_funil := coalesce(nullif(c.funil, ''),
                      case c.props->>'fluxo' when 'vender' then 'venda' when 'comprar' then 'compra' end);
  v_novas := array_remove(array['veio do site', 'origem: ' || v_motor,
                                'funil: ' || v_funil, 'cidade: ' || nullif(c.cidade_pagina, '')], null);
  select array_agg(pagina order by primeiro) into v_trajeto from (
    select pagina, min(ts) primeiro from public.eventos
     where visitante_id = c.visitante_id and nome = 'pagina:view' and coalesce(pagina, '') <> ''
     group by pagina order by min(ts) limit 30) x;
  select array_agg(distinct cidade_pagina) into v_cidades from public.eventos
   where visitante_id = c.visitante_id and coalesce(cidade_pagina, '') <> '';
  -- origem só muda em quem nasceu da conversa (013); indicação, planilha e
  -- cadastro manual guardam a origem que tinham
  v_troca_origem := coalesce(p.origem_primeira->>'tipo', 'whatsapp') = 'whatsapp';

  update public.pessoas set
    visitante_id = c.visitante_id,
    esteve_no_site = true,
    origem_primeira = case when not v_troca_origem then origem_primeira
                           else (case when jsonb_typeof(v_vis.primeira_origem) = 'object' then v_vis.primeira_origem else v_origem end)
                                || case when origem_primeira ? 'historico'
                                        then jsonb_build_object('historico', origem_primeira->'historico') else '{}'::jsonb end end,
    origem_conversao = case when v_troca_origem then v_origem else origem_conversao end,
    visitas = greatest(coalesce(visitas, 0), coalesce(v_vis.visitas, 1)),
    trajeto = coalesce(v_trajeto, trajeto),
    cidades_vistas = coalesce(v_cidades, cidades_vistas),
    etiquetas = etiquetas || array(select x from unnest(v_novas) x where not x = any(etiquetas)),
    vinculo_site = jsonb_build_object('certeza', p_certeza, 'wamid', p_wamid, 'visitante_id', c.visitante_id,
                     'evento_id', c.id, 'clique_em', c.ts, 'pagina', c.pagina, 'botao', c.rotulo,
                     'origem', v_motor, 'negocio_id', p_negocio, 'ligado_em', now(), 'ligado_por', p_quem,
                     'antes', jsonb_build_object('origem_primeira', p.origem_primeira, 'origem_conversao', p.origem_conversao,
                                                 'visitas', p.visitas, 'trajeto', p.trajeto, 'cidades_vistas', p.cidades_vistas,
                                                 'etiquetas', p.etiquetas))
   where id = p_pessoa;

  v_pag := coalesce(nullif(c.pagina, ''), 'página não registrada');
  v_botao := coalesce(nullif(c.rotulo, ''), 'WhatsApp');
  if p_negocio is not null then
    update public.negocios set
      origem_pagina = c.pagina,
      origem_rotulo = 'WhatsApp 2460 — ' || v_botao
     where id = p_negocio and origem_pagina is null and origem_evento like 'whatsapp:%';
  end if;
  insert into public.atividades (negocio_id, pessoa_id, tipo, em, quem, texto, meta)
  values (p_negocio, p_pessoa, 'sistema', p_em, p_quem,
          case when p_certeza = 'confirmado' then 'Confirmado: veio do clique em "' || v_botao || '" na ' || v_pag
               else 'Veio do clique em "' || v_botao || '" na ' || v_pag end,
          jsonb_build_object('fonte', 'whatsapp_clique', 'certeza', p_certeza, 'wamid', p_wamid,
                             'visitante_id', c.visitante_id, 'evento_id', c.id));
  return true;
end $$;

-- 5. o gatilho ---------------------------------------------------------------
create or replace function public.whatsapp_clique_ligar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pessoa uuid := new.pessoa_id;
  v_msg text;
  v_cands jsonb; n_texto int; n_hora int;
  v_res text; v_ev_id bigint; c record; p record;
begin
  begin
    v_msg := public.whatsapp_normalizar(new.texto);
    -- só quem ainda não tem o site ligado; interno nunca
    select * into p from public.pessoas where id = v_pessoa;
    if not found or p.interna or p.visitante_id is not null
       or exists (select 1 from public.visitantes where pessoa_id = v_pessoa) then
      return null;
    end if;
    -- só a primeira mensagem do número, em qualquer direção: se o Jonas
    -- escreveu primeiro, a conversa não começou de um clique
    if exists (select 1 from public.whatsapp_mensagens
                where pessoa_id = v_pessoa and wamid <> new.wamid) then
      return null;
    end if;

    -- candidatos: um por visitante anônimo que clicou para o 2460 na janela;
    -- `texto` diz se algum clique dele é o começo da mensagem
    with cliques as (
      select e.id, e.visitante_id, e.ts,
             public.whatsapp_normalizar(e.props->>'wa_texto') as pre
        from public.eventos e
        join public.visitantes v on v.id = e.visitante_id and v.pessoa_id is null
       where e.pessoa_id is null
         and e.ts > new.em - interval '1 day'      -- usa o índice eventos_ts
         and coalesce(e.recebido_em, e.ts) between new.em - interval '30 minutes' and new.em + interval '2 minutes'
         and (e.nome like '%:whatsapp_click' or (e.nome = 'portao:caminho_click' and e.props->>'caminho' = 'whats'))
         and (public.whatsapp_eh_empresa(public.whatsapp_clique_destino(e.props))
              -- portão de antes do campo novo: abre sempre o número do site
              or (e.nome = 'portao:caminho_click' and public.whatsapp_clique_destino(e.props) is null))
         -- popup fechado no X depois do clique: não foi ao WhatsApp
         and coalesce((select x.nome from public.eventos x
                        where x.visitante_id = e.visitante_id and x.ts >= e.ts
                          and x.nome in ('popup:identificacao_close', 'popup:identificacao_skip', 'popup:identificacao_submit')
                        order by x.ts limit 1), '') <> 'popup:identificacao_close'
    ), marcados as (
      select *, (length(pre) >= 12 and left(v_msg, length(pre)) = pre) as bate from cliques
    ), por_visitante as (
      select distinct on (visitante_id) visitante_id, id as evento_id, ts, bate
        from marcados
       order by visitante_id, bate desc, ts desc
    )
    select coalesce(jsonb_agg(jsonb_build_object('visitante_id', visitante_id, 'evento_id', evento_id,
                                                 'ts', ts, 'texto', bate) order by ts desc), '[]'::jsonb),
           count(*) filter (where bate), count(*)
      into v_cands, n_texto, n_hora
      from por_visitante;

    if n_hora = 0 then return null; end if;

    if n_texto = 1 then v_res := 'certeza';
    elsif n_texto > 1 or n_hora > 1 then v_res := 'ambiguo';
    else v_res := 'provavel';
    end if;

    if v_res = 'ambiguo' then
      insert into public.whatsapp_cliques_ligacao (wamid, pessoa_id, resultado, candidatos, detalhe)
      values (new.wamid, v_pessoa, 'ambiguo', v_cands,
              case when n_texto > 1 then n_texto || ' visitantes com o mesmo texto' else n_hora || ' visitantes no horário' end)
      on conflict (wamid) do nothing;
      if new.negocio_id is not null then
        insert into public.atividades (negocio_id, pessoa_id, tipo, em, texto, meta)
        values (new.negocio_id, v_pessoa, 'sistema', new.em,
                'Pode ter vindo de um clique no WhatsApp do site, mas ' ||
                case when n_texto > 1 then n_texto else n_hora end ||
                ' visitantes clicaram nos 30 minutos antes. Nenhum foi ligado.',
                jsonb_build_object('fonte', 'whatsapp_clique', 'certeza', 'ambiguo', 'wamid', new.wamid));
      end if;
      return null;
    end if;

    v_ev_id := (select (x->>'evento_id')::bigint from jsonb_array_elements(v_cands) x
                 where v_res = 'provavel' or (x->>'texto')::boolean limit 1);

    if v_res = 'certeza' then
      if not public.whatsapp_clique_aplicar(v_pessoa, v_ev_id, new.negocio_id, 'certeza', new.wamid, new.em, null) then
        insert into public.whatsapp_cliques_ligacao (wamid, pessoa_id, resultado, evento_id, candidatos, detalhe)
        values (new.wamid, v_pessoa, 'nenhum', v_ev_id, v_cands, 'visitante ligado a outra pessoa no meio')
        on conflict (wamid) do nothing;
        return null;
      end if;
    else
      -- provável: só a sugestão; nada do visitante entra na ficha antes de o
      -- corretor confirmar
      select * into c from public.eventos where id = v_ev_id;
      update public.pessoas set vinculo_site = jsonb_build_object(
          'certeza', 'provavel', 'wamid', new.wamid, 'visitante_id', c.visitante_id, 'evento_id', c.id,
          'clique_em', c.ts, 'pagina', c.pagina, 'botao', c.rotulo, 'negocio_id', new.negocio_id,
          'origem', case when coalesce(c.origem_tipo, 'direto') in ('direto', 'interno', '') then 'direto'
                         when c.origem_tipo = 'ia' then 'IA (' || coalesce(nullif(c.origem_motor, ''), '?') || ')'
                         else coalesce(nullif(c.origem_motor, ''), c.origem_tipo) end,
          'sugerido_em', now())
       where id = v_pessoa;
      if new.negocio_id is not null then
        insert into public.atividades (negocio_id, pessoa_id, tipo, em, texto, meta)
        values (new.negocio_id, v_pessoa, 'sistema', new.em,
                'Provavelmente veio do clique em "' || coalesce(nullif(c.rotulo, ''), 'WhatsApp') || '" na '
                || coalesce(nullif(c.pagina, ''), 'página não registrada')
                || ' (só o horário bate; confirmar com a pessoa)',
                jsonb_build_object('fonte', 'whatsapp_clique', 'certeza', 'provavel', 'wamid', new.wamid,
                                   'visitante_id', c.visitante_id, 'evento_id', c.id));
      end if;
    end if;

    insert into public.whatsapp_cliques_ligacao (wamid, pessoa_id, resultado, evento_id, visitante_id, candidatos)
    values (new.wamid, v_pessoa, v_res, v_ev_id, (select visitante_id from public.eventos where id = v_ev_id), v_cands)
    on conflict (wamid) do nothing;
  exception when others then
    -- a mensagem do cliente vale mais que a ligação: grava o erro e segue
    insert into public.whatsapp_cliques_ligacao (wamid, pessoa_id, resultado, detalhe)
    values (new.wamid, v_pessoa, 'erro', left(sqlerrm, 500))
    on conflict (wamid) do nothing;
  end;
  return null;
end $$;

drop trigger if exists whatsapp_clique on public.whatsapp_mensagens;
create trigger whatsapp_clique
  after update of pessoa_id on public.whatsapp_mensagens
  for each row
  when (old.pessoa_id is null and new.pessoa_id is not null
        and new.direcao = 'entrada' and new.canal = 'ao_vivo' and new.conta)
  execute function public.whatsapp_clique_ligar();

-- 6. o corretor confirma ou descarta o provável (botões da ficha) ----------
create or replace function public.whatsapp_clique_confirmar(p_pessoa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; v_neg uuid;
begin
  if not public.posso_editar() then return jsonb_build_object('ok', false, 'erro', 'sem permissao'); end if;
  select vinculo_site into v from public.pessoas where id = p_pessoa for update;
  if coalesce(v->>'certeza', '') <> 'provavel' then
    return jsonb_build_object('ok', false, 'erro', 'nao ha sugestao para confirmar');
  end if;
  -- o cartão de quando a mensagem chegou, se ainda aberto; senão o aberto mais recente
  select id into v_neg from public.negocios
   where pessoa_id = p_pessoa and fechado_em is null
   order by (id::text = v->>'negocio_id') desc, coalesce(ultima_atividade_em, criado_em) desc limit 1;
  if not public.whatsapp_clique_aplicar(p_pessoa, (v->>'evento_id')::bigint, v_neg, 'confirmado',
                                        v->>'wamid', now(), auth.uid()) then
    return jsonb_build_object('ok', false, 'erro', 'esse visitante ja esta ligado a outra pessoa');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.whatsapp_clique_descartar(p_pessoa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; v_neg uuid;
begin
  if not public.posso_editar() then return jsonb_build_object('ok', false, 'erro', 'sem permissao'); end if;
  select vinculo_site into v from public.pessoas where id = p_pessoa for update;
  if coalesce(v->>'certeza', '') <> 'provavel' then
    return jsonb_build_object('ok', false, 'erro', 'nao ha sugestao para descartar');
  end if;
  update public.pessoas set vinculo_site = v || jsonb_build_object('certeza', 'descartado',
         'descartado_em', now(), 'descartado_por', auth.uid())
   where id = p_pessoa;
  select id into v_neg from public.negocios
   where pessoa_id = p_pessoa and fechado_em is null
   order by (id::text = v->>'negocio_id') desc, coalesce(ultima_atividade_em, criado_em) desc limit 1;
  insert into public.atividades (negocio_id, pessoa_id, tipo, quem, texto, meta)
  values (v_neg, p_pessoa, 'sistema', auth.uid(),
          'Não veio do clique sugerido em "' || coalesce(nullif(v->>'botao', ''), 'WhatsApp') || '" (descartado)',
          jsonb_build_object('fonte', 'whatsapp_clique', 'certeza', 'descartado', 'evento_id', v->'evento_id'));
  return jsonb_build_object('ok', true);
end $$;

-- 7. permissões --------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['whatsapp_normalizar(text)', 'whatsapp_clique_destino(jsonb)', 'whatsapp_clique_ligar()',
                           'whatsapp_clique_aplicar(uuid, bigint, uuid, text, text, timestamptz, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['whatsapp_clique_confirmar(uuid)', 'whatsapp_clique_descartar(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

commit;
