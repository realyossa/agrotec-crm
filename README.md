# Agrotec · Console de Leads (v2)

Console de leads do site agrotecimobiliarianoagro.com.br. Deploy próprio na
Netlify, banco no Supabase, senha única (um usuário fixo do Supabase Auth). Criado por Yossa Umar — MYIA
VENTURES LTD 17063729.

## Como funciona

```
site (botão com data-ev)  →  site/js/rastro.js  →  /.netlify/functions/evento  →  Supabase: ingerir_eventos()
popup / formulário / portão →  site/js/captacao.js  →  /.netlify/functions/lead  →  planilha (espelho) + Supabase: ingerir_lead()
console (este repositório)  →  Supabase (Auth + RLS + Realtime)
```

- `supabase/001_esquema.sql` — tabelas, views, RLS, gatilhos. Rodar uma vez no SQL Editor.
- `supabase/002_ingestao.sql` — funções chamadas pelas funções da Netlify com a chave de serviço.
- `config.js` — URL, chave **publishable** (pública por desenho), e-mail fixo do login e tema padrão.
- `js/dados.js` — camada de dados (Supabase ou demonstração com `?demo=1`).
- `js/app.js` — telas. `js/graficos.js` — gráficos em canvas.

## Subir do zero (uma vez)

1. **Supabase → SQL Editor**: colar e rodar `supabase/001_esquema.sql`, depois `supabase/002_ingestao.sql`.
2. **Supabase → Authentication → Providers → Email**: deixar "Enable email provider" ligado e **desligar "Allow new users to sign up"**. Quem entra é criado pelo dono em Authentication → Users → Add user (com senha).
3. **Supabase → Project Settings → API**: copiar `Project URL` e `anon public` para `config.js`. Copiar `service_role` para o site (passo 5). O `service_role` nunca entra neste repositório.
4. Depois do primeiro login do dono, no SQL Editor: `update public.perfis set papel = 'dono' where email = 'seu@email';`
5. **Netlify do SITE (agrotec)** → Site configuration → Environment variables: `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY`. Fazer um deploy.
6. **Netlify → Add new site → Import from Git** apontando para este repositório (publish `.`, sem build). Opcional: domínio `leads.agrotecimobiliarianoagro.com.br`.
7. Migrar a planilha: exportar a aba Leads como CSV e rodar `python3 ferramentas/migrar_planilha_crm.py leads.csv > migracao.sql` no repositório do site; colar o SQL no editor.

## Regras que valem aqui

- Página gerada não se edita à mão; botão de contato sem `data-ev` reprova o preflight do site (portão 32).
- O console nunca recebe a chave de serviço. Tudo que ele faz passa por RLS.
- Etapas, motivos de perda e SLA vivem na tabela `config` — mudar lá muda o console.
- A planilha continua como espelho enquanto o dono quiser; a fonte é o banco.
