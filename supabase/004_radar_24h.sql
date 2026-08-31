-- 004_radar_24h.sql — o fechamento das 19h passa a cobrir 24 h (19h → 19h).
-- Motivo (31/08/2026): o resumo de 30/08 disse "0 leads" e era verdade até as
-- 19h — o lead do dia se identificou às 19:49 e caiu fora da janela. Janela de
-- dia-calendário fechada às 19h esconde a noite inteira; 24 h não esconde nada.
-- Também entra "identificados" (popup/formulário/portão enviados), medido pelos
-- eventos do site — não depende do CRM ter gravado a pessoa.

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
        select codigo, nome, coalesce(nullif(telefone,''), 'sem telefone') as telefone from public.pessoas
        where criado_em >= now() - interval '24 hours' and coalesce(nome,'') <> '' and nome not like '(%'
        order by criado_em desc limit 6) t)
  );
$$;

revoke all on function public.radar_resumo_dia() from public, anon, authenticated;
grant execute on function public.radar_resumo_dia() to service_role;
