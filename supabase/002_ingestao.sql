-- =====================================================================
-- Ingestão: funções chamadas SÓ pelas funções da Netlify (service_role).
-- Revogadas de anon e authenticated: o navegador nunca chega aqui direto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ingerir_eventos(lote): um lote do rastro.js. Cria/atualiza visitante e
-- sessão, grava os eventos, cola pessoa_id quando o visitante já é lead.
-- lote = {"eventos":[...], "tela":..., "conexao":..., "idioma":..., "fuso":..., "ua":..., "geo":{...}}
-- ---------------------------------------------------------------------
create or replace function public.ingerir_eventos(lote jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  e jsonb; n int := 0;
  v_vid text; v_sid text; v_pessoa uuid;
  geo jsonb := coalesce(lote->'geo', '{}'::jsonb);
begin
  for e in select * from jsonb_array_elements(coalesce(lote->'eventos', '[]'::jsonb)) loop
    v_vid := nullif(e->>'vid', ''); v_sid := nullif(e->>'sid', '');
    if v_vid is null or length(v_vid) > 40 or (e->>'nome') is null then continue; end if;

    insert into public.visitantes (id, primeira_origem, dispositivo, idioma, fuso, tela, ua, cidade_ip, uf_ip, pais_ip, visitas)
    values (v_vid, coalesce(e->'origem_primeira', e->'origem'), e->>'dispositivo', lote->>'idioma', lote->>'fuso', lote->>'tela', lote->>'ua',
            geo->>'cidade', geo->>'uf', geo->>'pais', greatest(1, coalesce((e->>'visitas')::int, 1)))
    on conflict (id) do update set
      ultima_visita = now(),
      visitas = greatest(public.visitantes.visitas, coalesce((excluded.visitas), 1)),
      dispositivo = coalesce(excluded.dispositivo, public.visitantes.dispositivo),
      cidade_ip = coalesce(excluded.cidade_ip, public.visitantes.cidade_ip),
      uf_ip = coalesce(excluded.uf_ip, public.visitantes.uf_ip),
      pais_ip = coalesce(excluded.pais_ip, public.visitantes.pais_ip),
      ua = coalesce(excluded.ua, public.visitantes.ua);

    if v_sid is not null then
      insert into public.sessoes (id, visitante_id, origem, landing, dispositivo, paginas, cliques_contato)
      values (v_sid, v_vid, e->'origem', e->'origem'->>'landing', e->>'dispositivo',
              case when e->>'nome' = 'pagina:view' then 1 else 0 end,
              case when e->>'nome' ~ '_click$|_submit$' then 1 else 0 end)
      on conflict (id) do update set
        ultima_em = now(),
        paginas = public.sessoes.paginas + (case when e->>'nome' = 'pagina:view' then 1 else 0 end),
        cliques_contato = public.sessoes.cliques_contato + (case when e->>'nome' ~ '_click$|_submit$' then 1 else 0 end);
    end if;

    select pessoa_id into v_pessoa from public.visitantes where id = v_vid;

    insert into public.eventos (ts, nome, visitante_id, sessao_id, pessoa_id, pagina, secao, rotulo, interesse, funil, cidade_pagina,
                                origem_tipo, origem_motor, origem_via, dispositivo, props)
    values (
      case when (e->>'ts') ~ '^\d+$' then to_timestamp((e->>'ts')::bigint / 1000.0) else now() end,
      left(e->>'nome', 60), v_vid, v_sid, v_pessoa,
      left(e->>'pagina', 160), left(e->>'secao', 60), left(e->>'rotulo', 120), left(e->>'interesse', 40), left(e->>'funil', 20),
      left(e->>'cidade_pagina', 60),
      left(e->'origem'->>'tipo', 20), left(e->'origem'->>'motor', 60), left(e->'origem'->>'via', 12),
      left(e->>'dispositivo', 12),
      (coalesce(e->'props', '{}'::jsonb)
        || jsonb_build_object('titulo', left(e->>'titulo', 120), 'viewport', e->>'viewport', 'scroll', e->>'scroll', 'tempo', e->>'tempo',
                              'visitas', e->>'visitas', 'utm', e->'origem'->'utm_source', 'referrer_host', e->'origem'->>'referrer_host'))
    );
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- ingerir_lead(d): chamado pelo lead.mjs quando alguém se identifica.
-- Cria ou encontra a pessoa pelo telefone, cria o negócio, cola o
-- histórico do visitante e marca esteve_no_site.
-- d = {nome, telefone, email, cidade, regiao, cidade_ip, uf_ip, vid, sid,
--      ev, pagina, rotulo, secao, tipo, funil, interesse, area, descricao,
--      origem, origem_primeira, visitas, tempo, leitura, trajeto[], cidades[],
--      aceite_texto, observacao, legado}
-- ---------------------------------------------------------------------
create or replace function public.ingerir_lead(d jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  fone text := nullif(regexp_replace(coalesce(d->>'telefone',''), '\D', '', 'g'), '');
  v_pessoa uuid; v_negocio uuid; nova boolean := false;
  v_vid text := nullif(d->>'vid',''); v_sid text := nullif(d->>'sid','');
  historico int := 0; sessoes_antes int := 0;
  v_funil text := lower(coalesce(nullif(d->>'funil',''), 'compra'));
  v_etapa text := 'Novo';
  ultimo uuid;
begin
  if v_funil not in ('compra','venda','servico') then v_funil := 'compra'; end if;

  if fone is not null then
    select id into v_pessoa from public.pessoas where telefone = fone;
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
                                aceite_lgpd_em, aceite_texto, observacoes, legado)
    values (public.proximo_codigo(), left(coalesce(d->>'nome',''),120), fone, d->>'telefone_fmt', left(d->>'email',120),
            left(d->>'cidade',80), left(d->>'regiao',80), left(d->>'cidade_ip',80), left(d->>'uf_ip',4), v_vid,
            (v_vid is not null and (historico > 0 or exists (select 1 from public.eventos where visitante_id = v_vid))),
            coalesce(d->'origem_primeira', d->'origem'), d->'origem',
            nullif(d->>'visitas','')::int, d->>'tempo', nullif(d->>'leitura','')::int,
            (select array_agg(x) from jsonb_array_elements_text(coalesce(d->'trajeto','[]'::jsonb)) x),
            (select array_agg(x) from jsonb_array_elements_text(coalesce(d->'cidades','[]'::jsonb)) x),
            case when d ? 'aceite_texto' then now() end, d->>'aceite_texto', left(d->>'observacao',400), d->'legado')
    returning id into v_pessoa;
  else
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

  -- histórico do navegador cola na pessoa
  if v_vid is not null then
    update public.visitantes set pessoa_id = v_pessoa where id = v_vid;
    update public.eventos set pessoa_id = v_pessoa where visitante_id = v_vid and pessoa_id is null;
  end if;

  -- negócio: reaproveita um aberto do mesmo funil nas últimas 72 h (o
  -- mesmo clique repetido não vira dois cartões); senão cria.
  select id into v_negocio from public.negocios
   where pessoa_id = v_pessoa and funil = v_funil and fechado_em is null and criado_em > now() - interval '72 hours'
   order by criado_em desc limit 1;
  if v_negocio is null then
    insert into public.negocios (pessoa_id, funil, etapa, tipo, interesse, cidade, regiao, area_ha, descricao,
                                 origem_evento, origem_pagina, origem_rotulo, pontuacao)
    values (v_pessoa, v_funil, v_etapa, left(d->>'tipo',40), left(d->>'interesse',200), left(d->>'cidade',80), left(d->>'regiao',80),
            nullif(regexp_replace(coalesce(d->>'area',''), '[^0-9.,]', '', 'g'),'')::numeric,
            left(d->>'descricao',1500), left(d->>'ev',60), left(d->>'pagina',160), left(d->>'rotulo',120),
            -- pontuação simples e explicável: telefone válido, leitura, retorno, histórico, descrição
            (case when fone is not null and length(fone) between 12 and 13 then 30 else 0 end)
            + (case when coalesce(nullif(d->>'leitura','')::int,0) >= 50 then 15 else 0 end)
            + (case when coalesce(nullif(d->>'visitas','')::int,1) > 1 then 15 else 0 end)
            + least(historico, 20)
            + (case when length(coalesce(d->>'descricao','')) > 40 then 20 else 0 end))
    returning id into v_negocio;
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    values (v_negocio, v_pessoa, 'sistema', 'Entrou pelo site', jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo', 'historico', historico, 'sessoes_antes', sessoes_antes));
  else
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    values (v_negocio, v_pessoa, 'sistema', 'Clicou de novo', jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo'));
  end if;

  return jsonb_build_object('pessoa_id', v_pessoa, 'negocio_id', v_negocio, 'nova', nova, 'historico', historico,
                            'codigo', (select codigo from public.pessoas where id = v_pessoa));
end $$;

-- Quem pulou o popup: não é pessoa, mas o visitante fica marcado.
create or replace function public.ingerir_pulo(d jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if nullif(d->>'vid','') is null then return; end if;
  insert into public.visitantes (id) values (d->>'vid') on conflict (id) do nothing;
end $$;

revoke all on function public.ingerir_eventos(jsonb) from public, anon, authenticated;
revoke all on function public.ingerir_lead(jsonb) from public, anon, authenticated;
revoke all on function public.ingerir_pulo(jsonb) from public, anon, authenticated;
