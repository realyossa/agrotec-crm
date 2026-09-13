-- Recupera no CRM os dois leads identificados que o telefone.mjs antigo
-- deixou de fora (31/08/2026). Rodar UMA vez no SQL Editor do Supabase.
-- O telefone digitado por eles foi descartado e nao existe em lugar nenhum:
-- entram sem telefone, com a observacao pedindo conferencia no WhatsApp.
do $$
declare v text; r jsonb;
begin
  -- LEAD-0074 da planilha: Juliano, 30/08 19:49 (BRT), popup do botao flutuante
  select visitante_id into v from public.eventos
   where nome = 'popup:identificacao_submit'
     and ts between '2026-08-30 22:40+00' and '2026-08-30 23:00+00'
   order by ts desc limit 1;
  r := public.ingerir_lead(jsonb_build_object(
    'nome', 'JULIANO VARELA DA SILVA', 'telefone', '',
    'cidade_ip', 'Palhoça', 'uf_ip', 'SC', 'vid', coalesce(v, ''),
    'ev', 'flutuante:whatsapp_click', 'pagina', '/preco-da-terra-santa-catarina',
    'rotulo', 'Botao flutuante - Preco da terra santa catarina',
    'tipo', 'Pericia', 'funil', 'Servico',
    'origem', jsonb_build_object('tipo', 'direto', 'motor', ''),
    'visitas', '1', 'tempo', '2 min',
    'observacao', 'RECUPERADO 31/08: o telefone digitado foi descartado por uma regra antiga de formato (corrigida). Conferir no WhatsApp se ele chegou a mandar mensagem em 30/08 ~19:49. Planilha: LEAD-0074.'));
  update public.negocios set criado_em = '2026-08-30 22:49:11+00' where id = (r->>'negocio_id')::uuid;
  update public.pessoas  set criado_em = '2026-08-30 22:49:11+00', esteve_no_site = true where id = (r->>'pessoa_id')::uuid;

  -- LEAD-0075 da planilha: Elton, 31/08 10:57 (BRT), veio do Bing, hero de /terra-para-plantar-cafe
  select visitante_id into v from public.eventos
   where nome = 'popup:identificacao_submit'
     and ts between '2026-08-31 13:50+00' and '2026-08-31 14:05+00'
   order by ts desc limit 1;
  r := public.ingerir_lead(jsonb_build_object(
    'nome', 'ELTON DA SILVA PEREIRA', 'telefone', '',
    'cidade_ip', 'São Paulo', 'uf_ip', 'SP', 'vid', coalesce(v, ''),
    'ev', 'hero:whatsapp_click', 'pagina', '/terra-para-plantar-cafe',
    'rotulo', 'Hero - Terra para plantar cafe',
    'tipo', 'Arrendamento', 'funil', 'Compra',
    'origem', jsonb_build_object('tipo', 'busca', 'motor', 'Bing', 'via', 'referrer', 'referrer_host', 'bing.com'),
    'visitas', '3', 'tempo', 'menos de 1 min',
    'observacao', 'RECUPERADO 31/08: o telefone digitado foi descartado por uma regra antiga de formato (corrigida). Conferir no WhatsApp se ele chegou a mandar mensagem em 31/08 ~10:57. Planilha: LEAD-0075.'));
  update public.negocios set criado_em = '2026-08-31 13:57:09+00' where id = (r->>'negocio_id')::uuid;
  update public.pessoas  set criado_em = '2026-08-31 13:57:09+00', esteve_no_site = true where id = (r->>'pessoa_id')::uuid;
end $$;

-- conferencia
select codigo, nome, telefone, esteve_no_site, criado_em from public.pessoas order by criado_em desc limit 4;
