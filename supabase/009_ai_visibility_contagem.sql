-- 009_ai_visibility_contagem.sql — conserta a contagem da aba "IA lendo o site" (22/09/2026)
--
-- Rodar no SQL Editor depois do 008. Idempotente.
--
-- Dois defeitos apareceram com o primeiro dado real:
--  1. O topo da aba SOMAVA as páginas. Quem chega do ChatGPT e vê três páginas
--     virava três pessoas; o lead que passou por duas páginas virava dois leads.
--     Agora o total sai de v_ia_totais, contado uma vez só por visitante e por pessoa.
--  2. Entravam na conta a pessoa interna (a mesma marcação que já tira gente
--     da fila e dos números, 006) e página que não existe (a
--     /pagina-que-nao-existe-teste-radar do teste do radar, 28/08).

create or replace view public.v_ia_eventos_validos with (security_invoker = true) as
select e.*
from public.eventos e
left join public.visitantes v on v.id = e.visitante_id
left join public.pessoas pe on pe.id = e.pessoa_id
left join public.pessoas pv on pv.id = v.pessoa_id
where e.ts > now() - interval '28 days'
  and e.origem_tipo = 'ia'
  and not coalesce(pe.interna, false)
  and not coalesce(pv.interna, false)
  and not exists (select 1 from public.eventos x
                  where x.pagina = e.pagina and x.nome = 'pagina:error_404');

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
      and finalidade in ('leitura_ia', 'agente_ia'))                         as leituras_ao_vivo,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao <> 'falso' and status_classe = '2xx'
      and finalidade = 'busca_ia')                                           as indice_ia,
  (select count(distinct visitante_id) from public.v_ia_eventos_validos
    where nome = 'pagina:view')                                              as visitantes_vindos_de_ia,
  (select count(distinct pessoa_id) from public.v_ia_eventos_validos)       as leads_vindos_de_ia,
  (select coalesce(sum(n), 0) from public.acesso_agente_dia
    where dia > current_date - 28 and verificacao = 'falso')                as falsos,
  (select min(dia) from public.acesso_agente_dia)                            as medindo_desde;
