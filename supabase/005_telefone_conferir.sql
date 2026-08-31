-- 005_telefone_conferir.sql — "aceita tudo, confere depois, tenta as variações".
--
-- POR QUE (31/08/2026): os leads 0074/0075 perderam o único contato porque uma
-- regra de formato apagava o número digitado. A política nova é: o site aceita
-- o que a pessoa digitou; o servidor diagnostica; o CRM mostra "conferir" e as
-- variações determinísticas para TENTAR (hoje: o 9 da migração de 2016 no fixo
-- de 10 dígitos). O número original é sempre o principal — promover uma
-- variação a principal é ato de GENTE, pelo botão "era este" do console.
--
-- Rodar UMA vez no SQL Editor do Supabase (projeto agrotec-crm).

-- 1. Diagnóstico do telefone na ficha da pessoa -------------------------------
alter table public.pessoas
  add column if not exists telefone_conferir boolean not null default false,
  add column if not exists telefone_motivo text,
  add column if not exists telefone_alternativas jsonb not null default '[]'::jsonb;

-- 2. A fila do console passa a enxergar o diagnóstico -------------------------
-- (colunas novas entram no FIM — é o que o CREATE OR REPLACE VIEW permite)
create or replace view public.v_fila with (security_invoker = true) as
select n.*, p.nome as pessoa_nome, p.telefone, p.telefone_fmt, p.codigo, p.cidade as pessoa_cidade,
       p.cidade_ip, p.esteve_no_site, p.origem_conversao, p.origem_primeira, p.visitas, p.leitura,
       pr.nome as corretor_nome,
       extract(epoch from (coalesce(n.primeiro_contato_em, now()) - n.criado_em))/60 as minutos_ate_contato,
       (n.primeiro_contato_em is null) as sem_contato,
       extract(epoch from (now() - coalesce(n.ultima_atividade_em, n.criado_em)))/3600 as horas_parado,
       p.telefone_conferir, p.telefone_motivo, p.telefone_alternativas
from public.negocios n
join public.pessoas p on p.id = n.pessoa_id
left join public.perfis pr on pr.id = n.corretor_id;

-- 3. ingerir_lead: grava o diagnóstico, deduplica também pelas variações, e
--    PREENCHE o telefone de pessoa que existia sem ele (o caminho de
--    recuperação do Juliano e do Elton: se voltarem e se identificarem, o
--    número entra sozinho na ficha).
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
  ultimo uuid;
begin
  if v_funil not in ('compra','venda','servico') then v_funil := 'compra'; end if;

  if fone is not null then
    select id into v_pessoa from public.pessoas where telefone = fone;
    -- o número que chegou é a variação "com 9" de alguém que existe (ou o
    -- contrário): mesma pessoa, duas grafias do mesmo aparelho
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
    -- pessoa que existia SEM telefone ganha o que acabou de chegar (nunca
    -- sobrescreve um telefone existente, e nunca cria duplicata do único)
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
            (case when fone is not null and length(fone) between 12 and 13 then 30 else 0 end)
            + (case when coalesce(nullif(d->>'leitura','')::int,0) >= 50 then 15 else 0 end)
            + (case when coalesce(nullif(d->>'visitas','')::int,1) > 1 then 15 else 0 end)
            + least(historico, 20)
            + (case when length(coalesce(d->>'descricao','')) > 40 then 20 else 0 end))
    returning id into v_negocio;
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    values (v_negocio, v_pessoa, 'sistema', 'Entrou pelo site', jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo', 'historico', historico, 'sessoes_antes', sessoes_antes));
  else
    update public.negocios set ultima_atividade_em = now() where id = v_negocio;
    insert into public.atividades (negocio_id, pessoa_id, tipo, texto, meta)
    values (v_negocio, v_pessoa, 'sistema', 'Novo contato pelo site', jsonb_build_object('ev', d->>'ev', 'pagina', d->>'pagina', 'rotulo', d->>'rotulo'));
  end if;

  return jsonb_build_object('ok', true, 'pessoa_id', v_pessoa, 'negocio_id', v_negocio, 'nova', nova);
end $$;

revoke all on function public.ingerir_lead(jsonb) from public, anon, authenticated;
grant execute on function public.ingerir_lead(jsonb) to service_role;

-- 4. "ERA ESTE" — promover uma variação a número principal. Ato de gente, no
--    console; só aceita número que JÁ está na ficha (principal ou variação) e
--    recusa se outra pessoa já tem o número.
create or replace function public.telefone_confirmado(p_pessoa uuid, p_numero text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare alvo text := nullif(regexp_replace(coalesce(p_numero,''), '\D', '', 'g'), '');
begin
  if alvo is null then return jsonb_build_object('ok', false, 'erro', 'numero vazio'); end if;
  if not exists (select 1 from public.pessoas
                  where id = p_pessoa
                    and (telefone = alvo
                         or telefone_alternativas @> jsonb_build_array(jsonb_build_object('numero', alvo)))) then
    return jsonb_build_object('ok', false, 'erro', 'esse numero nao esta na ficha da pessoa');
  end if;
  if exists (select 1 from public.pessoas where telefone = alvo and id <> p_pessoa) then
    return jsonb_build_object('ok', false, 'erro', 'outra pessoa ja tem esse numero');
  end if;
  update public.pessoas set
    telefone = alvo,
    telefone_fmt = case when length(alvo) = 13 then '(' || substr(alvo,3,2) || ') ' || substr(alvo,5,5) || '-' || substr(alvo,10)
                        when length(alvo) = 12 then '(' || substr(alvo,3,2) || ') ' || substr(alvo,5,4) || '-' || substr(alvo,9)
                        else alvo end,
    telefone_conferir = false,
    telefone_motivo = null,
    telefone_alternativas = '[]'::jsonb
  where id = p_pessoa;
  insert into public.atividades (pessoa_id, tipo, texto)
  values (p_pessoa, 'sistema', 'Telefone confirmado no console: ' || alvo);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.telefone_confirmado(uuid, text) from public, anon;
grant execute on function public.telefone_confirmado(uuid, text) to authenticated, service_role;

-- 5. O fechamento das 19h marca quem precisa de conferência ------------------
create or replace function public.radar_resumo_dia()
returns jsonb
language sql security definer set search_path = public as $$
  with janela as (
    select * from public.eventos where ts >= now() - interval '24 hours'
  )
  select jsonb_build_object(
    'janela_h',         24,
    'visitantes',       (select count(distinct visitante_id) from janela where nome = 'pagina:view'),
    'paginas_vistas',   (select count(*) from janela where nome = 'pagina:view'),
    'cliques_contato',  (select count(*) from janela where nome ~ '^(hero|cta|card|rodape|menu|flutuante|tel|mail|mapa):.*_click$'),
    'formularios',      (select count(*) from janela where nome ~ '^(form|portao|popup):.*submit$'),
    'identificados',    (select count(*) from janela where nome in ('popup:identificacao_submit','form:submit','portao:submit')),
    'abandonos',        (select count(*) from janela where nome in ('form:saida','portao:close','popup:identificacao_close','popup:identificacao_skip')),
    'erros',            (select count(*) from janela where nome in ('form:error','portao:error','pagina:error_404')),
    'visitantes_ia',    (select count(distinct visitante_id) from janela where origem_tipo = 'ia'),
    'leituras_30s',     (select count(*) from janela where nome = 'pagina:leitura_30s'),
    'buscas_sem_resultado', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select props->>'termo' as termo from janela
        where nome = 'busca:resultado_view' and (props->>'resultados')::int = 0 limit 8) t),
    'top_botoes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select nome, count(*) as n from janela
        where nome ~ '_click$' group by 1 order by 2 desc limit 5) t),
    'top_paginas', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select pagina, count(*) as n from janela
        where nome = 'pagina:view' group by 1 order by 2 desc limit 5) t),
    'motores', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select coalesce(nullif(origem_motor,''), case when origem_tipo='direto' then '(direto)' else coalesce(origem_tipo,'(direto)') end) as motor,
               count(distinct visitante_id) as n
        from janela where nome = 'pagina:view' group by 1 order by 2 desc limit 8) t),
    'pessoas_novas', (select count(*) from public.pessoas where criado_em >= now() - interval '24 hours'),
    'pessoas_lista', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select codigo, nome, coalesce(nullif(telefone,''), 'sem telefone') as telefone,
               telefone_conferir as conferir
        from public.pessoas
        where criado_em >= now() - interval '24 hours' and coalesce(nome,'') <> '' and nome not like '(%'
        order by criado_em desc limit 6) t)
  );
$$;

revoke all on function public.radar_resumo_dia() from public, anon, authenticated;
grant execute on function public.radar_resumo_dia() to service_role;

-- conferência rápida depois de rodar:
select column_name from information_schema.columns
 where table_name = 'pessoas' and column_name like 'telefone%' order by 1;
