-- =====================================================================
-- 013 — WhatsApp do 2460 no Console (19/10/2026)
--
-- POR QUE
-- O (49) 99838-2460 é o número do site e do Perfil do Google. O Jonas atende
-- pelo WhatsApp Business do celular e vai continuar assim: a ligação com a
-- WhatsApp Business Platform é em COEXISTÊNCIA (decisão do dono, 07/10/2026).
-- A Meta manda uma cópia de cada mensagem para o webhook do site
-- (agrotec/netlify/functions/whatsapp.mjs), que chama ingerir_whatsapp().
-- Objetivo do dono: toda mensagem que entra ou sai do 2460 cai no CRM, num
-- cartão com nome, número e responsável. Captura, não envio.
--
-- O QUE CRIA
--   whatsapp_mensagens  uma linha por mensagem (wamid é a chave: a Meta
--                       reenvia, o banco não duplica)
--   whatsapp_contatos   a agenda do celular (nome que o Jonas deu)
--   whatsapp_conexao    conexão caiu / voltou / foi desfeita / falha de gravação
--   whatsapp_bruto      o POST inteiro da Meta, 90 dias, para auditar e
--                       reprocessar (reprocessar_whatsapp)
--   pessoas.nome_origem / nome_conferir   de onde veio o nome
--   config 'whatsapp'   responsável dos cartões novos (o Jonas) e o número
--
-- REGRAS QUE ESTE SQL IMPÕE
--   1. Nome: agenda do celular > nome deixado no site > nome do perfil do
--      WhatsApp (este marcado "conferir": é o que a pessoa escolheu mostrar,
--      às vezes um apelido ou o nome da fazenda). O número entra sempre.
--   2. Contato novo ganha cartão em "Em análise", responsável Jonas. Quem já
--      tem cartão aberto (em qualquer funil) continua no mesmo cartão e com o
--      mesmo responsável — a mesma regra de "um cartão por lead" do 006/011.
--      Pessoa interna (006) não ganha cartão nem aviso.
--   3. A agenda NÃO cria pessoa: ela tem família e fornecedor. Só dá nome a
--      quem já conversou. O número da própria empresa nunca vira pessoa.
--   4. Mensagem do cliente não é "atendimento". Só a resposta do Jonas vira
--      atividade 'whatsapp' (é o que conta o primeiro contato e o SLA no
--      gatilho apos_atividade do 001). A do cliente sobe o cartão na fila.
--      Reação, apagamento e aviso de sistema (conta = false) não contam para
--      nada disso: são guardados e só.
--   5. Linha do tempo sem enxurrada: uma atividade por rodada de conversa
--      (nada do mesmo lado nas 2 h anteriores), não uma por mensagem. As
--      mensagens inteiras ficam em whatsapp_mensagens.
--   6. Conversa antiga (history, até 180 dias, chega uma vez na conexão, das
--      fases mais novas para as mais velhas) gera cartão em "Em contato",
--      datado do dia da conversa mais antiga — não de hoje. Só pessoa e
--      cartão que NASCERAM do histórico recuam a data quando chega mensagem
--      mais velha. Os que nasceram ao vivo ou do site nunca mudam de data: a
--      data do registro é a prova de lead do site, e recuar um cartão de
--      hoje faria o SLA dizer "esperando há 4 meses" para quem escreveu há 5
--      minutos (revisão independente, 2ª rodada). O primeiro contato nunca
--      fica antes da criação do cartão.
--   7. Dois avisos simultâneos da Meta para o mesmo número esperam um pelo
--      outro (trava por número): sem pessoa nem cartão duplicado.
--
-- ORDEM DE PUBLICAÇÃO
-- Webhook no ar sem este SQL: a RPC não existe, a função responde 500 e a
-- Meta tenta de novo por até 7 dias — nada se perde se o SQL vier depois.
-- Este SQL sem o webhook: tabelas vazias, nada muda no console.
-- Exige o 011 (funil 'analise'): sem ele, para no passo 0 sem mudar nada.
--
-- Idempotente: pode rodar duas vezes. Não substitui nenhuma função existente.
-- Aplicar pelo SQL Editor do Supabase (projeto agrotec-crm).
-- Testado em PGlite (Postgres 17) com 001–012 aplicados:
-- agrotec/ferramentas/testar_whatsapp.mjs.
-- =====================================================================

begin;

-- 0. TRAVA: os cartões novos vão para o funil 'analise', que nasce no 011.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.negocios'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) ~ 'analise') then
    raise exception 'PAROU: o 011 (funil Em analise) nao esta aplicado. Rode o 011 antes. Nada foi alterado.';
  end if;
end $$;

-- 1. de onde veio o nome ----------------------------------------------------
alter table public.pessoas add column if not exists nome_origem text;
alter table public.pessoas add column if not exists nome_conferir boolean not null default false;

-- 2. tabelas ----------------------------------------------------------------
create table if not exists public.whatsapp_mensagens (
  wamid text primary key,
  pessoa_id uuid references public.pessoas(id) on delete cascade,
  negocio_id uuid references public.negocios(id) on delete set null,
  telefone text not null,                      -- do cliente, forma canônica (55..., celular com o 9)
  direcao text not null check (direcao in ('entrada','saida')),
  canal text not null check (canal in ('ao_vivo','historico')),
  formato text not null default 'text',        -- text, image, audio, reaction, media_placeholder...
  conta boolean not null default true,         -- false: reação, apagamento, sistema
  texto text not null default '',
  midia jsonb,                                 -- id na Meta (vale 30 dias), mime, nome
  responde_a text,
  origem text,                                 -- 'site' quando trouxe "Vim pelo site"
  status text,
  status_em timestamptz,
  erros jsonb,
  em timestamptz not null,
  gravado_em timestamptz not null default now(),
  alerta_sem_resposta_em timestamptz           -- aviso de 30 min já entregue no grupo
);
-- banco que rodou uma versão anterior deste arquivo: a coluna chega aqui
alter table public.whatsapp_mensagens add column if not exists conta boolean not null default true;
create index if not exists whatsapp_msg_pessoa on public.whatsapp_mensagens(pessoa_id, em desc);
create index if not exists whatsapp_msg_telefone on public.whatsapp_mensagens(telefone, em desc);
create index if not exists whatsapp_msg_em on public.whatsapp_mensagens(em desc);

create table if not exists public.whatsapp_contatos (
  telefone text primary key,
  nome_agenda text,
  removido boolean not null default false,
  atualizado_em timestamptz not null default now()
);

create table if not exists public.whatsapp_conexao (
  id bigserial primary key,
  em timestamptz not null default now(),
  evento text not null,
  detalhe jsonb
);
create index if not exists whatsapp_conexao_em on public.whatsapp_conexao(em desc);
-- a Meta reenvia o mesmo aviso de conexão com o mesmo horário: entra uma vez
create unique index if not exists whatsapp_conexao_unico on public.whatsapp_conexao(evento, em);

create table if not exists public.whatsapp_bruto (
  id bigserial primary key,
  recebido_em timestamptz not null default now(),
  campos text[],
  payload jsonb not null,
  itens jsonb not null default '[]'::jsonb,
  resultado jsonb
);
create index if not exists whatsapp_bruto_recebido on public.whatsapp_bruto(recebido_em);

-- 3. leitura no console (escrita só pela chave de serviço) -----------------
do $$
declare t text;
begin
  foreach t in array array['whatsapp_mensagens','whatsapp_contatos','whatsapp_conexao','whatsapp_bruto'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists ler on public.%I', t);
    execute format('create policy ler on public.%I for select to authenticated using (public.eu_ativo())', t);
  end loop;
end $$;
-- o corpo bruto tem tudo; só o dono lê
drop policy if exists ler on public.whatsapp_bruto;
create policy ler on public.whatsapp_bruto for select to authenticated using (public.sou_dono());

do $$ begin
  begin alter publication supabase_realtime add table public.whatsapp_mensagens; exception when duplicate_object or undefined_object then null; end;
end $$;

-- 4. responsável padrão e número da empresa ---------------------------------
-- O perfil do Jonas já existe (inativo: o console tem login único). Se não
-- for achado, os cartões nascem sem responsável e o dono escolhe no console;
-- rodar de novo depois de criar o perfil preenche.
insert into public.config (chave, valor)
values ('whatsapp', jsonb_build_object('responsavel', null, 'numero', '5549998382460'))
on conflict (chave) do nothing;
update public.config
   set valor = jsonb_set(valor, '{responsavel}',
         to_jsonb((select id from public.perfis where nome = 'jonasscatolin' order by criado_em limit 1))),
       atualizado_em = now()
 where chave = 'whatsapp' and coalesce(valor->>'responsavel','') = ''
   and exists (select 1 from public.perfis where nome = 'jonasscatolin');

-- 5. achar a pessoa pelo número ---------------------------------------------
-- O webhook já manda o celular com o 9 e a forma sem o 9 em `alts`; o site
-- grava com. Procura o número, as variações e as que a pessoa já tem guardadas.
create or replace function public.whatsapp_achar_pessoa(fone text, alts text[])
returns uuid language sql stable security definer set search_path = public as $$
  select id from (
    select id, 1 as ordem from public.pessoas where telefone = fone
    union all
    select id, 2 from public.pessoas where telefone = any(coalesce(alts, '{}'))
    union all
    select id, 3 from public.pessoas
     where telefone_alternativas @> jsonb_build_array(jsonb_build_object('numero', fone))
  ) x order by ordem limit 1;
$$;

-- o número da empresa nas duas formas (com e sem o 9)
create or replace function public.whatsapp_eh_empresa(fone text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.config c, lateral (select coalesce(c.valor->>'numero','5549998382460') n) x
     where c.chave = 'whatsapp'
       and fone in (x.n, case when length(x.n) = 13 then left(x.n, 4) || substr(x.n, 6) end))
  or fone in ('5549998382460', '554998382460');
$$;

-- 6. um item ----------------------------------------------------------------
create or replace function public.whatsapp_item(it jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tipo text := it->>'tipo';
  v_wamid text := nullif(it->>'wamid','');
  fone text := nullif(regexp_replace(coalesce(it->>'telefone',''), '\D', '', 'g'), '');
  alts text[] := array(select jsonb_array_elements_text(coalesce(it->'alternativas','[]'::jsonb)));
  v_em timestamptz := least(coalesce(nullif(it->>'em','')::timestamptz, now()), now());
  v_direcao text := it->>'direcao';
  v_canal text := case when it->>'canal' = 'historico' then 'historico' else 'ao_vivo' end;
  v_conta boolean := coalesce((it->>'conta')::boolean, true);
  v_texto text := left(coalesce(it->>'texto',''), 65536);
  v_pessoa uuid; v_negocio uuid; v_interna boolean;
  pessoa_nova boolean := false; cartao_novo boolean := false;
  v_nome text; v_nome_agenda text; v_antigo text;
  v_resp uuid; v_criado timestamptz; v_pc_antes timestamptz;
  rank_novo int; rank_velho int;
  trecho text;
begin
  -- ---------------------------------------------------------------- conexão
  if v_tipo = 'conexao' then
    insert into public.whatsapp_conexao (em, evento, detalhe)
    values (v_em, coalesce(nullif(it->>'evento',''),'desconhecido'), it->'detalhe')
    on conflict (evento, em) do nothing;
    return jsonb_build_object('resultado', case when found then 'gravado' else 'repetido' end);
  end if;

  -- ---------------------------------------------------------------- agenda
  if v_tipo = 'contato' then
    if fone is null or public.whatsapp_eh_empresa(fone) then return jsonb_build_object('resultado', 'ignorado'); end if;
    v_nome_agenda := nullif(btrim(it->>'nome_agenda'), '');
    insert into public.whatsapp_contatos (telefone, nome_agenda, removido, atualizado_em)
    values (fone, v_nome_agenda, it->>'acao' = 'remove', now())
    on conflict (telefone) do update set
      nome_agenda = case when excluded.removido then public.whatsapp_contatos.nome_agenda else excluded.nome_agenda end,
      removido = excluded.removido, atualizado_em = now();
    if it->>'acao' <> 'remove' and v_nome_agenda is not null then
      v_pessoa := public.whatsapp_achar_pessoa(fone, alts);
      if v_pessoa is not null then
        select nome into v_antigo from public.pessoas where id = v_pessoa;
        if coalesce(v_antigo,'') is distinct from v_nome_agenda then
          update public.pessoas set nome = v_nome_agenda, nome_origem = 'agenda', nome_conferir = false where id = v_pessoa;
          if coalesce(v_antigo,'') <> '' then
            insert into public.atividades (pessoa_id, tipo, texto, meta)
            values (v_pessoa, 'sistema', 'Nome da agenda do celular: ' || v_nome_agenda || ' (antes: ' || v_antigo || ')',
                    jsonb_build_object('fonte', 'whatsapp_agenda'));
          end if;
        end if;
      end if;
    end if;
    return jsonb_build_object('resultado', 'gravado');
  end if;

  -- ---------------------------------------------------------------- status
  -- Só existe para mensagem enviada pela API (hoje nenhuma). Status nunca
  -- volta para trás: "lida" não vira "entregue" se os avisos chegarem fora
  -- de ordem.
  if v_tipo = 'status' then
    rank_novo := array_position(array['sent','delivered','read','failed'], it->>'status');
    select array_position(array['sent','delivered','read','failed'], status) into rank_velho
      from public.whatsapp_mensagens where wamid = v_wamid;
    update public.whatsapp_mensagens set status = it->>'status', status_em = v_em
     where wamid = v_wamid and coalesce(rank_velho, 0) < coalesce(rank_novo, 0);
    return jsonb_build_object('resultado', case when found then 'gravado' else 'ignorado' end);
  end if;

  if v_tipo <> 'mensagem' or v_wamid is null then
    return jsonb_build_object('resultado', 'ignorado');
  end if;

  -- ------------------------------------------- mídia antiga chegando depois
  if coalesce((it->>'completa_midia')::boolean, false) then
    update public.whatsapp_mensagens set
      formato = coalesce(nullif(it->>'formato',''), formato),
      midia = coalesce(it->'midia', midia),
      texto = case when texto = '' then v_texto else texto end
    where wamid = v_wamid and formato = 'media_placeholder';
    if found then return jsonb_build_object('resultado', 'gravado'); end if;
    if exists (select 1 from public.whatsapp_mensagens where wamid = v_wamid) then
      return jsonb_build_object('resultado', 'repetido');
    end if;
    -- placeholder ainda não chegou: grava como mensagem comum (abaixo)
  end if;

  if fone is null or v_direcao not in ('entrada','saida') or public.whatsapp_eh_empresa(fone) then
    return jsonb_build_object('resultado', 'ignorado');
  end if;

  -- Trava por número até o fim da transação: o segundo POST simultâneo para
  -- o mesmo cliente espera o primeiro gravar a pessoa e o cartão (regra 7).
  perform pg_advisory_xact_lock(hashtext('whatsapp:' || fone));

  -- ---------------------------------------------------------------- mensagem
  insert into public.whatsapp_mensagens (wamid, telefone, direcao, canal, formato, conta, texto, midia, responde_a, origem, status, erros, em)
  values (v_wamid, fone, v_direcao, v_canal, coalesce(nullif(it->>'formato',''), 'text'), v_conta, v_texto, it->'midia',
          nullif(it->>'responde_a',''), nullif(it->>'origem',''), nullif(it->>'status',''), it->'erros', v_em)
  on conflict (wamid) do nothing;
  if not found then return jsonb_build_object('resultado', 'repetido'); end if;

  -- pessoa
  v_pessoa := public.whatsapp_achar_pessoa(fone, alts);
  select nome_agenda into v_nome_agenda from public.whatsapp_contatos
   where (telefone = fone or telefone = any(alts)) and not removido
   order by (telefone = fone) desc limit 1;
  if v_pessoa is null then
    v_nome := coalesce(v_nome_agenda, case when v_direcao = 'entrada' then nullif(btrim(it->>'nome_perfil'),'') end, '');
    begin
      insert into public.pessoas (codigo, criado_em, nome, nome_origem, nome_conferir, telefone, telefone_fmt,
                                  telefone_alternativas, origem_primeira, origem_conversao)
      values (public.proximo_codigo(), v_em, left(v_nome,120),
              case when v_nome_agenda is not null then 'agenda' when v_nome <> '' then 'whatsapp_perfil' end,
              v_nome_agenda is null and v_nome <> '',
              fone, nullif(it->>'telefone_fmt',''),
              coalesce((select jsonb_agg(jsonb_build_object('numero', a, 'porque', 'forma do numero no WhatsApp')) from unnest(alts) a), '[]'::jsonb),
              -- mesmo formato que o chipOrigem do console lê (tipo, motor, via);
              -- `historico` marca quem nasceu da conversa antiga (regra 6)
              jsonb_build_object('tipo', 'whatsapp', 'via', 'whatsapp', 'historico', v_canal = 'historico',
                'motor', case when it->>'origem' = 'site' then 'WhatsApp 2460 (site)' else 'WhatsApp 2460' end),
              jsonb_build_object('tipo', 'whatsapp', 'via', 'whatsapp',
                'motor', case when it->>'origem' = 'site' then 'WhatsApp 2460 (site)' else 'WhatsApp 2460' end))
      returning id into v_pessoa;
      pessoa_nova := true;
    exception when unique_violation then
      -- alguém gravou o mesmo número entre o achar e o gravar (o site, por
      -- outro caminho): é a mesma pessoa
      v_pessoa := public.whatsapp_achar_pessoa(fone, alts);
      if v_pessoa is null then raise; end if;
    end;
  else
    if v_direcao = 'entrada' and nullif(btrim(it->>'nome_perfil'),'') is not null then
      -- nome do perfil só preenche vazio; nunca passa por cima do site nem da agenda
      update public.pessoas set nome = left(btrim(it->>'nome_perfil'),120), nome_origem = 'whatsapp_perfil', nome_conferir = true
       where id = v_pessoa and (coalesce(nome,'') = '' or nome like '(não informou%');
    end if;
    -- quem nasceu do histórico recua a data para a conversa mais antiga (regra 6)
    update public.pessoas set criado_em = v_em
     where id = v_pessoa and criado_em > v_em and origem_primeira->>'historico' = 'true';
  end if;

  select interna into v_interna from public.pessoas where id = v_pessoa;

  if not coalesce(v_interna, false) then
    -- um cartão por lead: qualquer cartão aberto, na ordem do 011
    select id into v_negocio from public.negocios
     where pessoa_id = v_pessoa and fechado_em is null
     order by (etapa <> 'Novo') desc, coalesce(ultima_atividade_em, criado_em) desc limit 1;

    if v_negocio is null then
      cartao_novo := true;
      select nullif(valor->>'responsavel','')::uuid into v_resp from public.config where chave = 'whatsapp';
      if v_resp is not null and not exists (select 1 from public.perfis where id = v_resp) then v_resp := null; end if;
      insert into public.negocios (pessoa_id, funil, etapa, corretor_id, criado_em, origem_evento, origem_rotulo, interesse)
      values (v_pessoa, 'analise',
              case when v_canal = 'historico' or v_direcao = 'saida' then 'Em contato' else 'Novo' end,
              v_resp, v_em,
              case when v_canal = 'historico' then 'whatsapp:historico'
                   else 'whatsapp:' || coalesce(nullif(it->>'origem',''), 'whatsapp') end,
              case when v_canal = 'historico' then 'WhatsApp 2460 (conversa antiga)'
                   when it->>'origem' = 'site' then 'WhatsApp 2460 (veio pelo site)'
                   else 'WhatsApp 2460' end,
              case when v_direcao = 'entrada' and v_conta then nullif(left(v_texto,200),'') end)
      returning id into v_negocio;
      insert into public.atividades (negocio_id, pessoa_id, tipo, em, texto, meta)
      values (v_negocio, v_pessoa, 'sistema', v_em,
              case when v_canal = 'historico' then 'Conversa antiga importada do WhatsApp 2460' else 'Entrou pelo WhatsApp 2460' end,
              jsonb_build_object('wamid', v_wamid, 'origem', it->>'origem'));
    else
      -- cartão que nasceu do histórico recua para a conversa mais antiga; o ao vivo e o do site, nunca
      update public.negocios set criado_em = v_em
       where id = v_negocio and criado_em > v_em and origem_evento = 'whatsapp:historico';
    end if;
  end if;

  update public.whatsapp_mensagens set pessoa_id = v_pessoa, negocio_id = v_negocio where wamid = v_wamid;

  -- linha do tempo: uma atividade por rodada, não por mensagem (regra 5);
  -- reação e aviso de sistema não entram (regra 4)
  trecho := case when v_texto <> '' then left(v_texto, 280) else '[' || coalesce(nullif(it->>'formato',''),'mensagem') || ']' end;
  if v_negocio is not null and v_conta and not exists (
       select 1 from public.whatsapp_mensagens
        where pessoa_id = v_pessoa and direcao = v_direcao and conta and wamid <> v_wamid
          and em between v_em - interval '2 hours' and v_em) then
    if v_direcao = 'saida' then
      select primeiro_contato_em, criado_em into v_pc_antes, v_criado from public.negocios where id = v_negocio;
      insert into public.atividades (negocio_id, pessoa_id, tipo, em, texto, meta)
      values (v_negocio, v_pessoa, 'whatsapp', v_em, 'Respondeu pelo WhatsApp 2460: ' || trecho,
              jsonb_build_object('wamid', v_wamid, 'canal', v_canal));
      -- O gatilho do 001 grava o primeiro contato na ordem de chegada. Aqui
      -- vale o mais cedo, mas nunca antes de o cartão existir: resposta de
      -- meses atrás num cartão do site de hoje não é "contato em 0 minutos".
      update public.negocios set primeiro_contato_em =
             case when v_em < v_criado then v_pc_antes else least(coalesce(v_pc_antes, v_em), v_em) end
       where id = v_negocio;
    elsif not cartao_novo then
      insert into public.atividades (negocio_id, pessoa_id, tipo, em, texto, meta)
      values (v_negocio, v_pessoa, 'sistema', v_em, 'Mensagem pelo WhatsApp 2460: ' || trecho,
              jsonb_build_object('wamid', v_wamid, 'canal', v_canal));
    end if;
  end if;
  if v_negocio is not null and v_direcao = 'entrada' and v_conta then
    update public.negocios set ultima_atividade_em = greatest(coalesce(ultima_atividade_em, v_em), v_em)
     where id = v_negocio;
  end if;

  -- aviso de conversa nova: cliente escrevendo ao vivo depois de 12 h quieto
  if v_canal = 'ao_vivo' and v_direcao = 'entrada' and v_conta and not coalesce(v_interna, false) and not exists (
       select 1 from public.whatsapp_mensagens
        where pessoa_id = v_pessoa and wamid <> v_wamid and conta and em > v_em - interval '12 hours') then
    return jsonb_build_object('resultado', 'gravado', 'nova', (
      select jsonb_build_object('codigo', p.codigo, 'nome', p.nome, 'telefone', p.telefone,
                                'origem', it->>'origem', 'cartao_novo', cartao_novo, 'pessoa_nova', pessoa_nova)
        from public.pessoas p where p.id = v_pessoa));
  end if;
  return jsonb_build_object('resultado', 'gravado');
end $$;

-- 7. o lote do webhook ------------------------------------------------------
-- Cada item roda no próprio subbloco: um item torto não derruba os outros.
-- O que falhou volta em `falhas` — o webhook então responde 500 e a Meta
-- reenvia (o que entrou volta como repetido) — e fica em
-- whatsapp_bruto.resultado; reprocessar_whatsapp(id) refaz depois do conserto.
create or replace function public.whatsapp_processar(p_itens jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; r jsonb;
  gravados int := 0; repetidos int := 0; ignorados int := 0;
  falhas jsonb := '[]'::jsonb; novas jsonb := '[]'::jsonb; conexao jsonb := '[]'::jsonb;
begin
  -- Ordem por número e hora: dois lotes simultâneos pegam as travas por
  -- número na mesma ordem e nunca se esperam em círculo; e as mensagens de
  -- cada pessoa entram na ordem em que aconteceram.
  -- No empate (mesmo número, mesmo segundo) vale a ordem em que a Meta mandou.
  for it in select x.value from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) with ordinality x(value, pos)
             order by x.value->>'telefone' nulls first, x.value->>'em', x.pos loop
    begin
      r := public.whatsapp_item(it);
      case r->>'resultado'
        when 'gravado' then gravados := gravados + 1;
        when 'repetido' then repetidos := repetidos + 1;
        else ignorados := ignorados + 1;
      end case;
      if r ? 'nova' then novas := novas || jsonb_build_array(r->'nova'); end if;
      if it->>'tipo' = 'conexao' and r->>'resultado' = 'gravado' then
        conexao := conexao || jsonb_build_array(jsonb_build_object('evento', it->>'evento', 'motivo', it#>>'{detalhe,desconexao,reason}'));
      end if;
    exception when others then
      falhas := falhas || jsonb_build_array(jsonb_build_object('wamid', it->>'wamid', 'tipo', it->>'tipo', 'erro', sqlerrm));
    end;
  end loop;
  return jsonb_build_object('gravados', gravados, 'repetidos', repetidos, 'ignorados', ignorados,
                            'falhas', falhas, 'novas', novas, 'conexao', conexao);
end $$;

create or replace function public.ingerir_whatsapp(lote jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; r jsonb;
begin
  -- só a primeira fatia de um POST grande traz o corpo; as outras, só itens
  insert into public.whatsapp_bruto (campos, payload, itens)
  values (array(select jsonb_array_elements_text(coalesce(lote->'campos','[]'::jsonb))),
          case when jsonb_typeof(lote->'bruto') = 'object' then lote->'bruto'
               else jsonb_build_object('fatia', true) end,
          coalesce(lote->'itens', '[]'::jsonb))
  returning id into v_id;
  r := public.whatsapp_processar(lote->'itens');
  if nullif(lote->>'erro_desmonte','') is not null then
    r := r || jsonb_build_object('erro_desmonte', lote->>'erro_desmonte');
  end if;
  update public.whatsapp_bruto set resultado = r - 'novas' where id = v_id;
  if jsonb_array_length(r->'falhas') > 0 or r ? 'erro_desmonte' then
    insert into public.whatsapp_conexao (evento, detalhe)
    values ('FALHA_GRAVACAO', jsonb_build_object('bruto_id', v_id, 'falhas', r->'falhas', 'erro_desmonte', r->'erro_desmonte'))
    on conflict (evento, em) do nothing;
  end if;
  -- 90 dias de corpo bruto bastam para auditar; as mensagens ficam nas tabelas
  delete from public.whatsapp_bruto where recebido_em < now() - interval '90 days';
  return r || jsonb_build_object('bruto_id', v_id);
end $$;

create or replace function public.reprocessar_whatsapp(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  r := public.whatsapp_processar((select itens from public.whatsapp_bruto where id = p_id));
  update public.whatsapp_bruto set resultado = (r - 'novas') || jsonb_build_object('reprocessado_em', now()) where id = p_id;
  return r;
end $$;

-- 8. sem resposta -----------------------------------------------------------
-- Chamado a cada 10 min pela função agendada do site. Usa o SLA da config
-- (minutos, horário e dias de atendimento): mensagem às 23h não acorda
-- ninguém; o relógio começa quando abre o expediente. LISTA sem marcar: a
-- função do site marca (whatsapp_marcar_avisados) só depois que o Telegram
-- confirmou — aviso que não chegou é tentado de novo.
create or replace function public.whatsapp_sem_resposta()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb := coalesce((select valor from public.config where chave = 'sla'), '{}'::jsonb);
  minutos int := coalesce(nullif(s->>'minutos','')::int, 30);
  fuso text := coalesce(nullif(s->>'fuso',''), 'America/Sao_Paulo');
  ini time := coalesce(nullif(s#>>'{horario,inicio}','')::time, '08:00');
  fim time := coalesce(nullif(s#>>'{horario,fim}','')::time, '18:30');
  -- dias como o console grava: 0 = domingo ... 6 = sábado (getDay do JS = dow do Postgres)
  dias int[] := case when jsonb_typeof(s#>'{horario,dias}') = 'array'
                     then array(select jsonb_array_elements_text(s#>'{horario,dias}')::int)
                     else array[1,2,3,4,5,6] end;
  agora timestamp := now() at time zone fuso;
  abertura timestamptz := (date_trunc('day', now() at time zone fuso) + ini) at time zone fuso;
begin
  if not (extract(dow from agora)::int = any(dias) and agora::time between ini and fim) then
    return '[]'::jsonb;
  end if;
  -- Por pessoa: a última resposta do Jonas e a PRIMEIRA mensagem do cliente
  -- depois dela. O relógio conta dessa primeira (ou da abertura do
  -- expediente de hoje, o que for mais tarde). Um aviso por rodada: se já
  -- houve aviso depois da última resposta, o cliente insistir não avisa de novo.
  return coalesce((
    with por_pessoa as (
      select m.pessoa_id, max(m.em) filter (where m.direcao = 'saida') as ultima_resposta
        from public.whatsapp_mensagens m
       where m.canal = 'ao_vivo' and m.conta and m.pessoa_id is not null and m.em > now() - interval '3 days'
       group by m.pessoa_id
    ), primeira as (
      select distinct on (m.pessoa_id) m.wamid, m.pessoa_id, m.em
        from public.whatsapp_mensagens m
        join por_pessoa pp on pp.pessoa_id = m.pessoa_id
       where m.canal = 'ao_vivo' and m.conta and m.direcao = 'entrada'
         and m.em > coalesce(pp.ultima_resposta, '-infinity'::timestamptz)
         and m.em > now() - interval '3 days'
         and not exists (select 1 from public.whatsapp_mensagens a
                          where a.pessoa_id = m.pessoa_id and a.direcao = 'entrada'
                            and a.alerta_sem_resposta_em is not null
                            and a.em > coalesce(pp.ultima_resposta, '-infinity'::timestamptz))
       order by m.pessoa_id, m.em
    )
    select jsonb_agg(jsonb_build_object('wamid', pr.wamid, 'codigo', p.codigo, 'nome', p.nome,
                                        'telefone', p.telefone, 'desde', pr.em) order by pr.em)
      from primeira pr
      join public.pessoas p on p.id = pr.pessoa_id and not p.interna
     where now() - greatest(pr.em, abertura) > make_interval(mins => minutos)
  ), '[]'::jsonb);
end $$;

create or replace function public.whatsapp_marcar_avisados(p_wamids jsonb)
returns int language sql security definer set search_path = public as $$
  with m as (
    update public.whatsapp_mensagens set alerta_sem_resposta_em = now()
     where wamid in (select jsonb_array_elements_text(coalesce(p_wamids, '[]'::jsonb)))
       and alerta_sem_resposta_em is null
    returning 1)
  select count(*)::int from m;
$$;

-- 9. só a chave de serviço executa -----------------------------------------
do $$
declare f text;
begin
  foreach f in array array['whatsapp_achar_pessoa(text, text[])', 'whatsapp_eh_empresa(text)', 'whatsapp_item(jsonb)',
                           'whatsapp_processar(jsonb)', 'ingerir_whatsapp(jsonb)', 'reprocessar_whatsapp(bigint)',
                           'whatsapp_sem_resposta()', 'whatsapp_marcar_avisados(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
