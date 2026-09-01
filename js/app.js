// app.js — Console de Leads. Roteador por hash, telas como funções que
// devolvem HTML e ligam eventos depois. Sem framework: 1 arquivo, 1 CSS.
import { dados, DEMO } from './dados.js';
import { linha, donut } from './graficos.js';

const C = window.CONSOLE_CONFIG || {};
const app = document.getElementById('app');
// armazenamento pode não existir (sandbox, modo privado): nunca derruba o app
const guardar = (k, v) => { try { localStorage.setItem(k, v); } catch (e) {} };
const lerGuardado = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
const estado = { perfil: null, config: null, registro: null, recorte: 'todos', tema: lerGuardado('tema') || C.temaPadrao || 'noite', periodo: lerGuardado('periodo') || '14', periodoDe: lerGuardado('periodoDe') || '', periodoAte: lerGuardado('periodoAte') || '' };
document.documentElement.setAttribute('data-tema', estado.tema);

/* ------------------------------------------------------------ utilidades */
const h = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmtData = (d, comHora = true) => { if (!d) return ''; const x = new Date(d); const dd = x.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' }); return comHora ? dd + ' ' + x.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : dd; };
const fmtDia = (d) => { const x = new Date(d + (d.length === 10 ? 'T12:00:00' : '')); return x.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' }); };
const relativo = (d) => { if (!d) return ''; const m = (Date.now() - new Date(d)) / 60000; if (m < 1) return 'agora'; if (m < 60) return Math.round(m) + ' min'; if (m < 48 * 60) return Math.round(m / 60) + ' h'; return Math.round(m / 1440) + ' d'; };
const duracao = (min) => { if (min == null || isNaN(min)) return '—'; if (min < 60) return Math.round(min) + ' min'; if (min < 48 * 60) return (min / 60).toFixed(1).replace('.0', '') + ' h'; return Math.round(min / 1440) + ' d'; };
const iniciais = (n) => (n || '?').split(' ').filter(Boolean).slice(0, 2).map(x => x[0]).join('').toUpperCase();
const nomeOk = (n) => n && !/^\(n[ãa]o inform/.test(n) ? n : '(não informou)';
const semNome = (n) => !n || /^\(n[ãa]o inform/.test(n);
const tel = (t) => t ? String(t).replace(/\D/g, '') : '';
/* Telefone com pedido de conferência (31/08/2026): o site aceita o número
   como a pessoa digitou; quando o formato não fecha, o servidor marca
   telefone_conferir + motivo, e as variações determinísticas (o 9 de 2016)
   chegam em telefone_alternativas — para TENTAR, nunca para substituir sem
   alguém confirmar no botão "era este". */
const fmtTel = (s) => { s = tel(s); return s.length === 13 ? `(${s.slice(2, 4)}) ${s.slice(4, 9)}-${s.slice(9)}` : s.length === 12 ? `(${s.slice(2, 4)}) ${s.slice(4, 8)}-${s.slice(8)}` : s; };
const chipConferir = (x) => x?.telefone_conferir ? `<span class="chip c-laranja" title="${h(x.telefone_motivo || 'formato fora do padrão — confirmar com a pessoa')}">conferir</span>` : '';
const altsDe = (x) => Array.isArray(x?.telefone_alternativas) ? x.telefone_alternativas.filter(a => a && a.numero) : [];
const waLink = (t, nome) => 'https://wa.me/' + tel(t) + '?text=' + encodeURIComponent('Olá' + (nome && !semNome(nome) ? ', ' + nome.split(' ')[0] : '') + '! Aqui é da Agrotec Imobiliária. Vi seu contato pelo site e queria entender o que você procura.');
const ICO = {
  visao: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
  fila: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M4 12h10M4 18h7"/><circle cx="18" cy="17" r="3"/></svg>',
  pipeline: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="5" height="16" rx="1.5"/><rect x="10" y="4" width="5" height="11" rx="1.5"/><rect x="17" y="4" width="4" height="7" rx="1.5"/></svg>',
  pessoas: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.5-3.5 3-5.5 6.5-5.5s6 2 6.5 5.5"/><circle cx="17" cy="9" r="2.5"/><path d="M15.5 14.5c3 0 5.5 1.7 6 4.5"/></svg>',
  origens: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17M3.5 12h17M6 6.5c3.5 2 8.5 2 12 0M6 17.5c3.5-2 8.5-2 12 0"/></svg>',
  relatorios: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/></svg>',
  config: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>',
  wa: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2a8.2 8.2 0 0 1-4.2-1.2l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2zm4.5-6.1c-.2-.1-1.5-.7-1.7-.8s-.4-.1-.6.1-.6.8-.8 1-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.2-.4.7-1.3a.5.5 0 0 0 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.8 12 12 0 0 0 4.6 4c1.7.7 2.3.8 3.2.7a2.7 2.7 0 0 0 1.8-1.3 2.2 2.2 0 0 0 .2-1.3c-.1-.1-.3-.2-.5-.3z"/></svg>',
  tel: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z"/></svg>',
  ia: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8z"/></svg>',
  busca: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4-4"/></svg>',
  site: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/><circle cx="12" cy="12" r="9"/></svg>',
  lua: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>',
  sol: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
  cadeado: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>',
  seta: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 6l6 6-6 6"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12l5 5L20 7"/></svg>',
  nota: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 4h11l3 3v13H5z"/><path d="M8 12h8M8 16h5"/></svg>',
  copiar: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a1 1 0 0 1 1-1h10"/></svg>',
};
const MOTOR_COR = { ChatGPT: 'var(--ouro)', Perplexity: 'var(--ouro-2)', Gemini: 'var(--laranja)', Claude: 'var(--ouro)', Copilot: 'var(--laranja)', Google: 'var(--verde)', Bing: 'var(--azul)', Instagram: 'var(--roxo)', Facebook: 'var(--roxo)', '(direto)': 'var(--tinta-3)' };
const corMotor = (m, tipo) => MOTOR_COR[m] || (tipo === 'ia' ? 'var(--ouro)' : tipo === 'busca' ? 'var(--verde)' : tipo === 'social' ? 'var(--roxo)' : 'var(--tinta-3)');
function chipOrigem(o) {
  if (!o) return '<span class="chip c-neutro">(sem origem)</span>';
  const tipo = o.tipo || ''; const motor = o.motor || (tipo === 'interno' ? '(interno)' : '(direto)');
  const cls = tipo === 'ia' ? 'c-ouro' : tipo === 'busca' ? 'c-verde' : tipo === 'social' ? 'c-roxo' : tipo === 'campanha' ? 'c-azul' : 'c-neutro';
  const via = tipo === 'ia' ? (o.via === 'utm' ? ' (via link)' : o.via === 'ambos' ? '' : '') : '';
  return `<span class="chip ${cls}" title="${h(tipo)} · ${h(o.via || '')} · ${h(o.referrer_host || '')}">${tipo === 'ia' ? ICO.ia : tipo === 'busca' ? ICO.busca : ''}${h(motor)}${via}</span>`;
}
function chipFunil(f) { const m = { compra: ['Compra', 'c-verde'], venda: ['Venda', 'c-ouro'], servico: ['Serviço', 'c-azul'] }[f] || [f || '—', 'c-neutro']; return `<span class="chip ${m[1]}">${h(m[0])}</span>`; }
function chipEtapa(e) { const fins = estado.config?.etapas_finais || { ganhou: [], perdeu: [] }; const cls = fins.ganhou.includes(e) ? 'c-verde' : fins.perdeu.includes(e) ? 'c-vermelho' : e === 'Novo' ? 'c-azul' : 'c-laranja'; return `<span class="chip ${cls}">${h(e)}</span>`; }
function toast(msg) { const t = document.createElement('div'); t.className = 'toast'; t.textContent = msg; document.body.appendChild(t); setTimeout(() => t.remove(), 2200); }
async function copiar(txt) { try { await navigator.clipboard.writeText(txt); toast('Copiado'); } catch { const ta = document.createElement('textarea'); ta.value = txt; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); toast('Copiado'); } }

/* ----------------------------------------------------------- SLA / relógio */
function minutosUteis(deIso, ateMs = Date.now()) {
  // conta só dentro do horário de atendimento configurado
  const sla = estado.config?.sla || { horario: { inicio: '08:00', fim: '18:30', dias: [1, 2, 3, 4, 5, 6] } };
  const [hi, mi] = (sla.horario.inicio || '08:00').split(':').map(Number), [hf, mf] = (sla.horario.fim || '18:30').split(':').map(Number);
  const dias = sla.horario.dias || [1, 2, 3, 4, 5, 6];
  let t = new Date(deIso).getTime(); const fim = ateMs; let total = 0; let guard = 0;
  while (t < fim && guard++ < 20000) {
    const d = new Date(t); const dia = d.getDay();
    const ini = new Date(d); ini.setHours(hi, mi, 0, 0); const fin = new Date(d); fin.setHours(hf, mf, 0, 0);
    if (!dias.includes(dia) || t >= fin.getTime()) { const p = new Date(d); p.setDate(p.getDate() + 1); p.setHours(hi, mi, 0, 0); t = p.getTime(); continue; }
    if (t < ini.getTime()) t = ini.getTime();
    const ate = Math.min(fim, fin.getTime()); total += (ate - t) / 60000; t = ate;
    if (t >= fin.getTime()) { const p = new Date(d); p.setDate(p.getDate() + 1); p.setHours(hi, mi, 0, 0); t = p.getTime(); }
  }
  return total;
}
function classeSla(n) {
  const lim = estado.config?.sla?.minutos || 30;
  if (n.primeiro_contato_em) return 'ok';
  const m = minutosUteis(n.criado_em);
  return m > lim * 2 ? 'urgente' : m > lim ? 'atencao' : 'ok';
}

/* ------------------------------------------------------------- moldura */
const ROTAS = [['visao', 'Visão geral', 'visao'], ['fila', 'Atendimento', 'fila'], ['pipeline', 'Pipeline', 'pipeline'], ['pessoas', 'Pessoas', 'pessoas'], ['origens', 'Origens', 'origens'], ['relatorios', 'Relatórios', 'relatorios'], ['config', 'Configurações', 'config']];
function moldura(rota, conteudo, extras = {}) {
  const p = estado.perfil || {};
  const nav = ROTAS.filter(r => r[0] !== 'config' || p.papel === 'dono').map(([r, t, i]) => `<a href="#/${r}" class="${rota === r ? 'ativo' : ''}">${ICO[i]}<span>${t}</span>${r === 'fila' && extras.semContato ? `<span class="cont">${extras.semContato}</span>` : ''}</a>`).join('');
  const inferior = ['visao', 'fila', 'pipeline', 'pessoas', 'origens'].map(r => { const R = ROTAS.find(x => x[0] === r); return `<a href="#/${r}" class="${rota === r ? 'ativo' : ''}">${ICO[R[2]]}<span>${R[1].replace('Visão geral', 'Início')}</span>${r === 'fila' && extras.semContato ? `<span class="cont">${extras.semContato}</span>` : ''}</a>`; }).join('');
  app.innerHTML = `<div class="moldura">
    <aside class="lateral">
      <div class="marca"><b>${h(C.cliente || 'Agrotec')} <i>Leads</i></b><small>Console de Leads</small></div>
      <nav class="nav">${nav}</nav>
      <div class="fim">
        <div class="usuario"><div class="av">${h(iniciais(p.nome))}</div><div><b>${h(p.nome || '')}</b><span>${h({ dono: 'Dono', corretor: 'Corretor', leitura: 'Leitura' }[p.papel] || '')}${DEMO ? ' · demonstração' : ''}</span></div></div>
        <button class="btn btn-p" id="sair">Sair</button>
      </div>
    </aside>
    <main class="conteudo">${conteudo}</main>
  </div><nav class="barra-inferior">${inferior}</nav>`;
  document.getElementById('sair').onclick = async () => { await dados.sair(); location.hash = '#/login'; render(); };
}
function topo(titulo, sub, acoes = '') {
  return `<div class="topo"><div><h1>${h(titulo)}</h1><div class="sub">${h(sub)}</div></div><div class="acoes">
    <button class="btn btn-p" id="tema" title="Trocar entre claro e escuro">${estado.tema === 'noite' ? ICO.sol + ' Claro' : ICO.lua + ' Escuro'}</button><span class="vivo"><i></i>ao vivo</span>${acoes}</div></div>`;
}
function ligarTopo() { const b = document.getElementById('tema'); if (b) b.onclick = () => { estado.tema = estado.tema === 'noite' ? 'campo' : 'noite'; guardar('tema', estado.tema); document.documentElement.setAttribute('data-tema', estado.tema); render(); }; }
function recorteHtml() { return `<div class="seg" id="recorte">${[['todos', 'Todos'], ['compra', 'Compra'], ['venda', 'Venda'], ['servico', 'Serviço']].map(([k, t]) => `<button data-r="${k}" class="${estado.recorte === k ? 'ativo' : ''}">${t}</button>`).join('')}</div>`; }
function ligarRecorte() { const s = document.getElementById('recorte'); if (s) s.querySelectorAll('button').forEach(b => b.onclick = () => { estado.recorte = b.dataset.r; render(); }); }
const noRecorte = (n) => estado.recorte === 'todos' || n.funil === estado.recorte;

/* período da Visão geral — presets + faixa personalizada (padrão GA4/Stripe) */
const isoDia = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const diaCurto = (s) => s ? s.slice(8, 10) + '/' + s.slice(5, 7) : '';
function janelaPeriodo() {
  const hoje = new Date(); hoje.setHours(12, 0, 0, 0);
  let de, ate = new Date(hoje), rotulo;
  if (estado.periodo === 'p' && estado.periodoDe && estado.periodoAte) {
    de = new Date(estado.periodoDe + 'T12:00:00'); ate = new Date(estado.periodoAte + 'T12:00:00');
    rotulo = diaCurto(estado.periodoDe) + ' – ' + diaCurto(estado.periodoAte);
  } else {
    const n = Number(estado.periodo) || 14; de = new Date(hoje); de.setDate(de.getDate() - (n - 1));
    rotulo = n === 1 ? 'hoje' : n + ' dias';
  }
  const dias = Math.max(1, Math.round((ate - de) / 864e5) + 1);
  const deAnt = new Date(de); deAnt.setDate(deAnt.getDate() - dias);
  const ateAnt = new Date(de); ateAnt.setDate(ateAnt.getDate() - 1);
  return { deISO: isoDia(de), ateISO: isoDia(ate), deAntISO: isoDia(deAnt), ateAntISO: isoDia(ateAnt), dias, rotulo };
}
function periodoHtml() {
  const j = janelaPeriodo();
  const b = (k, t) => `<button data-p="${k}" class="${estado.periodo === k ? 'ativo' : ''}">${t}</button>`;
  return `<div class="seg" id="periodo">${b('1', 'Hoje')}${b('7', '7 dias')}${b('14', '14 dias')}${b('30', '30 dias')}${b('p', estado.periodo === 'p' ? j.rotulo : 'Personalizado')}</div>`;
}
function ligarPeriodo() {
  const s = document.getElementById('periodo'); if (!s) return;
  s.querySelectorAll('button').forEach(b => b.onclick = () => {
    if (b.dataset.p === 'p') return modalPeriodo();
    estado.periodo = b.dataset.p; guardar('periodo', estado.periodo); render();
  });
}
function modalPeriodo() {
  const j = janelaPeriodo();
  const min = new Date(); min.setDate(min.getDate() - 59); // a série diária guarda 60 dias
  const f = modal(`<h2>Período personalizado</h2><form id="fper">
    <div class="campo"><label for="p-de">De</label><input id="p-de" type="date" name="de" required value="${estado.periodoDe || j.deISO}" min="${isoDia(min)}" max="${isoDia(new Date())}"></div>
    <div class="campo"><label for="p-ate">Até</label><input id="p-ate" type="date" name="ate" required value="${estado.periodoAte || j.ateISO}" min="${isoDia(min)}" max="${isoDia(new Date())}"></div>
    <div class="dica">O gráfico diário cobre os últimos 60 dias. A comparação usa o período anterior de mesmo tamanho.</div>
    <div class="rodape"><button class="btn" type="button" data-fechar>Cancelar</button><button class="btn btn-ouro" type="submit">Aplicar</button></div></form>`);
  f.querySelector('[data-fechar]').onclick = () => f.remove();
  f.querySelector('form').onsubmit = (e) => { e.preventDefault(); const d = new FormData(e.target);
    let de = d.get('de'), ate = d.get('ate'); if (de > ate) { const t = de; de = ate; ate = t; }
    estado.periodo = 'p'; estado.periodoDe = de; estado.periodoAte = ate;
    guardar('periodo', 'p'); guardar('periodoDe', de); guardar('periodoAte', ate); f.remove(); render(); };
}
const noPeriodo = (j) => (x) => { const d = String(x || '').slice(0, 10); return d >= j.deISO && d <= j.ateISO; };
const noPeriodoAnt = (j) => (x) => { const d = String(x || '').slice(0, 10); return d >= j.deAntISO && d <= j.ateAntISO; };

/* ---------------------------------------------------------------- login */
function telaLogin(erro = '') {
  app.innerHTML = `<div class="login"><form class="cx" id="flogin" autocomplete="on">
    <div class="selo">${ICO.cadeado}</div>
    <h1>${h(C.cliente || 'Agrotec')} <b>Leads</b></h1><div class="sub">Console de leads · acesso restrito</div>
    ${erro ? `<div class="erro">${h(erro)}</div>` : ''}
    ${C.loginEmail ? `<input id="email" name="email" type="email" autocomplete="username" value="${h(C.loginEmail)}" class="oculto" tabindex="-1" aria-hidden="true">` : `<div class="campo"><label for="email">E-mail</label><input id="email" name="email" type="email" autocomplete="username" required ${DEMO ? 'value="demo@agrotec"' : ''}></div>`}
    <div class="campo"><label for="senha">${C.loginEmail ? 'Senha do painel' : 'Senha'}</label><input id="senha" name="senha" type="password" autocomplete="current-password" ${DEMO ? 'value="demo"' : 'required'}></div>
    <button class="btn btn-ouro btn-cheio" type="submit">Abrir o console</button>
    <div class="dica">${DEMO ? 'Modo demonstração: dados de exemplo, nada é gravado.' : C.loginEmail ? 'O console só abre com a senha. A sessão fica guardada somente neste aparelho.' : 'Sua sessão fica só neste aparelho. <a href="#" id="esqueci">Esqueci a senha</a>'}</div>
  </form></div>`;
  document.getElementById('flogin').onsubmit = async (e) => { e.preventDefault(); const b = e.target.querySelector('button'); b.disabled = true; b.textContent = 'Entrando…';
    try { await dados.entrar(e.target.email.value.trim(), e.target.senha.value); location.hash = '#/visao'; await iniciar(); }
    catch (err) { telaLogin(/invalid/i.test(err.message) ? 'E-mail ou senha não conferem.' : 'Não deu para entrar: ' + err.message); } };
  const esq = document.getElementById('esqueci'); if (esq) esq.onclick = async (e) => { e.preventDefault(); const em = document.getElementById('email').value.trim(); if (!em) return toast('Digite o e-mail primeiro'); try { await dados.recuperar(em); toast('Enviamos um link para ' + em); } catch (er) { toast('Não deu: ' + er.message); } };
}

/* ---------------------------------------------------------- visão geral */
async function telaVisao() {
  const j = janelaPeriodo();
  const [k, serie, motores, fila, pessoas] = await Promise.all([dados.kpis(), dados.serie(60), dados.motores(), dados.fila(), dados.pessoas()]);
  const filaR = fila.filter(noRecorte);
  const tend = (a, b) => { if (!b) return '<span class="tend neutro">novo</span>'; const p = Math.round((a - b) / b * 100); return `<span class="tend ${p > 0 ? 'sobe' : p < 0 ? 'desce' : 'neutro'}">${p > 0 ? '↗ +' : p < 0 ? '↘ ' : '→ '}${p}%</span>`; };
  const semContato = filaR.filter(n => n.sem_contato && !n.fechado_em).length;
  const atrasados = filaR.filter(n => n.sem_contato && !n.fechado_em && classeSla(n) !== 'ok').length;
  const recentes = filaR.slice(0, 8);
  // tudo abaixo respeita o período escolhido no topo
  const emJanela = noPeriodo(j), emJanelaAnt = noPeriodoAnt(j);
  const serieJ = serie.filter(x => emJanela(x.dia)), serieAnt = serie.filter(x => emJanelaAnt(x.dia));
  const somaCliques = a => a.reduce((t, x) => t + Number(x.cliques_contato || 0) + Number(x.formularios || 0), 0);
  const pesJ = pessoas.filter(p => emJanela(p.criado_em)), pesAnt = pessoas.filter(p => emJanelaAnt(p.criado_em));
  const ehIa = p => ((p.origem_conversao || {}).tipo === 'ia') || ((p.origem_primeira || {}).tipo === 'ia');
  const kJanela = { pessoas: pesJ.length, pessoasAnt: pesAnt.length, cliques: somaCliques(serieJ), cliquesAnt: somaCliques(serieAnt), ia: pesJ.filter(ehIa).length, historico: pessoas.filter(p => p.esteve_no_site).length };
  // origem de conversão no período (pessoas), com IA em dourado
  const cont = {}; pesJ.forEach(p => { const o = p.origem_conversao || p.origem_primeira || {}; const m = o.motor || (o.tipo === 'interno' ? '(interno)' : '(direto)'); cont[m] = cont[m] || { n: 0, tipo: o.tipo }; cont[m].n++; });
  const fatias = Object.entries(cont).sort((a, b) => b[1].n - a[1].n).slice(0, 8).map(([m, v]) => ({ rotulo: m, valor: v.n, cor: corMotor(m, v.tipo), tipo: v.tipo }));
  moldura('visao', `${topo('Visão geral', 'O pulso dos leads do site em tempo real', periodoHtml() + recorteHtml())}
    <div class="kpis">
      <div class="kpi"><div class="cab">${ICO.pessoas}${tend(kJanela.pessoas, kJanela.pessoasAnt)}</div><b class="num">${kJanela.pessoas}</b><span>pessoas · ${h(j.rotulo)}</span></div>
      <div class="kpi"><div class="cab">${ICO.wa}${tend(kJanela.cliques, kJanela.cliquesAnt)}</div><b class="num">${kJanela.cliques}</b><span>cliques de contato · ${h(j.rotulo)}</span></div>
      <div class="kpi"><div class="cab">${ICO.ia}<span class="tend neutro">canal IA</span></div><b class="num ouro">${kJanela.ia}</b><span>vieram de uma IA · ${h(j.rotulo)}</span></div>
      <div class="kpi"><div class="cab">${ICO.fila}<span class="tend ${atrasados ? 'desce' : 'neutro'}">${atrasados ? atrasados + ' fora do prazo' : 'no prazo'}</span></div><b class="num ${atrasados ? 'vermelho' : 'azul'}">${semContato}</b><span>sem atendimento</span></div>
      <div class="kpi"><div class="cab">${ICO.check}<span class="tend neutro">mediana 30 d</span></div><b class="num verde">${k.mediana_min_contato != null ? duracao(k.mediana_min_contato) : '—'}</b><span>até o primeiro contato</span></div>
      <div class="kpi"><div class="cab">${ICO.site}<span class="tend neutro">histórico</span></div><b class="num">${kJanela.historico}</b><span>leads que estavam no site</span></div>
    </div>
    <div class="grade-2">
      <div class="cx"><h2>Cliques em botões de contato</h2><div class="sub">${j.rotulo === 'hoje' ? 'Hoje' : (j.rotulo.includes('–') ? j.rotulo : 'Últimos ' + j.rotulo)} · WhatsApp, telefone, formulários e portões · tracejado = período anterior · ponto verde = vindos de IA</div>
        <div style="position:relative;margin-top:14px"><canvas class="grafico" id="g-linha"></canvas><div class="tt chip c-neutro" hidden style="position:absolute;transform:translateX(-50%);pointer-events:none"></div></div></div>
      <div class="cx"><h2>De onde vieram</h2><div class="sub">Origem na conversão · dourado = IA</div>
        <canvas id="g-donut" style="width:150px;height:150px;display:block;margin:14px auto 0"></canvas>
        <ul class="legenda">${fatias.map(f => `<li class="${f.tipo === 'ia' ? 'ia' : ''}"><i style="background:${f.cor}"></i><span>${h(f.rotulo)}</span><b class="num">${f.valor}</b></li>`).join('') || '<li class="vazio">Nenhuma pessoa neste período.</li>'}</ul></div>
    </div>
    <div class="cx"><div style="display:flex;justify-content:space-between;align-items:center;gap:10px"><h2>Leads recentes</h2><span class="sub">${filaR.length} neste recorte · <a href="#/pessoas" style="color:var(--ouro)">ver todos</a></span></div>
      <div class="rolo"><table class="tabela" style="margin-top:8px"><thead><tr><th>Código</th><th>Pessoa</th><th>Origem</th><th>Funil</th><th>Status</th><th></th></tr></thead><tbody>
      ${recentes.map(n => `<tr><td class="codigo">${h(n.codigo || '')}</td><td class="pessoa"><b>${h(nomeOk(n.pessoa_nome))}</b><small>${h(n.telefone_fmt || '')} ${n.esteve_no_site ? '· esteve no site' : ''}</small></td><td>${chipOrigem(n.origem_conversao)}</td><td>${chipFunil(n.funil)}</td><td>${chipEtapa(n.etapa)}</td><td><a class="btn btn-p" href="#/pessoa/${n.pessoa_id}">${ICO.seta}</a></td></tr>`).join('') || '<tr><td colspan="6" class="vazio">Nenhum lead ainda. Assim que alguém clicar num botão do site, aparece aqui.</td></tr>'}
      </tbody></table></div></div>`, { semContato });
  ligarTopo(); ligarRecorte(); ligarPeriodo();
  const ult = serieJ, ant = serieAnt;
  const desenha = () => { if (!document.getElementById('g-linha')) { window.onresize = null; return; } linha(document.getElementById('g-linha'), { rotulos: ult.map(x => fmtDia(x.dia)), atual: ult.map(x => Number(x.cliques_contato) + Number(x.formularios || 0)), anterior: ant.length === ult.length ? ant.map(x => Number(x.cliques_contato) + Number(x.formularios || 0)) : null, destaque: ult.map(x => Number(x.cliques_ia || 0)) }); donut(document.getElementById('g-donut'), fatias); };
  desenha(); window.onresize = desenha;
}

/* ------------------------------------------------------------------ fila */
/* Pedido do dono (31/08/2026): "Todos" e a primeira aba do Atendimento e a
   que abre por padrao — quem chega quer o retrato inteiro, e so depois filtra
   quem precisa de resposta. */
async function telaFila(aba = 'todos') {
  const fila = (await dados.fila()).filter(noRecorte);
  const fins = estado.config?.etapas_finais || { ganhou: [], perdeu: [] };
  const aberto = n => !fins.ganhou.includes(n.etapa) && !fins.perdeu.includes(n.etapa);
  const faixas = { precisa: fila.filter(n => aberto(n) && n.sem_contato), conversa: fila.filter(n => aberto(n) && !n.sem_contato), encerrados: fila.filter(n => !aberto(n)), todos: fila };
  const lista = faixas[aba].slice().sort((a, b) => { if (aba === 'precisa') return new Date(a.criado_em) - new Date(b.criado_em); return new Date(b.ultima_atividade_em || b.criado_em) - new Date(a.ultima_atividade_em || a.criado_em); });
  moldura('fila', `${topo('Atendimento', 'Com quem falar agora — ordem por tempo esperando', recorteHtml())}
    <div class="filtros">${[['todos', 'Todos'], ['precisa', 'Precisa de você'], ['conversa', 'Em conversa'], ['encerrados', 'Encerrados']].map(([k, t]) => `<button class="aba ${aba === k ? 'ativo' : ''}" data-aba="${k}">${t}<small>${faixas[k].length}</small></button>`).join('')}</div>
    <div class="fila">${lista.map(n => cartaoFila(n)).join('') || '<div class="cx vazio">Nada aqui. Bom sinal.</div>'}</div>`, { semContato: faixas.precisa.length });
  ligarTopo(); ligarRecorte();
  document.querySelectorAll('.aba').forEach(b => b.onclick = () => telaFila(b.dataset.aba));
  ligarAcoesLead();
}
function cartaoFila(n) {
  const cls = classeSla(n); const esperando = n.sem_contato ? minutosUteis(n.criado_em) : n.minutos_ate_contato;
  return `<article class="lead ${n.sem_contato ? cls : ''}" data-id="${n.id}" data-pessoa="${n.pessoa_id}" data-tel="${h(n.telefone || '')}" data-nome="${h(n.pessoa_nome || '')}">
    <div class="relogio ${cls}"><b class="num">${duracao(esperando)}</b><small>${n.sem_contato ? 'esperando' : 'até o 1º contato'}</small></div>
    <div><div class="nome">${h(nomeOk(n.pessoa_nome))} <span class="codigo mono" style="color:var(--ouro)">${h(n.codigo || '')}</span> ${n.esteve_no_site ? `<span class="chip c-azul" title="Tem histórico de navegação antes de se identificar">${ICO.site} esteve no site</span>` : ''}</div>
      <div class="linha">${chipFunil(n.funil)} ${n.tipo ? `<span class="chip c-neutro">${h(n.tipo)}</span>` : ''} ${chipOrigem(n.origem_conversao)} ${n.pessoa_cidade ? `<span>${h(n.pessoa_cidade)}</span>` : n.cidade_ip ? `<span title="pelo IP, aproximado">~${h(n.cidade_ip)}</span>` : ''} <span>· ${h(n.origem_rotulo || n.origem_evento || '')} em ${h(n.origem_pagina || '')}</span> ${n.corretor_nome ? `<span>· ${h(n.corretor_nome.split(' ')[0])}</span>` : ''} ${chipEtapa(n.etapa)}</div></div>
    <div class="botoes">${n.telefone ? `<a class="btn btn-p btn-verde" target="_blank" rel="noopener" href="${waLink(n.telefone, n.pessoa_nome)}" data-acao="whatsapp">${ICO.wa} WhatsApp</a><a class="btn btn-p" href="tel:+${tel(n.telefone)}" data-acao="ligar">${ICO.tel}</a>${chipConferir(n)}${altsDe(n).map(a => `<a class="btn btn-p" target="_blank" rel="noopener" href="${waLink(a.numero, n.pessoa_nome)}" title="${h(a.porque || '')} — ${h(fmtTel(a.numero))}" data-acao="whatsapp">${ICO.wa} tentar com o 9</a>`).join('')}` : '<span class="chip c-neutro">sem telefone</span>'}
      <button class="btn btn-p" data-acao="falei">Falei</button><button class="btn btn-p" data-acao="briefing" title="Copiar resumo para repassar">${ICO.copiar}</button><a class="btn btn-p" href="#/pessoa/${n.pessoa_id}">${ICO.seta}</a></div></article>`;
}
function ligarAcoesLead() {
  document.querySelectorAll('.lead [data-acao]').forEach(b => b.addEventListener('click', async (e) => {
    const art = b.closest('.lead'); const id = art.dataset.id, pessoa = art.dataset.pessoa, acao = b.dataset.acao;
    if (acao === 'whatsapp' || acao === 'ligar') { await dados.atividade({ negocio_id: id, pessoa_id: pessoa, tipo: acao === 'ligar' ? 'ligacao' : 'whatsapp', texto: acao === 'ligar' ? 'Ligou pelo console' : 'Abriu o WhatsApp pelo console', resultado: 'tentativa' }); return; }
    e.preventDefault();
    if (acao === 'falei') { modalFalei(id, pessoa); }
    if (acao === 'briefing') { const d = await dados.pessoa(pessoa); const n = d.negocios.find(x => x.id === id) || d.negocios[0]; copiar(briefing(d.pessoa, n, d.eventos)); await dados.atividade({ negocio_id: id, pessoa_id: pessoa, tipo: 'repasse', texto: 'Copiou o briefing', resultado: '' }); }
  }));
}
function briefing(p, n, eventos) {
  const paginas = [...new Set((eventos || []).filter(e => e.nome === 'pagina:view').map(e => e.pagina))].slice(0, 6);
  return [`${nomeOk(p.nome)} — ${p.telefone_fmt || p.telefone || 'sem telefone'} (${p.codigo || ''})`, `Quer: ${n?.tipo || '—'} · funil ${n?.funil || '—'} · ${n?.cidade || p.cidade || p.cidade_ip ? (n?.cidade || p.cidade || '~' + p.cidade_ip) : 'lugar não informado'}`, `Chegou por: ${(p.origem_conversao?.motor || p.origem_conversao?.tipo || 'direto')} em ${fmtData(n?.criado_em || p.criado_em)}; clicou em "${n?.origem_rotulo || n?.origem_evento || ''}" na página ${n?.origem_pagina || ''}`, paginas.length ? `Viu: ${paginas.join(' > ')}` : '', p.esteve_no_site ? 'Já tinha navegado no site antes de se identificar.' : '', n?.descricao ? `Descreveu: ${n.descricao}` : '', n?.proximo_passo ? `Próximo passo: ${n.proximo_passo}` : ''].filter(Boolean).join('\n');
}
function modal(html) { const f = document.createElement('div'); f.className = 'modal-fundo'; f.innerHTML = `<div class="modal">${html}</div>`; f.addEventListener('click', e => { if (e.target === f) f.remove(); }); document.body.appendChild(f); return f; }
function modalFalei(negocioId, pessoaId) {
  const f = modal(`<h2>Registrar contato</h2><form id="ffalei">
    <div class="campo"><label>Como</label><select name="tipo"><option value="whatsapp">WhatsApp</option><option value="ligacao">Ligação</option><option value="visita">Visita</option><option value="nota">Só uma nota</option></select></div>
    <div class="campo"><label>Resultado</label><select name="resultado"><option value="respondeu">Respondeu</option><option value="sem resposta">Não respondeu</option><option value="agendou">Agendou</option><option value="descartou">Descartou</option></select></div>
    <div class="campo"><label>Anotação</label><textarea class="nota" name="texto" placeholder="O que a pessoa disse, o que ficou combinado"></textarea></div>
    <div class="campo"><label>Próximo passo (opcional)</label><input name="proximo" placeholder="ex.: mandar fotos da área de Xaxim"></div>
    <div class="rodape"><button class="btn" type="button" data-fechar>Cancelar</button><button class="btn btn-ouro" type="submit">Salvar</button></div></form>`);
  f.querySelector('[data-fechar]').onclick = () => f.remove();
  f.querySelector('form').onsubmit = async (e) => { e.preventDefault(); const d = new FormData(e.target);
    await dados.atividade({ negocio_id: negocioId, pessoa_id: pessoaId, tipo: d.get('tipo'), resultado: d.get('resultado'), texto: d.get('texto') });
    if (d.get('proximo')) await dados.editarNegocio(negocioId, { proximo_passo: d.get('proximo') });
    f.remove(); toast('Registrado'); render(); };
}

/* -------------------------------------------------------------- pipeline */
let arrastando = null;
async function telaPipeline() {
  const fila = (await dados.fila()).filter(noRecorte);
  const funis = estado.config?.funis || {};
  const chaves = estado.recorte === 'todos' ? Object.keys(funis) : [estado.recorte];
  const secoes = chaves.map(f => { const et = funis[f]?.etapas || ['Novo']; const itens = fila.filter(n => n.funil === f);
    return `<section style="margin-bottom:22px"><h2 style="font-size:15px;color:var(--tinta-2);margin:0 0 10px">${h(funis[f]?.rotulo || f)} <small style="color:var(--tinta-3)">· ${itens.length}</small></h2>
      <div class="pipeline">${et.map(e => { const l = itens.filter(n => n.etapa === e); return `<div class="coluna" data-funil="${f}" data-etapa="${h(e)}"><header><i style="background:${corEtapa(e)}"></i>${h(e)}<span class="n num">${l.length}</span></header>
        ${l.map(n => `<div class="cartao" draggable="true" data-id="${n.id}" data-pessoa="${n.pessoa_id}"><div class="cab"><span class="codigo mono">${h(n.codigo || '')}</span>${n.tipo ? `<span class="chip c-neutro">${h(n.tipo)}</span>` : ''}</div>
          <div class="nome">${h(nomeOk(n.pessoa_nome))}</div><div class="meta">${chipOrigem(n.origem_conversao)} ${n.pessoa_cidade ? h(n.pessoa_cidade) : ''}</div>
          <div class="idade ${(Date.now() - new Date(n.ultima_atividade_em || n.criado_em)) > 3 * 86400000 && !n.fechado_em ? 'velho' : ''}">${n.fechado_em ? 'fechado ' + relativo(n.fechado_em) : 'parado há ' + relativo(n.ultima_atividade_em || n.criado_em)}${n.corretor_nome ? ' · ' + h(n.corretor_nome.split(' ')[0]) : ''}</div></div>`).join('') || '<div class="vazio">vazio</div>'}</div>`; }).join('')}</div></section>`; }).join('');
  moldura('pipeline', `${topo('Pipeline', 'Do primeiro clique ao contrato fechado — arraste para mudar a etapa', recorteHtml())}
    <p style="font-size:13px;color:var(--tinta-3);margin:0 0 12px">No celular, toque no cartão e escolha a etapa.</p>${secoes}`);
  ligarTopo(); ligarRecorte();
  document.querySelectorAll('.cartao').forEach(c => {
    c.addEventListener('dragstart', () => { arrastando = c; c.classList.add('arrastando'); });
    c.addEventListener('dragend', () => { c.classList.remove('arrastando'); arrastando = null; });
    c.addEventListener('click', () => modalEtapa(c.dataset.id, c.closest('.coluna').dataset.funil, c.closest('.coluna').dataset.etapa, c.dataset.pessoa));
  });
  document.querySelectorAll('.coluna').forEach(col => {
    col.addEventListener('dragover', e => { e.preventDefault(); col.classList.add('sobre'); });
    col.addEventListener('dragleave', () => col.classList.remove('sobre'));
    col.addEventListener('drop', async e => { e.preventDefault(); col.classList.remove('sobre'); if (!arrastando) return;
      const de = arrastando.closest('.coluna'); if (de.dataset.funil !== col.dataset.funil) return toast('Funil diferente — abra o cartão para mudar o funil');
      const etapa = col.dataset.etapa; if (etapa === de.dataset.etapa) return;
      await mover(arrastando.dataset.id, etapa); });
  });
}
function corEtapa(e) { const fins = estado.config?.etapas_finais || { ganhou: [], perdeu: [] }; return fins.ganhou.includes(e) ? 'var(--verde)' : fins.perdeu.includes(e) ? 'var(--vermelho)' : e === 'Novo' ? 'var(--azul)' : 'var(--laranja)'; }
async function mover(id, etapa) {
  const fins = estado.config?.etapas_finais || { perdeu: ['Perdido'] };
  if (fins.perdeu.includes(etapa)) { const motivos = estado.config?.motivos_perda || ['Outro'];
    const f = modal(`<h2>Por que perdeu?</h2><form id="fperda"><div class="campo"><select name="motivo">${motivos.map(m => `<option>${h(m)}</option>`).join('')}</select></div><div class="rodape"><button class="btn" type="button" data-fechar>Cancelar</button><button class="btn btn-ouro" type="submit">Marcar como perdido</button></div></form>`);
    f.querySelector('[data-fechar]').onclick = () => f.remove();
    f.querySelector('form').onsubmit = async (e) => { e.preventDefault(); await dados.moverEtapa(id, etapa, new FormData(e.target).get('motivo')); f.remove(); toast('Movido para ' + etapa); render(); };
    return; }
  await dados.moverEtapa(id, etapa, null); toast('Movido para ' + etapa); render();
}
function modalEtapa(id, funil, etapaAtual, pessoaId) {
  const funis = estado.config?.funis || {}; const et = funis[funil]?.etapas || [];
  const f = modal(`<h2>Mudar etapa</h2><form id="fetapa"><div class="campo"><label>Funil</label><select name="funil">${Object.keys(funis).map(k => `<option value="${k}" ${k === funil ? 'selected' : ''}>${h(funis[k].rotulo)}</option>`).join('')}</select></div>
    <div class="campo"><label>Etapa</label><select name="etapa">${et.map(e => `<option ${e === etapaAtual ? 'selected' : ''}>${h(e)}</option>`).join('')}</select></div>
    <div class="rodape"><a class="btn" href="#/pessoa/${pessoaId}">Abrir a pessoa</a><button class="btn btn-ouro" type="submit">Salvar</button></div></form>`);
  const sf = f.querySelector('[name=funil]'), se = f.querySelector('[name=etapa]');
  sf.onchange = () => { se.innerHTML = (funis[sf.value]?.etapas || []).map(e => `<option>${h(e)}</option>`).join(''); };
  f.querySelector('form').onsubmit = async (e) => { e.preventDefault(); const d = new FormData(e.target); f.remove();
    if (d.get('funil') !== funil) await dados.editarNegocio(id, { funil: d.get('funil') });
    await mover(id, d.get('etapa')); };
}

/* --------------------------------------------------------------- pessoas */
async function telaPessoas(q = '') {
  const lista = (await dados.pessoas(q)).filter(p => estado.recorte === 'todos' || (p.negocios || []).some(n => n.funil === estado.recorte));
  moldura('pessoas', `${topo('Pessoas', 'Uma linha por pessoa — o histórico junta todos os cliques dela', recorteHtml())}
    <div class="filtros"><span class="chip c-neutro">${lista.length} pessoas</span><span class="chip c-azul">${lista.filter(p => p.esteve_no_site).length} com histórico no site</span><span class="chip c-ouro">${lista.filter(p => (p.origem_conversao || {}).tipo === 'ia').length} vindas de IA</span>
      <div class="busca">${ICO.busca}<input id="q" placeholder="nome, telefone, código ou cidade…" value="${h(q)}"></div></div>
    <div class="cx" style="padding:0 16px"><div class="rolo"><table class="tabela"><thead><tr><th>Quando</th><th>Pessoa</th><th>Origem</th><th>Onde clicou</th><th>Negócios</th><th></th></tr></thead><tbody>
    ${lista.map(p => { const n = (p.negocios || [])[0] || {}; return `<tr><td class="quando"><b>${fmtData(p.criado_em)}</b><small>${p.visitas > 1 ? p.visitas + ' visitas' : '1ª visita'}${p.esteve_no_site ? ' · esteve no site' : ''}</small></td>
      <td class="pessoa"><b>${h(nomeOk(p.nome))}</b>${p.interna ? ' <span class="chip c-neutro">interno</span>' : ''}<small>${h(p.telefone_fmt || p.telefone || 'sem telefone')} · <span class="codigo">${h(p.codigo || '')}</span></small></td>
      <td>${chipOrigem(p.origem_conversao)}</td><td><small>${h(n.origem_rotulo || n.origem_evento || '')}<br>${h(n.origem_pagina || '')}</small></td>
      <td>${(p.negocios || []).map(x => chipFunil(x.funil) + ' ' + chipEtapa(x.etapa)).join('<br>')}</td><td><a class="btn btn-p" href="#/pessoa/${p.id}">${ICO.seta}</a></td></tr>`; }).join('') || '<tr><td colspan="6" class="vazio">Nenhuma pessoa encontrada.</td></tr>'}
    </tbody></table></div></div>`);
  ligarTopo(); ligarRecorte();
  let t; document.getElementById('q').oninput = (e) => { clearTimeout(t); t = setTimeout(() => telaPessoas(e.target.value.trim()), 300); };
  document.getElementById('q').focus(); const v = document.getElementById('q').value; document.getElementById('q').setSelectionRange(v.length, v.length);
}

/* ---------------------------------------------------------------- pessoa */
const EV_HUMANO = { ligacao: 'Ligação', whatsapp: 'WhatsApp', visita: 'Visita', nota: 'Nota', repasse: 'Repasse', etapa: 'Etapa', tarefa: 'Tarefa', sistema: 'Sistema' };
function nomeEvento(nome) { const r = estado.registro?.eventos?.[nome]; return r ? r.o_que : nome; }
async function telaPessoa(id) {
  const d = await dados.pessoa(id); const p = d.pessoa; if (!p) { moldura('pessoas', '<div class="cx vazio">Pessoa não encontrada.</div>'); return; }
  const n0 = d.negocios[0];
  const itens = [...d.atividades.map(a => ({ em: a.em, tipo: 'humano', a })), ...d.eventos.map(e => ({ em: e.ts, tipo: 'site', e }))].sort((a, b) => new Date(b.em) - new Date(a.em));
  const antes = d.eventos.filter(e => n0 && new Date(e.ts) < new Date(n0.criado_em)).length;
  moldura('pessoas', `${topo(nomeOk(p.nome), `${p.codigo || ''}${p.interna ? ' · PESSOA INTERNA (sem cartões, fora da fila e dos números)' : ''} · entrou ${fmtData(p.criado_em)}${p.esteve_no_site ? ' · esteve no site antes de se identificar' : ''}`, `<button class="btn" id="interna" title="${p.interna ? 'Volta a gerar cartões' : 'Sócio, corretor ou dono: sem cartões, fora da fila e dos números'}">${p.interna ? 'Deixar de ser interno' : 'Marcar como interno'}</button><a class="btn" href="#/pessoas">← Pessoas</a>`)}
    <div class="pessoa-grade">
      <div>
        <div class="cx" style="margin-bottom:14px"><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;align-items:center"><h2>Negócios</h2><button class="btn btn-p" id="novo-negocio">+ Negócio</button></div>
          ${d.negocios.map(n => `<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;padding:10px 0;border-top:1px solid var(--linha)" data-neg="${n.id}">${chipFunil(n.funil)}${chipEtapa(n.etapa)}${n.tipo ? `<span class="chip c-neutro">${h(n.tipo)}</span>` : ''}
            <span style="font-size:13px;color:var(--tinta-2)">${h(n.origem_rotulo || n.origem_evento || '')} em ${h(n.origem_pagina || '')} · ${fmtData(n.criado_em)}</span>
            <span style="font-size:13px;color:var(--tinta-2)">· 1º contato: ${n.primeiro_contato_em ? duracao((new Date(n.primeiro_contato_em) - new Date(n.criado_em)) / 60000) : '<b style="color:var(--vermelho)">ainda não</b>'}</span>
            ${n.perfis?.nome ? `<span style="font-size:13px;color:var(--tinta-2)">· ${h(n.perfis.nome)}</span>` : ''} ${n.proximo_passo ? `<span class="chip c-laranja">→ ${h(n.proximo_passo)}</span>` : ''}
            <span style="margin-left:auto;display:flex;gap:6px"><button class="btn btn-p" data-editar="${n.id}">Editar</button><button class="btn btn-p" data-etapa="${n.id}" data-funil="${n.funil}" data-atual="${h(n.etapa)}">Etapa</button></span>
            ${n.descricao ? `<p style="width:100%;margin:6px 0 0;font-size:14px;color:var(--tinta-2)">${h(n.descricao)}</p>` : ''}</div>`).join('') || '<p class="vazio">Sem negócio.</p>'}
          <div class="acao-rapida">${p.telefone ? `<a class="btn btn-verde" target="_blank" rel="noopener" href="${waLink(p.telefone, p.nome)}" id="wa">${ICO.wa} WhatsApp</a><a class="btn" href="tel:+${tel(p.telefone)}" id="ligar">${ICO.tel} Ligar</a>` : '<span class="chip c-neutro">sem telefone</span><span></span>'}
            <button class="btn" id="falei">${ICO.nota} Registrar contato</button><button class="btn" id="briefing">${ICO.copiar} Copiar briefing</button></div></div>
        <div class="cx"><h2>Linha do tempo</h2><div class="sub">${d.eventos.length} eventos no site (${antes} antes de se identificar) · ${d.atividades.length} atividades</div>
          <ul class="linha-tempo" style="margin-top:10px">${itens.slice(0, 120).map(it => it.tipo === 'humano' ? `<li><div class="ponto ${it.a.tipo === 'etapa' ? 'etapa' : it.a.tipo === 'sistema' ? '' : 'humano'}">${it.a.tipo === 'etapa' ? ICO.seta : it.a.tipo === 'sistema' ? ICO.site : ICO.check}</div><div><b>${h(EV_HUMANO[it.a.tipo] || it.a.tipo)}${it.a.perfis?.nome ? ' · ' + h(it.a.perfis.nome) : ''}${it.a.resultado ? ' · ' + h(it.a.resultado) : ''}</b><small>${h(it.a.texto || '')}${it.a.meta?.rotulo ? ' — ' + h(it.a.meta.rotulo) + ' em ' + h(it.a.meta.pagina || '') : ''}</small><small class="quando">${fmtData(it.em)}</small></div></li>`
            : `<li><div class="ponto site">${it.e.nome.includes('whatsapp') || it.e.nome.includes('submit') ? ICO.wa : ICO.site}</div><div><b>${h(nomeEvento(it.e.nome))}</b><small>${h(it.e.pagina || '')}${it.e.rotulo ? ' · ' + h(it.e.rotulo) : ''}${it.e.props?.pergunta ? ' · “' + h(it.e.props.pergunta) + '”' : ''}${it.e.props?.termo ? ' · buscou “' + h(it.e.props.termo) + '”' : ''}${it.e.origem_motor ? ' · ' + h(it.e.origem_motor) : ''}${it.e.dispositivo ? ' · ' + h(it.e.dispositivo) : ''}</small><small class="quando">${fmtData(it.em)}</small></div></li>`).join('') || '<li class="vazio">Sem eventos.</li>'}</ul></div>
      </div>
      <div class="cx"><h2>Dados</h2><dl class="dados">
        <dt>Telefone</dt><dd>${h(p.telefone_fmt || p.telefone || '—')} ${chipConferir(p)}${p.telefone_conferir && p.telefone_motivo ? `<small style="display:block;color:var(--tinta-3)">${h(p.telefone_motivo)} — confirmar com a pessoa na conversa</small>` : ''}</dd>
        ${altsDe(p).length ? `<dt>Se não atender</dt><dd>${altsDe(p).map(a => `<div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin:2px 0"><a class="btn btn-p" target="_blank" rel="noopener" href="${waLink(a.numero, p.nome)}">${ICO.wa} ${h(fmtTel(a.numero))}</a><small style="color:var(--tinta-3)">${h(a.porque || '')}</small><button class="btn btn-p" data-eraeste="${h(tel(a.numero))}" title="Confirma este como o número principal da ficha">era este</button></div>`).join('')}</dd>` : ''}
        <dt>E-mail</dt><dd>${h(p.email || '—')}</dd>
        <dt>Cidade</dt><dd>${h(p.cidade || '—')}${p.cidade_ip ? ` <small style="color:var(--tinta-3)">· pelo IP: ${h(p.cidade_ip)}${p.uf_ip ? '/' + h(p.uf_ip) : ''}</small>` : ''}</dd>
        <dt>Origem da conversão</dt><dd class="chips">${chipOrigem(p.origem_conversao)}${p.origem_conversao?.referrer_host ? `<span class="chip c-borda">${h(p.origem_conversao.referrer_host)}</span>` : ''}${p.origem_conversao?.utm_campaign ? `<span class="chip c-borda">${h(p.origem_conversao.utm_campaign)}</span>` : ''}</dd>
        <dt>Primeira visita</dt><dd class="chips">${chipOrigem(p.origem_primeira)}${p.origem_primeira?.landing ? `<span class="chip c-borda">${h(p.origem_primeira.landing)}</span>` : ''}</dd>
        <dt>Comportamento</dt><dd>${p.visitas || 1} visita(s)${p.leitura != null ? ' · leu ' + p.leitura + '%' : ''}${p.tempo_site ? ' · ' + h(p.tempo_site) + ' no site' : ''}</dd>
        ${p.trajeto?.length ? `<dt>Trajeto</dt><dd style="font-size:13px">${p.trajeto.map(h).join(' › ')}</dd>` : ''}
        ${p.cidades_vistas?.length ? `<dt>Cidades vistas</dt><dd>${p.cidades_vistas.map(h).join(', ')}</dd>` : ''}
        <dt>Aceite LGPD</dt><dd>${p.aceite_lgpd_em ? fmtData(p.aceite_lgpd_em) : '—'}</dd>
        <dt>Observações</dt><dd><textarea class="nota" id="obs">${h(p.observacoes || '')}</textarea><button class="btn btn-p" id="salvar-obs" style="margin-top:6px">Salvar</button></dd>
      </dl></div>
    </div>`);
  ligarTopo();
  const neg = () => n0?.id;
  document.getElementById('falei').onclick = () => neg() ? modalFalei(neg(), p.id) : toast('Crie um negócio primeiro');
  document.getElementById('briefing').onclick = async () => { copiar(briefing(p, n0, d.eventos)); if (neg()) await dados.atividade({ negocio_id: neg(), pessoa_id: p.id, tipo: 'repasse', texto: 'Copiou o briefing' }); };
  const wa = document.getElementById('wa'); if (wa) wa.onclick = () => neg() && dados.atividade({ negocio_id: neg(), pessoa_id: p.id, tipo: 'whatsapp', texto: 'Abriu o WhatsApp pelo console', resultado: 'tentativa' });
  const lg = document.getElementById('ligar'); if (lg) lg.onclick = () => neg() && dados.atividade({ negocio_id: neg(), pessoa_id: p.id, tipo: 'ligacao', texto: 'Ligou pelo console', resultado: 'tentativa' });
  document.getElementById('salvar-obs').onclick = async () => { await dados.editarPessoa(p.id, { observacoes: document.getElementById('obs').value }); toast('Salvo'); };
  /* Gente da casa (31/08/2026): sócio/corretor/dono que testa o site virava
     lead e poluía fila e números. Marcar como interno apaga os cartões da
     pessoa (a ficha e o histórico de site ficam) e impede cartões novos. */
  document.getElementById('interna').onclick = () => {
    if (p.interna) { dados.marcarInterna(p.id, false).then(() => { toast('Volta a gerar cartões'); telaPessoa(p.id); }); return; }
    const qtd = (d.negocios || []).length;
    const f = modal(`<h2>Marcar ${h(nomeOk(p.nome))} como pessoa interna?</h2>
      <p style="font-size:14px;color:var(--tinta-2)">É para sócio, corretor ou dono. A pessoa sai da fila, do pipeline e dos números; ${qtd ? `os <b>${qtd}</b> cartão(ões) dela são apagados (o histórico de navegação e a ficha ficam)` : 'ela não ganha mais cartões'}. Dá para desfazer na própria ficha.</p>
      <div class="rodape"><button class="btn" type="button" data-fechar>Cancelar</button><button class="btn btn-ouro" type="button" data-ok>Marcar como interno</button></div>`);
    f.querySelector('[data-fechar]').onclick = () => f.remove();
    f.querySelector('[data-ok]').onclick = async () => {
      try { const r = await dados.marcarInterna(p.id, true); f.remove(); toast(r && r.ok === false ? (r.erro || 'Não deu') : 'Marcada como interna'); telaPessoa(p.id); }
      catch (e) { toast('Não deu para marcar agora'); }
    };
  };
  document.querySelectorAll('[data-eraeste]').forEach(b => b.onclick = async () => {
    b.disabled = true;
    try {
      const r = await dados.telefoneConfirmado(p.id, b.dataset.eraeste);
      if (r && r.ok === false) { toast(r.erro || 'Não deu para confirmar'); b.disabled = false; return; }
      toast('Número confirmado como principal');
      telaPessoa(p.id);
    } catch (e) { toast('Não deu para confirmar agora'); b.disabled = false; }
  });
  document.querySelectorAll('[data-etapa]').forEach(b => b.onclick = () => modalEtapa(b.dataset.etapa, b.dataset.funil, b.dataset.atual, p.id));
  document.querySelectorAll('[data-editar]').forEach(b => b.onclick = () => modalNegocio(d.negocios.find(x => x.id === b.dataset.editar), p));
  document.getElementById('novo-negocio').onclick = () => modalNegocio(null, p);
}
function modalNegocio(n, p) {
  const funis = estado.config?.funis || {}; const tipos = estado.config?.tipos || []; const perfis = estado.perfisLista || [];
  const f = modal(`<h2>${n ? 'Editar negócio' : 'Novo negócio'}</h2><form id="fneg">
    <div class="campo"><label>Funil</label><select name="funil">${Object.keys(funis).map(k => `<option value="${k}" ${n?.funil === k ? 'selected' : ''}>${h(funis[k].rotulo)}</option>`).join('')}</select></div>
    <div class="campo"><label>Tipo</label><select name="tipo"><option value="">—</option>${tipos.map(t => `<option ${n?.tipo === t ? 'selected' : ''}>${h(t)}</option>`).join('')}</select></div>
    <div class="campo"><label>Cidade / região</label><input name="cidade" value="${h(n?.cidade || p.cidade || '')}"></div>
    <div class="campo"><label>Área (ha)</label><input name="area_ha" type="number" step="0.1" value="${n?.area_ha ?? ''}"></div>
    <div class="campo"><label>Corretor</label><select name="corretor_id"><option value="">—</option>${perfis.filter(x => x.ativo).map(x => `<option value="${x.id}" ${n?.corretor_id === x.id ? 'selected' : ''}>${h(x.nome)}</option>`).join('')}</select></div>
    <div class="campo"><label>Próximo passo</label><input name="proximo_passo" value="${h(n?.proximo_passo || '')}"></div>
    <div class="campo"><label>Descrição / o que procura</label><textarea class="nota" name="descricao">${h(n?.descricao || '')}</textarea></div>
    ${n ? `<div class="campo"><label>Valor (R$)</label><input name="valor" type="number" step="1000" value="${n?.valor ?? ''}"></div>` : ''}
    <div class="rodape"><button class="btn" type="button" data-fechar>Cancelar</button><button class="btn btn-ouro" type="submit">Salvar</button></div></form>`);
  f.querySelector('[data-fechar]').onclick = () => f.remove();
  f.querySelector('form').onsubmit = async (e) => { e.preventDefault(); const d = Object.fromEntries(new FormData(e.target)); ['area_ha', 'valor'].forEach(k => { if (k in d) d[k] = d[k] === '' ? null : Number(d[k]); }); if (!d.corretor_id) d.corretor_id = null;
    if (n) await dados.editarNegocio(n.id, d); else await dados.criarNegocio({ ...d, pessoa_id: p.id, etapa: 'Novo', origem_evento: 'console', origem_rotulo: 'Criado no console' });
    f.remove(); toast('Salvo'); render(); };
}

/* --------------------------------------------------------------- origens */
async function telaOrigens() {
  const [origens, motores] = await Promise.all([dados.origensEvento(), dados.motores()]);
  const reg = estado.registro?.eventos || {};
  const contato = origens.filter(o => reg[o.nome]?.contato || /_click$|_submit$/.test(o.nome)).sort((a, b) => b.ultimos_30d - a.ultimos_30d);
  const maxC = Math.max(1, ...contato.map(o => o.ultimos_30d));
  const outros = origens.filter(o => !contato.includes(o)).sort((a, b) => b.ultimos_30d - a.ultimos_30d);
  const registrados = Object.keys(reg).filter(k => reg[k].contato && !origens.some(o => o.nome === k));
  const mortos = contato.filter(o => o.ultimo_em && (Date.now() - new Date(o.ultimo_em)) > 30 * 86400000);
  const ia = motores.filter(m => m.origem_tipo === 'ia'), busca = motores.filter(m => m.origem_tipo === 'busca'), resto = motores.filter(m => !['ia', 'busca'].includes(m.origem_tipo));
  const linhaMotor = m => `<div class="funil-ev"><div><b>${h(m.motor)}</b> <span class="chip ${m.origem_tipo === 'ia' ? 'c-ouro' : m.origem_tipo === 'busca' ? 'c-verde' : 'c-neutro'}">${h(m.origem_tipo)}</span></div><div class="n num">${m.visitantes_30d}</div><div class="n num">${m.cliques_30d}</div><div class="n num">${m.pessoas_30d}</div><div class="num">${m.visitantes_30d ? (m.pessoas_30d / m.visitantes_30d * 100).toFixed(1) + '%' : '—'}</div><div class="barra"><i style="width:${Math.min(100, m.cliques_30d / Math.max(1, ...motores.map(x => x.cliques_30d)) * 100)}%;background:${corMotor(m.motor, m.origem_tipo)}"></i></div></div>`;
  moldura('origens', `${topo('Origens', 'Qual botão, página e canal trazem lead que vira negócio')}
    <div class="cx" style="margin-bottom:14px"><h2>Motores e canais · 30 dias</h2><div class="sub">Visitantes, cliques de contato e pessoas identificadas por onde chegaram. IA em dourado.</div>
      <div class="funil-ev" style="font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--tinta-3)"><div>Motor</div><div>Visitantes</div><div>Cliques</div><div>Pessoas</div><div>Taxa</div><div></div></div>
      ${ia.map(linhaMotor).join('')}${busca.map(linhaMotor).join('')}${resto.map(linhaMotor).join('') || ''}${motores.length ? '' : '<p class="vazio">Sem visitas medidas ainda.</p>'}</div>
    <div class="cx" style="margin-bottom:14px"><h2>Botões de contato · 30 dias</h2><div class="sub">Cada nome é um identificador fixo do registro. O que varia (página, rótulo, interesse) fica na ficha da pessoa.</div>
      <div class="funil-ev" style="font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--tinta-3)"><div>Evento</div><div>30 dias</div><div>14 dias</div><div>Visitantes</div><div>Identific.</div><div></div></div>
      ${contato.map(o => `<div class="funil-ev"><div><b class="mono">${h(o.nome)}</b><br><small style="color:var(--tinta-3)">${h(reg[o.nome]?.o_que || '')}</small>${mortos.includes(o) ? '<br><span class="morto">sem clique há mais de 30 dias</span>' : ''}</div><div class="n num">${o.ultimos_30d}</div><div class="n num">${o.ultimos_14d}</div><div class="num">${o.visitantes}</div><div class="num">${o.identificados}</div><div class="barra"><i style="width:${o.ultimos_30d / maxC * 100}%"></i></div></div>`).join('') || '<p class="vazio">Nenhum clique de contato ainda.</p>'}
      ${registrados.length ? `<p style="font-size:13px;color:var(--tinta-3);margin-top:12px">No registro e nunca clicados: ${registrados.map(x => `<span class="mono">${h(x)}</span>`).join(', ')}</p>` : ''}</div>
    <div class="cx"><h2>Leitura e formulários</h2><div class="sub">Páginas vistas, leitura, formulários vistos e começados, FAQ, busca.</div>
      ${outros.map(o => `<div class="funil-ev"><div><b class="mono">${h(o.nome)}</b><br><small style="color:var(--tinta-3)">${h(reg[o.nome]?.o_que || '')}</small></div><div class="n num">${o.ultimos_30d}</div><div class="n num">${o.ultimos_14d}</div><div class="num">${o.visitantes}</div><div class="num">${o.identificados}</div><div></div></div>`).join('') || '<p class="vazio">Nada ainda.</p>'}</div>`);
  ligarTopo();
}

/* ------------------------------------------------------------ relatórios */
async function telaRelatorios() {
  const [fila, serie, perfis] = await Promise.all([dados.fila(), dados.serie(28), dados.perfis()]);
  const fins = estado.config?.etapas_finais || { ganhou: [], perdeu: [] };
  const semana = fila.filter(n => (Date.now() - new Date(n.criado_em)) < 7 * 86400000);
  const porCorretor = perfis.filter(p => p.papel !== 'leitura').map(p => { const l = fila.filter(n => n.corretor_id === p.id); const c = l.filter(n => n.primeiro_contato_em); const med = c.length ? c.map(n => n.minutos_ate_contato).sort((a, b) => a - b)[Math.floor(c.length / 2)] : null;
    return { nome: p.nome, total: l.length, contatados: c.length, ganhos: l.filter(n => fins.ganhou.includes(n.etapa)).length, perdidos: l.filter(n => fins.perdeu.includes(n.etapa)).length, mediana: med }; });
  const perdas = {}; fila.filter(n => fins.perdeu.includes(n.etapa)).forEach(n => perdas[n.motivo_perda || '(sem motivo)'] = (perdas[n.motivo_perda || '(sem motivo)'] || 0) + 1);
  const porOrigem = {}; fila.forEach(n => { const m = n.origem_conversao?.motor || n.origem_conversao?.tipo || '(direto)'; porOrigem[m] = porOrigem[m] || { n: 0, g: 0 }; porOrigem[m].n++; if (fins.ganhou.includes(n.etapa)) porOrigem[m].g++; });
  const csv = () => { const linhas = [['codigo', 'nome', 'telefone', 'criado_em', 'funil', 'etapa', 'tipo', 'cidade', 'origem_tipo', 'origem_motor', 'origem_via', 'evento', 'pagina', 'rotulo', 'corretor', 'primeiro_contato_em', 'minutos_ate_contato', 'esteve_no_site', 'motivo_perda', 'valor'].join(';')];
    fila.forEach(n => linhas.push([n.codigo, nomeOk(n.pessoa_nome), n.telefone, n.criado_em, n.funil, n.etapa, n.tipo, n.pessoa_cidade, n.origem_conversao?.tipo, n.origem_conversao?.motor, n.origem_conversao?.via, n.origem_evento, n.origem_pagina, n.origem_rotulo, n.corretor_nome, n.primeiro_contato_em, n.primeiro_contato_em ? Math.round(n.minutos_ate_contato) : '', n.esteve_no_site, n.motivo_perda, n.valor].map(v => '"' + String(v ?? '').replace(/"/g, '""') + '"').join(';')));
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['﻿' + linhas.join('\n')], { type: 'text/csv;charset=utf-8' })); a.download = 'leads-' + new Date().toISOString().slice(0, 10) + '.csv'; a.click(); };
  moldura('relatorios', `${topo('Relatórios', 'A semana em uma tela, para mandar na segunda', '<button class="btn" id="csv">Exportar CSV</button>')}
    <div class="kpis"><div class="kpi"><div class="cab">${ICO.pessoas}</div><b class="num">${semana.length}</b><span>negócios · 7 dias</span></div>
      <div class="kpi"><div class="cab">${ICO.check}</div><b class="num verde">${semana.filter(n => n.primeiro_contato_em).length}</b><span>contatados</span></div>
      <div class="kpi"><div class="cab">${ICO.fila}</div><b class="num ouro">${fila.filter(n => fins.ganhou.includes(n.etapa)).length}</b><span>ganhos no total</span></div>
      <div class="kpi"><div class="cab">${ICO.wa}</div><b class="num">${serie.slice(-7).reduce((s, x) => s + Number(x.cliques_contato), 0)}</b><span>cliques de contato · 7 dias</span></div></div>
    <div class="grade-2">
      <div class="cx"><h2>Por corretor</h2><div class="rolo"><table class="tabela"><thead><tr><th>Corretor</th><th>Negócios</th><th>Contatados</th><th>Mediana até o 1º contato</th><th>Ganhos</th><th>Perdidos</th></tr></thead><tbody>
        ${porCorretor.map(c => `<tr><td>${h(c.nome)}</td><td class="num">${c.total}</td><td class="num">${c.contatados}</td><td class="num">${c.mediana != null ? duracao(c.mediana) : '—'}</td><td class="num">${c.ganhos}</td><td class="num">${c.perdidos}</td></tr>`).join('')}</tbody></table></div></div>
      <div class="cx"><h2>Perdas por motivo</h2>${Object.entries(perdas).sort((a, b) => b[1] - a[1]).map(([m, n]) => `<div class="funil-ev" style="grid-template-columns:1fr auto"><div>${h(m)}</div><div class="n num">${n}</div></div>`).join('') || '<p class="vazio">Nenhuma perda registrada.</p>'}
        <h2 style="margin-top:18px">Conversão por origem</h2>${Object.entries(porOrigem).sort((a, b) => b[1].n - a[1].n).map(([m, v]) => `<div class="funil-ev" style="grid-template-columns:1fr auto auto"><div>${h(m)}</div><div class="num">${v.n}</div><div class="n num">${v.g} ganho(s)</div></div>`).join('')}</div>
    </div>`);
  ligarTopo(); document.getElementById('csv').onclick = csv;
}

/* ---------------------------------------------------------------- config */
async function telaConfig() {
  const perfis = await dados.perfis(); const cfg = estado.config || {};
  moldura('config', `${topo('Configurações', 'Quem entra, com que regra')}
    <div class="grade-2">
      <div class="cx"><h2>Usuários</h2><div class="sub">Crie o usuário no Supabase (Authentication → Users → Add user). Ele aparece aqui no primeiro login; defina papel e ative.</div>
        <div class="rolo"><table class="tabela"><thead><tr><th>Nome</th><th>E-mail</th><th>Papel</th><th>Ativo</th></tr></thead><tbody>
        ${perfis.map(p => `<tr data-id="${p.id}"><td><input class="nota" style="min-height:0;padding:6px 8px" value="${h(p.nome)}" data-campo="nome"></td><td>${h(p.email)}</td><td><select data-campo="papel" class="nota" style="min-height:0;padding:6px 8px">${['dono', 'corretor', 'leitura'].map(x => `<option ${p.papel === x ? 'selected' : ''}>${x}</option>`).join('')}</select></td><td><input type="checkbox" data-campo="ativo" ${p.ativo ? 'checked' : ''}></td></tr>`).join('')}</tbody></table></div></div>
      <div class="cx"><h2>Atendimento (SLA)</h2><form id="fsla">
        <div class="campo"><label>Prazo para o primeiro contato (minutos úteis)</label><input name="minutos" type="number" value="${cfg.sla?.minutos ?? 30}"></div>
        <div class="campo"><label>Horário</label><div style="display:flex;gap:8px"><input name="inicio" type="time" value="${cfg.sla?.horario?.inicio ?? '08:00'}"><input name="fim" type="time" value="${cfg.sla?.horario?.fim ?? '18:30'}"></div></div>
        <div class="campo"><label>Dias</label><div style="display:flex;gap:6px;flex-wrap:wrap">${['D', 'S', 'T', 'Q', 'Q', 'S', 'S'].map((d, i) => `<label class="chip c-borda" style="cursor:pointer"><input type="checkbox" name="dia" value="${i}" ${(cfg.sla?.horario?.dias || [1, 2, 3, 4, 5, 6]).includes(i) ? 'checked' : ''}> ${d}</label>`).join('')}</div></div>
        <div class="campo"><label>Motivos de perda (um por linha)</label><textarea class="nota" name="motivos">${h((cfg.motivos_perda || []).join('\n'))}</textarea></div>
        <button class="btn btn-ouro" type="submit">Salvar</button></form></div>
    </div>`);
  ligarTopo();
  document.querySelectorAll('tr[data-id] [data-campo]').forEach(el => el.onchange = async () => { const id = el.closest('tr').dataset.id; const v = el.type === 'checkbox' ? el.checked : el.value; await dados.atualizarPerfil(id, { [el.dataset.campo]: v }); toast('Salvo'); });
  document.getElementById('fsla').onsubmit = async (e) => { e.preventDefault(); const d = new FormData(e.target);
    await dados.salvarConfig('sla', { minutos: Number(d.get('minutos')), horario: { inicio: d.get('inicio'), fim: d.get('fim'), dias: d.getAll('dia').map(Number) }, fuso: 'America/Sao_Paulo' });
    await dados.salvarConfig('motivos_perda', String(d.get('motivos')).split('\n').map(x => x.trim()).filter(Boolean));
    estado.config = await dados.config(); toast('Salvo'); };
}

/* --------------------------------------------------------------- roteador */
let renderizando = false;
async function render() {
  const [rota, arg] = (location.hash.replace(/^#\/?/, '') || 'visao').split('/');
  const sess = await dados.sessao();
  if (!sess) return telaLogin();
  if (!estado.perfil) { estado.perfil = await dados.perfil(); if (estado.perfil && estado.perfil.ativo === false) { await dados.sair(); return telaLogin('Seu usuário ainda não foi ativado pelo dono.'); } }
  if (!estado.config) estado.config = await dados.config();
  if (!estado.perfisLista) estado.perfisLista = await dados.perfis();
  if (!estado.registro) { try { estado.registro = await (await fetch(C.registroEventos || '/eventos.json')).json(); } catch { estado.registro = { eventos: {} }; } }
  if (renderizando) return; renderizando = true;
  try {
    switch (rota) {
      case 'fila': await telaFila(); break;
      case 'pipeline': await telaPipeline(); break;
      case 'pessoas': await telaPessoas(); break;
      case 'pessoa': await telaPessoa(arg); break;
      case 'origens': await telaOrigens(); break;
      case 'relatorios': await telaRelatorios(); break;
      case 'config': await telaConfig(); break;
      default: await telaVisao();
    }
  } catch (e) { console.error(e); app.innerHTML = `<div class="login"><div class="cx"><h1>Algo falhou</h1><p style="color:var(--tinta-2)">${h(e.message || e)}</p><button class="btn btn-ouro" onclick="location.reload()">Recarregar</button></div></div>`; }
  finally { renderizando = false; }
}
async function iniciar() {
  window.addEventListener('hashchange', render);
  dados.aoMudarAuth((ev) => { if (ev === 'SIGNED_OUT') { estado.perfil = null; telaLogin(); } });
  let t; dados.aoVivo(() => { clearTimeout(t); t = setTimeout(render, 800); });
  await render();
}
iniciar();
if ('serviceWorker' in navigator && !DEMO) navigator.serviceWorker.register('/sw.js').catch(() => {});
