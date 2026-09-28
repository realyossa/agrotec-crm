-- =====================================================================
-- 011b — Opcional, rodar DEPOIS do 011 (28/09/2026)
--
-- Os cadastros da trava do mapa feitos ANTES do funil "Em análise" entraram
-- como Compra. Este arquivo move para "Em análise" só os cartões que:
--   - estão em Compra, etapa Novo, abertos;
--   - NINGUÉM contatou ainda (sem primeiro contato registrado);
--   - vieram só pela trava (nenhum outro pedido pelo site no mesmo cartão).
-- Cartão que o corretor já trabalhou ou que teve pedido de compra de verdade
-- fica onde está. A mudança aparece na linha do tempo de cada cartão.
-- O resultado mostra quantos cartões mudaram.
-- =====================================================================
do $$
begin
  if not exists (select 1 from public.config where chave = 'funis' and valor ? 'analise') then
    raise exception 'PAROU: rode primeiro o 011_funil_em_analise.sql. Nada foi alterado.';
  end if;
end $$;

with movidos as (
  update public.negocios n set funil = 'analise'
   where n.funil = 'compra' and n.etapa = 'Novo' and n.fechado_em is null
     and n.primeiro_contato_em is null
     and (n.origem_evento = 'trava:submit' or n.origem_rotulo like 'trava%'
          or n.origem_rotulo = 'Formulário - conteudo-acesso')
     and not exists (select 1 from public.atividades a
                      where a.negocio_id = n.id and coalesce(a.meta->>'rotulo','') <> ''
                        and a.meta->>'rotulo' not like 'trava%'
                        and a.meta->>'rotulo' <> 'Formulário - conteudo-acesso')
  returning n.id
)
select count(*) as cartoes_movidos_para_em_analise from movidos;
