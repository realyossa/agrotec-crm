// dados.js — camada de dados do console. Dois provedores com a MESMA
// interface: Supabase (produção) e Demo (dados de exemplo, sem rede, para
// o protótipo e para mostrar o console sem chave).
//
// Tudo que a tela precisa passa por aqui. A tela nunca monta SQL.

const C = window.CONSOLE_CONFIG || {};
export const DEMO = new URLSearchParams(location.search).has('demo') || !C.supabaseUrl || C.supabaseUrl.indexOf('COLE_') === 0;

/* ============================================================ Supabase */
let sb = null;
async function cliente() {
  if (sb) return sb;
  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
  sb = createClient(C.supabaseUrl, C.supabaseAnonKey, { auth: { persistSession: true, autoRefreshToken: true } });
  return sb;
}

const provSupabase = {
  async sessao() { const s = await cliente(); const { data } = await s.auth.getSession(); return data.session; },
  async entrar(email, senha) { const s = await cliente(); const { data, error } = await s.auth.signInWithPassword({ email, password: senha }); if (error) throw error; return data.session; },
  async sair() { const s = await cliente(); await s.auth.signOut(); },
  async recuperar(email) { const s = await cliente(); const { error } = await s.auth.resetPasswordForEmail(email, { redirectTo: location.origin }); if (error) throw error; },
  async trocarSenha(nova) { const s = await cliente(); const { error } = await s.auth.updateUser({ password: nova }); if (error) throw error; },
  aoMudarAuth(cb) { cliente().then(s => s.auth.onAuthStateChange((ev, sess) => cb(ev, sess))); },

  async perfil() { const s = await cliente(); const { data: u } = await s.auth.getUser(); if (!u?.user) return null;
    const { data } = await s.from('perfis').select('*').eq('id', u.user.id).single(); return data || { id: u.user.id, nome: u.user.email, email: u.user.email, papel: 'leitura', ativo: false }; },
  async perfis() { const s = await cliente(); const { data } = await s.from('perfis').select('*').order('nome'); return data || []; },
  async config() { const s = await cliente(); const { data } = await s.from('config').select('*'); const o = {}; (data || []).forEach(r => o[r.chave] = r.valor); return o; },

  async kpis() { const s = await cliente(); const { data } = await s.from('v_kpis').select('*').single(); return data || {}; },
  async serie(dias = 28) { const s = await cliente(); const { data } = await s.from('v_serie_diaria').select('*'); return (data || []).slice(-dias); },
  async pessoasPorDia() { const s = await cliente(); const { data } = await s.from('v_pessoas_por_dia').select('*'); return data || []; },
  async motores() { const s = await cliente(); const { data } = await s.from('v_motores').select('*'); return data || []; },
  async origensEvento() { const s = await cliente(); const { data } = await s.from('v_origens_evento').select('*'); return data || []; },
  async fila() { const s = await cliente(); const { data } = await s.from('v_fila').select('*').order('criado_em', { ascending: false }).limit(500); return data || []; },
  async pessoas(q) { const s = await cliente(); let r = s.from('pessoas').select('*, negocios(*)').order('criado_em', { ascending: false }).limit(300);
    if (q) r = r.or(`nome.ilike.%${q}%,telefone.ilike.%${q}%,codigo.ilike.%${q}%,cidade.ilike.%${q}%`); const { data } = await r; return data || []; },
  async pessoa(id) { const s = await cliente();
    const [{ data: p }, { data: n }, { data: a }, { data: e }] = await Promise.all([
      s.from('pessoas').select('*').eq('id', id).single(),
      s.from('negocios').select('*, perfis(nome)').eq('pessoa_id', id).order('criado_em', { ascending: false }),
      s.from('atividades').select('*, perfis(nome)').eq('pessoa_id', id).order('em', { ascending: false }).limit(200),
      s.from('eventos').select('*').eq('pessoa_id', id).order('ts', { ascending: false }).limit(300)
    ]);
    return { pessoa: p, negocios: n || [], atividades: a || [], eventos: e || [] }; },
  async moverEtapa(negocioId, etapa, motivo) { const s = await cliente(); const { error } = await s.from('negocios').update({ etapa, motivo_perda: motivo || null }).eq('id', negocioId); if (error) throw error; },
  async editarNegocio(id, campos) { const s = await cliente(); const { error } = await s.from('negocios').update(campos).eq('id', id); if (error) throw error; },
  async criarNegocio(campos) { const s = await cliente(); const { error } = await s.from('negocios').insert(campos); if (error) throw error; },
  async editarPessoa(id, campos) { const s = await cliente(); const { error } = await s.from('pessoas').update(campos).eq('id', id); if (error) throw error; },
  // "era este": promove uma variação a número principal. A regra mora no
  // banco (telefone_confirmado): só número que já está na ficha, e nunca um
  // que outra pessoa já tenha.
  async telefoneConfirmado(pessoaId, numero) { const s = await cliente(); const { data, error } = await s.rpc('telefone_confirmado', { p_pessoa: pessoaId, p_numero: numero }); if (error) throw error; return data; },
  // gente da casa: a regra (apagar cartoes, impedir novos) mora no banco (marcar_interna)
  async marcarInterna(pessoaId, valor) { const s = await cliente(); const { data, error } = await s.rpc('marcar_interna', { p_pessoa: pessoaId, p_valor: !!valor }); if (error) throw error; return data; },
  async atividade(a) { const s = await cliente(); const { data: u } = await s.auth.getUser(); const { error } = await s.from('atividades').insert({ ...a, quem: u?.user?.id || null }); if (error) throw error; },
  async atualizarPerfil(id, campos) { const s = await cliente(); const { error } = await s.from('perfis').update(campos).eq('id', id); if (error) throw error; },
  async salvarConfig(chave, valor) { const s = await cliente(); const { error } = await s.from('config').upsert({ chave, valor, atualizado_em: new Date().toISOString() }); if (error) throw error; },
  aoVivo(cb) { cliente().then(s => { s.channel('console').on('postgres_changes', { event: '*', schema: 'public', table: 'negocios' }, cb)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'atividades' }, cb)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'pessoas' }, cb).subscribe(); }); }
};

/* ================================================================ Demo */
function demoDados() {
  const hoje = new Date(); hoje.setHours(12, 0, 0, 0);
  const dia = d => { const x = new Date(hoje); x.setDate(x.getDate() - d); return x; };
  const iso = d => d.toISOString();
  const motores = [['Google', 'busca'], ['ChatGPT', 'ia'], ['(direto)', 'direto'], ['Bing', 'busca'], ['Perplexity', 'ia'], ['Instagram', 'social'], ['Gemini', 'ia'], ['Claude', 'ia']];
  const nomes = ['Valdir Antunes', 'Marlene Bortoluzzi', 'Jair Piovesan', '(não informou)', 'Cleusa Dallagnol', 'Roberto Zanella', 'Adriana Menegatti', 'Ivo Sartori', '(não informou)', 'Lucimar Bressan', 'Nelson Grando', 'Paulo Cézar Rech', 'Sirlei Fávero', 'Ademir Lazzari', 'Edson Tomazi', 'Neuza Baldissera'];
  const cidades = ['Chapecó', 'Xanxerê', 'Concórdia', 'Xaxim', 'Palmitos', 'Abelardo Luz', 'Cordilheira Alta', 'Curitiba', 'São Paulo'];
  const tipos = [['Sitio', 'compra'], ['Fazenda', 'compra'], ['Chacara', 'compra'], ['Venda', 'venda'], ['Georreferenciamento', 'servico'], ['Arrendamento', 'compra'], ['Avaliacao', 'servico']];
  const evs = ['cta:whatsapp_click', 'rodape:whatsapp_click', 'hero:whatsapp_click', 'flutuante:whatsapp_click', 'form:submit', 'portao:submit', 'tel:telefone_click', 'card:whatsapp_click', 'popup:identificacao_submit'];
  const etapasC = ['Novo', 'Em contato', 'Visita agendada', 'Proposta enviada', 'Fechado', 'Perdido'];
  const perfis = [{ id: 'u1', nome: 'Jonas Scatolin', papel: 'corretor', email: 'jonas@agrotec.com.br', ativo: true }, { id: 'u2', nome: 'Tatiane Scatolin', papel: 'corretor', email: 'tatiane@agrotec.com.br', ativo: true }, { id: 'u0', nome: 'Yossa Umar', papel: 'dono', email: 'yossa@myia.ventures', ativo: true }];
  let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const pessoas = [], negocios = [], atividades = [], eventos = [];
  for (let i = 0; i < 46; i++) {
    const d = dia(Math.floor(rnd() * 27)); d.setHours(7 + Math.floor(rnd() * 13), Math.floor(rnd() * 60));
    const m = motores[Math.floor(rnd() * motores.length)];
    const nome = nomes[i % nomes.length]; const [tipo, funil] = tipos[Math.floor(rnd() * tipos.length)];
    const ev = evs[Math.floor(rnd() * evs.length)];
    const p = { id: 'p' + i, codigo: 'LEAD-' + String(120 - i).padStart(4, '0'), criado_em: iso(d), nome, telefone: nome.startsWith('(') ? null : '5549' + String(990000000 + Math.floor(rnd() * 9999999)),
      telefone_fmt: nome.startsWith('(') ? '' : '(49) 9' + String(9000000 + Math.floor(rnd() * 999999)).replace(/(\d{4})(\d{4})/, '$1-$2'),
      cidade: cidades[Math.floor(rnd() * cidades.length)], cidade_ip: cidades[Math.floor(rnd() * 7)], esteve_no_site: rnd() > .25,
      origem_conversao: { tipo: m[1], motor: m[0] === '(direto)' ? '' : m[0], via: m[1] === 'ia' && rnd() > .5 ? 'utm' : 'referrer' }, origem_primeira: { tipo: m[1], motor: m[0] === '(direto)' ? '' : m[0] },
      visitas: 1 + Math.floor(rnd() * 4), leitura: Math.floor(rnd() * 100), trajeto: ['/', '/' + tipo.toLowerCase() + 's', '/preco-da-terra'] };
    pessoas.push(p);
    const idx = Math.min(etapasC.length - 1, Math.floor(rnd() * rnd() * 6));
    const etapa = i < 5 ? 'Novo' : etapasC[idx];
    const contato = etapa === 'Novo' ? null : new Date(d.getTime() + (rnd() > .3 ? 8 + rnd() * 40 : 60 + rnd() * 1400) * 60000);
    const n = { id: 'n' + i, pessoa_id: p.id, criado_em: iso(d), funil, etapa: funil === 'compra' ? etapa : (etapa === 'Visita agendada' ? 'Em contato' : etapa === 'Proposta enviada' ? (funil === 'venda' ? 'Documentacao' : 'Orcamento enviado') : etapa === 'Fechado' ? (funil === 'venda' ? 'Vendido' : 'Executado') : etapa),
      tipo, cidade: p.cidade, corretor_id: rnd() > .5 ? 'u1' : 'u2', origem_evento: ev, origem_pagina: p.trajeto[1], origem_rotulo: 'CTA - ' + tipo,
      primeiro_contato_em: contato ? iso(contato) : null, ultima_atividade_em: contato ? iso(contato) : null, pontuacao: 20 + Math.floor(rnd() * 70), motivo_perda: etapa === 'Perdido' ? 'Sem resposta' : null, fechado_em: (etapa === 'Fechado' || etapa === 'Perdido') ? iso(new Date(d.getTime() + 86400000 * 3)) : null, area_ha: funil === 'venda' ? Math.floor(5 + rnd() * 60) : null };
    negocios.push(n);
    atividades.push({ id: 'a' + i + 'a', negocio_id: n.id, pessoa_id: p.id, em: iso(d), tipo: 'sistema', texto: 'Entrou pelo site', meta: { ev, pagina: n.origem_pagina, rotulo: n.origem_rotulo, historico: 6 } });
    if (contato) atividades.push({ id: 'a' + i + 'b', negocio_id: n.id, pessoa_id: p.id, em: iso(contato), tipo: 'whatsapp', quem: n.corretor_id, texto: 'Falei pelo WhatsApp', resultado: 'respondeu', perfis: { nome: n.corretor_id === 'u1' ? 'Jonas Scatolin' : 'Tatiane Scatolin' } });
    // histórico do visitante
    const nEv = 2 + Math.floor(rnd() * 6);
    for (let k = 0; k < nEv; k++) { const t = new Date(d.getTime() - (nEv - k) * 90000); eventos.push({ id: 'e' + i + k, ts: iso(t), nome: k === nEv - 1 ? ev : (k === 0 ? 'pagina:view' : ['pagina:view', 'pagina:leitura_50', 'faq:pergunta_open', 'form:view'][Math.floor(rnd() * 4)]), pessoa_id: p.id, pagina: p.trajeto[Math.min(2, k)], rotulo: k === nEv - 1 ? n.origem_rotulo : '', origem_motor: m[0] === '(direto)' ? '' : m[0], origem_tipo: m[1], dispositivo: rnd() > .4 ? 'celular' : 'desktop', props: k === 2 ? { pergunta: 'Quanto custa um alqueire?' } : {} }); }
  }
  // série diária
  const serie = []; const base = [3, 4, 2, 6, 9, 5, 4, 7, 11, 6, 3, 5, 8, 13, 24, 12, 6, 4, 9, 7, 5, 3, 6, 10, 8, 4, 7, 9];
  for (let i = 27; i >= 0; i--) { const v = base[27 - i]; serie.push({ dia: iso(dia(i)).slice(0, 10), cliques_contato: v, formularios: Math.round(v / 4), visualizacoes: v * 9, visitantes: v * 6, cliques_ia: Math.round(v / 3) }); }
  const kpis = { pessoas_14d: 27, pessoas_14d_anterior: 24, cliques_14d: serie.slice(-14).reduce((s, x) => s + x.cliques_contato, 0), cliques_14d_anterior: serie.slice(0, 14).reduce((s, x) => s + x.cliques_contato, 0), pessoas_ia_14d: 9, sem_contato: negocios.filter(n => !n.primeiro_contato_em && !n.fechado_em).length, mediana_min_contato: 38, com_historico: pessoas.filter(p => p.esteve_no_site).length };
  const motoresV = motores.map(([mo, tipo]) => ({ motor: mo, origem_tipo: tipo, visitantes_30d: Math.floor(40 + rnd() * 400), cliques_30d: Math.floor(5 + rnd() * 60), pessoas_30d: pessoas.filter(p => (p.origem_conversao.motor || '(direto)') === mo).length }));
  const origens = evs.concat(['pagina:view', 'form:view', 'form:start', 'popup:identificacao_view', 'popup:identificacao_skip', 'faq:pergunta_open', 'mapa:endereco_click', 'menu:whatsapp_click', 'busca:termo_submit']).map(nome => { const t = Math.floor(10 + rnd() * 300); return { nome, total: t, ultimos_14d: Math.floor(t * .5), ultimos_30d: t, visitantes: Math.floor(t * .7), identificados: nome === 'menu:whatsapp_click' ? 0 : Math.floor(t * .12), ultimo_em: nome === 'menu:whatsapp_click' ? iso(dia(41)) : iso(dia(Math.floor(rnd() * 3))) }; });
  const config = { cliente: { nome: 'Agrotec Imobiliária', curto: 'Agrotec' },
    funis: { compra: { rotulo: 'Compra', etapas: ['Novo', 'Em contato', 'Visita agendada', 'Proposta enviada', 'Fechado', 'Perdido'] }, venda: { rotulo: 'Venda', etapas: ['Novo', 'Em contato', 'Visita a propriedade', 'Documentacao', 'Em divulgacao', 'Vendido', 'Perdido'] }, servico: { rotulo: 'Serviço', etapas: ['Novo', 'Em contato', 'Orcamento enviado', 'Agendado', 'Executado', 'Perdido'] } },
    etapas_finais: { ganhou: ['Fechado', 'Vendido', 'Executado'], perdeu: ['Perdido'] }, motivos_perda: ['Sem resposta', 'Preço', 'Região', 'Já comprou / vendeu', 'Não era o serviço', 'Dado inválido', 'Outro'],
    sla: { minutos: 30, horario: { inicio: '08:00', fim: '18:30', dias: [1, 2, 3, 4, 5, 6] } } };
  return { pessoas, negocios, atividades, eventos, serie, kpis, motores: motoresV, origens, config, perfis };
}

const D = DEMO ? demoDados() : null;
const espera = (v) => new Promise(r => setTimeout(() => r(v), 120));
const provDemo = {
  async sessao() { try { return sessionStorage.getItem('demo_login') ? { user: { id: 'u0' } } : null; } catch (e) { return window.__demoLogin ? { user: { id: 'u0' } } : null; } },
  async entrar(email) { window.__demoLogin = true; try { sessionStorage.setItem('demo_login', email || 'demo'); } catch (e) {} return { user: { id: 'u0' } }; },
  async sair() { window.__demoLogin = false; try { sessionStorage.removeItem('demo_login'); } catch (e) {} },
  async recuperar() {}, async trocarSenha() {}, aoMudarAuth() {},
  async perfil() { return D.perfis[2]; }, async perfis() { return D.perfis; }, async config() { return D.config; },
  async kpis() { return espera(D.kpis); }, async serie(dias = 28) { return espera(D.serie.slice(-dias)); },
  async pessoasPorDia() { return []; }, async motores() { return espera(D.motores); }, async origensEvento() { return espera(D.origens); },
  async fila() { return espera(D.negocios.map(n => { const p = D.pessoas.find(x => x.id === n.pessoa_id); const c = D.perfis.find(x => x.id === n.corretor_id);
    return { ...n, pessoa_nome: p.nome, telefone: p.telefone, telefone_fmt: p.telefone_fmt, codigo: p.codigo, pessoa_cidade: p.cidade, cidade_ip: p.cidade_ip, esteve_no_site: p.esteve_no_site, origem_conversao: p.origem_conversao, origem_primeira: p.origem_primeira, visitas: p.visitas, leitura: p.leitura, corretor_nome: c?.nome,
      minutos_ate_contato: (new Date(n.primeiro_contato_em || Date.now()) - new Date(n.criado_em)) / 60000, sem_contato: !n.primeiro_contato_em, horas_parado: (Date.now() - new Date(n.ultima_atividade_em || n.criado_em)) / 3600000 }; })); },
  async pessoas(q) { const l = D.pessoas.map(p => ({ ...p, negocios: D.negocios.filter(n => n.pessoa_id === p.id) })); return espera(q ? l.filter(p => (p.nome + p.telefone + p.codigo + p.cidade).toLowerCase().includes(q.toLowerCase())) : l); },
  async pessoa(id) { return espera({ pessoa: D.pessoas.find(p => p.id === id), negocios: D.negocios.filter(n => n.pessoa_id === id).map(n => ({ ...n, perfis: D.perfis.find(x => x.id === n.corretor_id) })), atividades: D.atividades.filter(a => a.pessoa_id === id).sort((a, b) => b.em.localeCompare(a.em)), eventos: D.eventos.filter(e => e.pessoa_id === id).sort((a, b) => b.ts.localeCompare(a.ts)) }); },
  async moverEtapa(id, etapa, motivo) { const n = D.negocios.find(x => x.id === id); D.atividades.push({ id: 'a' + Math.random(), negocio_id: id, pessoa_id: n.pessoa_id, em: new Date().toISOString(), tipo: 'etapa', texto: n.etapa + ' → ' + etapa, perfis: D.perfis[2] }); n.etapa = etapa; n.motivo_perda = motivo || null; n.fechado_em = (D.config.etapas_finais.ganhou.concat(D.config.etapas_finais.perdeu).includes(etapa)) ? new Date().toISOString() : null; },
  async editarNegocio(id, c) { Object.assign(D.negocios.find(x => x.id === id), c); },
  async criarNegocio(c) { D.negocios.unshift({ id: 'n' + Math.random(), criado_em: new Date().toISOString(), pontuacao: 0, ...c }); },
  async editarPessoa(id, c) { Object.assign(D.pessoas.find(x => x.id === id), c); },
  async telefoneConfirmado(id, numero) { const p = D.pessoas.find(x => x.id === id); if (p) { p.telefone = numero; p.telefone_conferir = false; p.telefone_motivo = null; p.telefone_alternativas = []; } return { ok: true }; },
  async marcarInterna(id, valor) { const p = D.pessoas.find(x => x.id === id); if (p) { p.interna = !!valor; if (valor) D.negocios = D.negocios.filter(n => n.pessoa_id !== id); } return { ok: true }; },
  async atividade(a) { const n = D.negocios.find(x => x.id === a.negocio_id); D.atividades.push({ id: 'a' + Math.random(), em: new Date().toISOString(), perfis: D.perfis[2], quem: 'u0', ...a }); if (n && ['ligacao', 'whatsapp', 'visita', 'nota', 'repasse'].includes(a.tipo)) { n.primeiro_contato_em = n.primeiro_contato_em || new Date().toISOString(); n.ultima_atividade_em = new Date().toISOString(); } },
  async atualizarPerfil(id, c) { Object.assign(D.perfis.find(x => x.id === id), c); },
  async salvarConfig(k, v) { D.config[k] = v; },
  aoVivo() {}
};

export const dados = DEMO ? provDemo : provSupabase;
