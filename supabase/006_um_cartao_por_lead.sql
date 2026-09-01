-- 006_um_cartao_por_lead.sql — UM cartão por lead no pipeline, e gente da casa fora da fila.
--
-- POR QUE (31/08/2026): Maria Helena (LEAD-0027) tinha 5 cartões abertos no
-- funil Compra — a migração da planilha criou um negócio por linha, e a regra
-- de ingestão só reaproveitava cartão aberto nas últimas 72 h. Tatiane
-- (LEAD-0042, sócia) tinha 6 cartões "Perdido" e o próprio Yossa (LEAD-0033)
-- dois — gente da casa testando o site vira lead e polui fila e números.
--
-- TRÊS MUDANÇAS:
--   1. regra: um contato novo cai no negócio ABERTO do mesmo funil, qualquer
--      idade. Só nasce cartão novo se não houver nenhum aberto naquele funil.
--      Funis diferentes (compra E venda) continuam sendo cartões diferentes —
--      são negócios diferentes de verdade.
--   2. junção única dos repetidos que já existem: fica o mais avançado (etapa
--      além de "Novo" > já teve contato > mais recente), as atividades dos
--      outros passam para ele, e cada um apagado deixa uma linha na linha do
--      tempo dizendo de onde veio. Nada de histórico se perde.
--   3. pessoas.interna: sócio/corretor/dono marcado como interno não gera
--      negócio, sai da fila, do pipeline e dos números. A marca é feita por
--      gente, no console (botão na ficha), e este script já marca Tatiane e
--      Yossa.
--
-- Rodar UMA vez no SQL Editor do Supabase (projeto agrotec-crm). Idempotente:
-- rodar de novo não junta nem apaga nada a mais.

-- 1. Marca de gente da casa -------------------------------------------------
alter table public.pessoas add column if not exists interna boolean not null default false;

create or replace function public.marcar_interna(p_pessoa uuid, p_valor boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  update public.pessoas set interna = coalesce(p_valor, false) where id = p_pessoa;
  if not found then return jsonb_build_object('ok', false, 'erro', 'pessoa nao encontrada'); end if;
  if coalesce(p_valor, false) then
    -- gente da casa nao tem negocio: os cartoes somem, o historico de site fica
    delete from public.atividades where negocio_id in (select id from public.negocios where pessoa_id = p_pessoa);
    delete from public.negocios where pessoa_id = p_pessoa;
    get diagnostics n = row_count;
    insert into public.atividades (pessoa_id, tipo, texto)
    values (p_pessoa, 'sistema', 'Marcada como pessoa interna (' || n || ' cartao(oes) removido(s))');
  else
    insert into public.atividades (pessoa_id, tipo, texto)
    values (p_pessoa, 'sistema', 'Deixou de ser pessoa interna');
  end if;
  return jsonb_build_object('ok', true, 'removidos', n);
end $$;
revoke all on function public.marcar_interna(uuid, boolean) from public, anon;
grant execute on function public.marcar_interna(uuid, boolean) to authenticated, service_role;

-- a fila enxerga a marca (coluna nova no FIM, como o CREATE OR REPLACE VIEW exige)
create or replace view public.v_fila with (security_invoker = true) as
select n.*, p.nome as pessoa_nome, p.telefone, p.telefone_fmt, p.codigo, p.cidade as pessoa_cidade,
       p.cidade_ip, p.esteve_no_site, p.origem_conversao, p.origem_primeira, p.visitas, p.leitura,
       pr.nome as corretor_nome,
       extract(epoch from (coalesce(n.primeiro_contato_em, now()) - n.criado_em))/60 as minutos_ate_contato,
       (n.primeiro_contato_em is null) as sem_contato,
       extract(epoch from (now() - coalesce(n.ultima_atividade_em, n.criado_em)))/3600 as horas_parado,
       p.telefone_conferir, p.telefone_motivo, p.telefone_alternativas,
       p.interna
from public.negocios n
join public.pessoas p on p.id = n.pessoa_id
left join public.perfis pr on pr.id = n.corretor_id;

-- 2. Regra de ingestão: reaproveita QUALQUER negócio aberto do mesmo funil ---
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
  if v_funil not in ('compra','venda','servico') then v_funil := 'compra'; end if;

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
    values (v_negocio, v_pessoa, 'sistema', 'Novo contato pelo site — ' || coalesce(d->>'rotulo','') || ' em ' || coalesce(d->>'pagina',''), jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo'));
  end if;

  return jsonb_build_object('ok', true, 'pessoa_id', v_pessoa, 'negocio_id', v_negocio, 'nova', nova);
end $$;

revoke all on function public.ingerir_lead(jsonb) from public, anon, authenticated;
grant execute on function public.ingerir_lead(jsonb) to service_role;

-- 3. Junção única dos cartões repetidos que já existem ----------------------
do $$
declare g record; manter uuid; outros uuid[]; n int;
begin
  for g in
    select pessoa_id, funil from public.negocios
     where fechado_em is null group by 1, 2 having count(*) > 1
  loop
    select id into manter from public.negocios
     where pessoa_id = g.pessoa_id and funil = g.funil and fechado_em is null
     order by (etapa <> 'Novo') desc, (primeiro_contato_em is not null) desc,
              coalesce(ultima_atividade_em, criado_em) desc
     limit 1;
    select array_agg(id) into outros from public.negocios
     where pessoa_id = g.pessoa_id and funil = g.funil and fechado_em is null and id <> manter;

    update public.atividades set negocio_id = manter where negocio_id = any(outros);
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    select manter, g.pessoa_id, 'sistema',
           'Cartão repetido juntado a este — veio por ' || coalesce(nullif(origem_rotulo,''), origem_evento, '?')
             || ' em ' || coalesce(origem_pagina,'?') || ' (' || to_char(criado_em, 'DD/MM/YYYY') || ')',
           jsonb_build_object('juntado_de', id, 'origem_evento', origem_evento, 'origem_pagina', origem_pagina,
                              'origem_rotulo', origem_rotulo, 'criado_em', criado_em, 'etapa', etapa)
      from public.negocios where id = any(outros);
    -- o cartao que fica assume a data do PRIMEIRO contato daquela pessoa no funil
    update public.negocios set criado_em = least(criado_em, (select min(criado_em) from public.negocios where id = any(outros)))
     where id = manter;
    delete from public.negocios where id = any(outros);
    get diagnostics n = row_count;
    raise notice 'pessoa % funil %: % cartao(oes) juntado(s) em %', g.pessoa_id, g.funil, n, manter;
  end loop;
end $$;

-- 4. Gente da casa conhecida hoje (31/08/2026): Tatiane (sócia) e Yossa (dono).
--    Jonas e outros: pelo botão "marcar como interno" na ficha, no console.
select codigo, nome, public.marcar_interna(id, true) as resultado
  from public.pessoas where codigo in ('LEAD-0042', 'LEAD-0033') and not interna;

-- conferência: ninguém com mais de um cartão aberto no mesmo funil
select p.codigo, p.nome, n.funil, count(*) as abertos
  from public.negocios n join public.pessoas p on p.id = n.pessoa_id
 where n.fechado_em is null group by 1, 2, 3 having count(*) > 1;
