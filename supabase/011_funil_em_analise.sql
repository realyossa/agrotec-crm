-- =====================================================================
-- 011 — Funil "Em análise" (28/09/2026)
--
-- POR QUE
-- A trava do mapa do preço da terra (site, js/trava.js) pede nome e WhatsApp
-- a quem quer abrir o 2º município ou estado. Essa pessoa ainda não disse se
-- compra, vende ou só pesquisa. Até aqui o lead chegava com funil vazio e o
-- ingerir_lead o jogava em 'compra': o corretor via um "comprador" que talvez
-- nunca tenha pensado em comprar, e a métrica do funil de compra inflava.
--
-- O QUE MUDA
-- 1. negocios.funil aceita 'analise' (rótulo "Em análise").
-- 2. config.funis ganha o funil, com as etapas Novo, Em contato, Perdido.
--    O corretor qualifica e MUDA O FUNIL do cartão (Compra/Venda/Serviço)
--    pelo "Mudar etapa" do console — o cartão é o mesmo, a história também.
-- 3. ingerir_lead:
--    (a) 'analise' de quem já tem cartão aberto em qualquer funil vai para
--        esse cartão (sem cartão duplicado para quem já é comprador);
--    (b) quem estava em análise e pede compra/venda/serviço pelo site muda
--        o funil do próprio cartão (qualificou-se sozinho);
--    (c) contato repetido registra o "interesse" na linha do tempo (a trava
--        manda o que a pessoa pediu no mapa).
-- 4. Mudança de FUNIL vira atividade, como a de etapa: é o que mede quantos
--    "em análise" viram comprador ou vendedor.
--
-- SEGURANÇA DA ORDEM DE PUBLICAÇÃO
-- Site novo mandando 'analise' com este SQL ainda não aplicado: o
-- ingerir_lead antigo troca por 'compra' (comportamento de hoje). Este SQL
-- aplicado com o site antigo: nada muda. Qualquer ordem é segura.
--
-- Idempotente: pode rodar duas vezes. Aplicar pelo SQL Editor do Supabase
-- (projeto agrotec-crm). Testado em Postgres 16 com 001–010 aplicados.
-- Substitui o ingerir_lead INTEIRO (versao do 006 + os tres trechos acima).
-- O passo 0 confere sozinho que a de producao e a do 006; se nao for, para
-- sem mudar nada.
-- =====================================================================

begin;

-- 0. TRAVA DE SEGURANÇA: esta migração substitui o ingerir_lead INTEIRO.
-- Se o de produção não for exatamente o do 006 (ou já o do 011, quando se
-- roda de novo), alguém mexeu nele direto no painel: para tudo e não muda nada.
do $$
declare h text;
begin
  select md5(prosrc) into h from pg_proc
   where proname = 'ingerir_lead' and pronamespace = 'public'::regnamespace;
  if h is null or h not in ('9d9ec4f0643139535b365a69f80d101d',   -- 006
                            '5354d460ed30d9ff2846c187e1e8c1c2') then -- 011
    raise exception 'PAROU: o ingerir_lead de producao nao e o do 006 (hash %). Nada foi alterado. Mande esta mensagem para o Claude.', h;
  end if;
end $$;

-- 1. restrição do funil --------------------------------------------------
-- Tira QUALQUER check sobre a coluna funil, seja qual for o nome (o banco de
-- producao pode ter nome diferente do que o 001 gera), e poe o novo.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.negocios'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ~ '\mfunil\M'
  loop
    execute format('alter table public.negocios drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.negocios add constraint negocios_funil_check
  check (funil in ('compra','venda','servico','analise'));

-- 2. o funil no console ---------------------------------------------------
update public.config
   set valor = valor || jsonb_build_object('analise',
         jsonb_build_object('rotulo', 'Em análise', 'etapas', jsonb_build_array('Novo','Em contato','Perdido'))),
       atualizado_em = now()
 where chave = 'funis' and not (valor ? 'analise');

-- 3. ingestão -------------------------------------------------------------
create or replace function public.ingerir_lead(d jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  fone text := nullif(regexp_replace(coalesce(d->>'telefone',''), '\D', '', 'g'), '');
  alts jsonb := coalesce(d->'telefone_alternativas', '[]'::jsonb);
  v_pessoa uuid; v_negocio uuid; nova boolean := false;
  v_vid text := nullif(d->>'vid',''); v_sid text := nullif(d->>'sid','');
  historico int := 0; sessoes_antes int := 0;
  v_funil text := lower(coalesce(nullif(d->>'funil',''), 'compra'));
  v_etapa text := 'Novo';
  v_interna boolean := false;
begin
  -- 011: 'analise' passa a valer. O que nao for conhecido continua caindo em
  -- 'compra', como antes (site novo com banco velho, ou o contrario, nao quebra).
  if v_funil not in ('compra','venda','servico','analise') then v_funil := 'compra'; end if;

  if fone is not null then
    select id into v_pessoa from public.pessoas where telefone = fone;
    if v_pessoa is null then
      select id into v_pessoa from public.pessoas
       where telefone_alternativas @> jsonb_build_array(jsonb_build_object('numero', fone))
       limit 1;
    end if;
    if v_pessoa is null and jsonb_array_length(alts) > 0 then
      select p.id into v_pessoa from public.pessoas p
       where p.telefone in (select x->>'numero' from jsonb_array_elements(alts) x)
       limit 1;
    end if;
  end if;
  if v_pessoa is null and v_vid is not null then
    select pessoa_id into v_pessoa from public.visitantes where id = v_vid and pessoa_id is not null;
  end if;

  if v_vid is not null then
    select count(*), count(distinct sessao_id) into historico, sessoes_antes
      from public.eventos where visitante_id = v_vid and (v_sid is null or sessao_id <> v_sid);
  end if;

  if v_pessoa is null then
    nova := true;
    insert into public.pessoas (codigo, nome, telefone, telefone_fmt, email, cidade, regiao, cidade_ip, uf_ip, visitante_id,
                                esteve_no_site, origem_primeira, origem_conversao, visitas, tempo_site, leitura, trajeto, cidades_vistas,
                                aceite_lgpd_em, aceite_texto, observacoes, legado,
                                telefone_conferir, telefone_motivo, telefone_alternativas)
    values (public.proximo_codigo(), left(coalesce(d->>'nome',''),120), fone, d->>'telefone_fmt', left(d->>'email',120),
            left(d->>'cidade',80), left(d->>'regiao',80), left(d->>'cidade_ip',80), left(d->>'uf_ip',4), v_vid,
            (v_vid is not null and (historico > 0 or exists (select 1 from public.eventos where visitante_id = v_vid))),
            coalesce(d->'origem_primeira', d->'origem'), d->'origem',
            nullif(d->>'visitas','')::int, d->>'tempo', nullif(d->>'leitura','')::int,
            (select array_agg(x) from jsonb_array_elements_text(coalesce(d->'trajeto','[]'::jsonb)) x),
            (select array_agg(x) from jsonb_array_elements_text(coalesce(d->'cidades','[]'::jsonb)) x),
            case when d ? 'aceite_texto' then now() end, d->>'aceite_texto', left(d->>'observacao',400), d->'legado',
            coalesce((d->>'telefone_conferir')::boolean, false) and fone is not null,
            case when coalesce((d->>'telefone_conferir')::boolean, false) then nullif(d->>'telefone_motivo','') end,
            alts)
    returning id into v_pessoa;
  else
    if fone is not null then
      update public.pessoas set
        telefone = fone,
        telefone_fmt = d->>'telefone_fmt',
        telefone_conferir = coalesce((d->>'telefone_conferir')::boolean, false),
        telefone_motivo = case when coalesce((d->>'telefone_conferir')::boolean, false) then nullif(d->>'telefone_motivo','') end,
        telefone_alternativas = alts
      where id = v_pessoa and coalesce(telefone,'') = ''
        and not exists (select 1 from public.pessoas p2 where p2.telefone = fone and p2.id <> v_pessoa);
    end if;
    update public.pessoas set
      nome = case when coalesce(nome,'') = '' or nome like '(não informou%' then left(coalesce(d->>'nome',nome),120) else nome end,
      email = coalesce(nullif(left(d->>'email',120),''), email),
      cidade = coalesce(nullif(left(d->>'cidade',80),''), cidade),
      visitante_id = coalesce(visitante_id, v_vid),
      esteve_no_site = esteve_no_site or historico > 0,
      visitas = greatest(coalesce(visitas,0), coalesce(nullif(d->>'visitas','')::int,0)),
      observacoes = case when coalesce(d->>'observacao','') <> '' then concat_ws(E'\n', observacoes, d->>'observacao') else observacoes end
    where id = v_pessoa;
  end if;

  if v_vid is not null then
    update public.visitantes set pessoa_id = v_pessoa where id = v_vid;
    update public.eventos set pessoa_id = v_pessoa where visitante_id = v_vid and pessoa_id is null;
  end if;

  -- gente da casa: registra o contato na linha do tempo e NAO cria cartao
  select interna into v_interna from public.pessoas where id = v_pessoa;
  if coalesce(v_interna, false) then
    insert into public.atividades (pessoa_id, tipo, texto, meta)
    values (v_pessoa, 'sistema', 'Contato pelo site (pessoa interna, sem cartao)', jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo'));
    return jsonb_build_object('ok', true, 'pessoa_id', v_pessoa, 'negocio_id', null, 'nova', nova, 'interna', true);
  end if;

  -- UM cartao por lead e funil: qualquer negocio ABERTO do mesmo funil recebe o
  -- contato novo (e sobe na fila pela atividade). Cartao novo so quando nao ha
  -- nenhum aberto naquele funil. A janela de 72 h que existia aqui foi o que
  -- deu 5 cartoes para a mesma pessoa.
  select id into v_negocio from public.negocios
   where pessoa_id = v_pessoa and funil = v_funil and fechado_em is null
   order by (etapa <> 'Novo') desc, coalesce(ultima_atividade_em, criado_em) desc limit 1;

  -- 011 (a): contato de 'analise' (ex.: trava do mapa) de quem JA tem cartao
  -- aberto em qualquer funil vai para esse cartao — quem ja e comprador nao
  -- ganha um segundo cartao "em analise".
  if v_negocio is null and v_funil = 'analise' then
    select id into v_negocio from public.negocios
     where pessoa_id = v_pessoa and fechado_em is null
     order by (etapa <> 'Novo') desc, coalesce(ultima_atividade_em, criado_em) desc limit 1;
  end if;

  -- 011 (b): quem estava "em analise" e agora pede compra, venda ou servico
  -- pelo site se qualificou sozinho: o MESMO cartao muda de funil, em vez de
  -- nascer um segundo. A mudanca fica na linha do tempo.
  if v_negocio is null and v_funil <> 'analise' then
    select id into v_negocio from public.negocios
     where pessoa_id = v_pessoa and funil = 'analise' and fechado_em is null
     order by coalesce(ultima_atividade_em, criado_em) desc limit 1;
    if v_negocio is not null then
      -- o formulario que qualificou traz o que o cartao em analise nao tinha:
      -- tipo, interesse, area, cidade. A origem (1o toque) fica como estava.
      update public.negocios set
        funil = v_funil,
        tipo = case when coalesce(nullif(d->>'tipo',''),'Outro') <> 'Outro' or coalesce(tipo,'') = '' then left(coalesce(nullif(d->>'tipo',''), tipo),40) else tipo end,
        interesse = coalesce(nullif(left(d->>'interesse',200),''), interesse),
        cidade = coalesce(nullif(left(d->>'cidade',80),''), cidade),
        regiao = coalesce(nullif(left(d->>'regiao',80),''), regiao),
        area_ha = coalesce(nullif(regexp_replace(coalesce(d->>'area',''), '[^0-9.,]', '', 'g'),'')::numeric, area_ha),
        pontuacao = greatest(coalesce(pontuacao,0),
            (case when fone is not null and length(fone) between 12 and 13 then 30 else 0 end)
          + (case when coalesce(nullif(d->>'leitura','')::int,0) >= 50 then 15 else 0 end)
          + (case when coalesce(nullif(d->>'visitas','')::int,1) > 1 then 15 else 0 end)
          + least(historico, 20)
          + (case when length(coalesce(d->>'descricao','')) > 40 then 20 else 0 end))
      where id = v_negocio;
    end if;
  end if;

  if v_negocio is null then
    insert into public.negocios (pessoa_id, funil, etapa, tipo, interesse, cidade, regiao, area_ha, descricao,
                                 origem_evento, origem_pagina, origem_rotulo, pontuacao)
    values (v_pessoa, v_funil, v_etapa, left(d->>'tipo',40), left(d->>'interesse',200), left(d->>'cidade',80), left(d->>'regiao',80),
            nullif(regexp_replace(coalesce(d->>'area',''), '[^0-9.,]', '', 'g'),'')::numeric,
            left(d->>'descricao',1500), left(d->>'ev',60), left(d->>'pagina',160), left(d->>'rotulo',120),
            (case when fone is not null and length(fone) between 12 and 13 then 30 else 0 end)
            + (case when coalesce(nullif(d->>'leitura','')::int,0) >= 50 then 15 else 0 end)
            + (case when coalesce(nullif(d->>'visitas','')::int,1) > 1 then 15 else 0 end)
            + least(historico, 20)
            + (case when length(coalesce(d->>'descricao','')) > 40 then 20 else 0 end))
    returning id into v_negocio;
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    values (v_negocio, v_pessoa, 'sistema', 'Entrou pelo site', jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo', 'historico', historico, 'sessoes_antes', sessoes_antes));
  else
    update public.negocios set ultima_atividade_em = now(),
      -- o cartao guarda o que a pessoa disse por ultimo, quando disse algo
      descricao = case when length(coalesce(d->>'descricao','')) > 0 then left(d->>'descricao',1500) else descricao end
    where id = v_negocio;
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    values (v_negocio, v_pessoa, 'sistema', 'Novo contato pelo site — ' || coalesce(d->>'rotulo','') || ' em ' || coalesce(d->>'pagina','')
            || coalesce(' (' || nullif(left(d->>'interesse',200),'') || ')', ''),
            jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo', 'interesse', d->>'interesse'));
  end if;

  return jsonb_build_object('ok', true, 'pessoa_id', v_pessoa, 'negocio_id', v_negocio, 'nova', nova);
end $$;

revoke all on function public.ingerir_lead(jsonb) from public, anon, authenticated;
grant execute on function public.ingerir_lead(jsonb) to service_role;

-- 4. mudança de funil vira atividade ---------------------------------------
create or replace function public.registrar_etapa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.funil is distinct from old.funil then
    insert into public.atividades (negocio_id, pessoa_id, tipo, quem, texto, meta)
    values (new.id, new.pessoa_id, 'etapa', auth.uid(),
            'Funil: ' || coalesce((select valor->old.funil->>'rotulo' from public.config where chave='funis'), old.funil)
            || ' → ' || coalesce((select valor->new.funil->>'rotulo' from public.config where chave='funis'), new.funil),
            jsonb_build_object('funil_de', old.funil, 'funil_para', new.funil));
  end if;
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

commit;

-- ---------------------------------------------------------------------
-- OPCIONAL, depois de olhar: cartões que vieram da trava do mapa e ainda
-- estão parados em Compra/Novo. Rode o SELECT; se a lista fizer sentido,
-- rode o UPDATE (a mudança de funil fica registrada na linha do tempo).
--
-- So entra cartao cuja TODA entrada pelo site foi a trava (JS ou webhook do
-- form conteudo-acesso): cartao que depois recebeu pedido de compra real fica.
--
-- select n.id, p.codigo, p.nome, n.criado_em, n.origem_rotulo
--   from public.negocios n join public.pessoas p on p.id = n.pessoa_id
--  where n.funil = 'compra' and n.etapa = 'Novo' and n.fechado_em is null
--    and n.primeiro_contato_em is null
--    and (n.origem_evento = 'trava:submit' or n.origem_rotulo like 'trava%'
--         or n.origem_rotulo = 'Formulário - conteudo-acesso')
--    and not exists (select 1 from public.atividades a
--                     where a.negocio_id = n.id and coalesce(a.meta->>'rotulo','') <> ''
--                       and a.meta->>'rotulo' not like 'trava%'
--                       and a.meta->>'rotulo' <> 'Formulário - conteudo-acesso');
--
-- update public.negocios n set funil = 'analise'
--  where n.funil = 'compra' and n.etapa = 'Novo' and n.fechado_em is null
--    and n.primeiro_contato_em is null
--    and (n.origem_evento = 'trava:submit' or n.origem_rotulo like 'trava%'
--         or n.origem_rotulo = 'Formulário - conteudo-acesso')
--    and not exists (select 1 from public.atividades a
--                     where a.negocio_id = n.id and coalesce(a.meta->>'rotulo','') <> ''
--                       and a.meta->>'rotulo' not like 'trava%'
--                       and a.meta->>'rotulo' <> 'Formulário - conteudo-acesso');
-- ---------------------------------------------------------------------
