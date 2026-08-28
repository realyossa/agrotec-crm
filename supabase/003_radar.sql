-- 003_radar.sql — funções do radar do Telegram.
-- Rodar uma vez no SQL Editor, depois de 001 e 002.
-- Só a chave de serviço executa (revogadas de anon/authenticated).

-- Quem é este visitante? (nome/código/etapa se já virou lead)
create or replace function public.radar_contexto(v_vid text)
returns jsonb
language sql security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object(
      'nome', p.nome,
      'codigo', p.codigo,
      'etapa', (select n.etapa from public.negocios n
                where n.pessoa_id = p.id order by n.criado_em desc limit 1)
    )
    from public.pessoas p
    where p.visitante_id = v_vid
      and coalesce(p.nome, '') <> ''
    limit 1
  ), '{}'::jsonb);
$$;

-- Resumo do dia para o fechamento das 19h.
create or replace function public.radar_resumo_dia()
returns jsonb
language sql security definer set search_path = public as $$
  with hoje as (
    select * from public.eventos
    where ts >= (now() at time zone 'America/Sao_Paulo')::date::timestamp at time zone 'America/Sao_Paulo'
  )
  select jsonb_build_object(
    'visitantes',       (select count(distinct visitante_id) from hoje where nome = 'pagina:view'),
    'paginas_vistas',   (select count(*) from hoje where nome = 'pagina:view'),
    'cliques_contato',  (select count(*) from hoje where nome ~ '^(hero|cta|card|rodape|menu|flutuante|tel|mail|mapa):.*_click$'),
    'formularios',      (select count(*) from hoje where nome ~ '^(form|portao|popup):.*submit$'),
    'abandonos',        (select count(*) from hoje where nome in ('form:saida','portao:close','popup:identificacao_close','popup:identificacao_skip')),
    'erros',            (select count(*) from hoje where nome in ('form:error','portao:error','pagina:error_404')),
    'visitantes_ia',    (select count(distinct visitante_id) from hoje where origem_tipo = 'ia'),
    'leituras_30s',     (select count(*) from hoje where nome = 'pagina:leitura_30s'),
    'buscas_sem_resultado', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select props->>'termo' as termo from hoje
        where nome = 'busca:resultado_view' and (props->>'resultados')::int = 0 limit 8) t),
    'top_botoes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select nome, count(*) as n from hoje
        where nome ~ '_click$' group by 1 order by 2 desc limit 5) t),
    'top_paginas', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select pagina, count(*) as n from hoje
        where nome = 'pagina:view' group by 1 order by 2 desc limit 5) t),
    'motores', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select coalesce(nullif(origem_motor,''), case when origem_tipo='direto' then '(direto)' else coalesce(origem_tipo,'(direto)') end) as motor,
               count(distinct visitante_id) as n
        from hoje where nome = 'pagina:view' group by 1 order by 2 desc limit 8) t),
    'pessoas_novas', (select count(*) from public.pessoas
        where criado_em >= (now() at time zone 'America/Sao_Paulo')::date::timestamp at time zone 'America/Sao_Paulo')
  );
$$;

revoke all on function public.radar_contexto(text) from public, anon, authenticated;
revoke all on function public.radar_resumo_dia() from public, anon, authenticated;
grant execute on function public.radar_contexto(text) to service_role;
grant execute on function public.radar_resumo_dia() to service_role;
