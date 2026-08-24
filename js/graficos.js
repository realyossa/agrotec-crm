// graficos.js — canvas puro, sem biblioteca. Linha (período atual + anterior
// tracejado) e donut. Cores vêm dos tokens CSS para seguir o tema.

function cor(nome) { return getComputedStyle(document.documentElement).getPropertyValue(nome).trim(); }
// aceita 'var(--x)' vindo da tela e devolve a cor resolvida (canvas não entende var())
export function resolver(c) { const m = /^var\((--[\w-]+)\)$/.exec(String(c || '').trim()); return m ? cor(m[1]) : c; }
function dpr() { return Math.min(2, window.devicePixelRatio || 1); }
function prepara(cv) {
  const r = cv.getBoundingClientRect(); const k = dpr();
  cv.width = Math.round(r.width * k); cv.height = Math.round(r.height * k);
  const g = cv.getContext('2d'); g.setTransform(k, 0, 0, k, 0, 0); return [g, r.width, r.height];
}

/** linha(cv, {rotulos:[...], atual:[...], anterior:[...], destaque:[...]}) */
export function linha(cv, s) {
  const [g, W, H] = prepara(cv);
  const padL = 34, padR = 12, padT = 16, padB = 28;
  const w = W - padL - padR, h = H - padT - padB;
  const n = s.atual.length; if (!n) return;
  const max = Math.max(4, ...s.atual, ...(s.anterior || []));
  const passo = max <= 8 ? 2 : max <= 20 ? 5 : max <= 50 ? 10 : Math.ceil(max / 5 / 10) * 10;
  const topo = Math.ceil(max / passo) * passo;
  const x = i => padL + (n === 1 ? w / 2 : i * (w / (n - 1)));
  const y = v => padT + h - (v / topo) * h;
  g.clearRect(0, 0, W, H);
  g.font = '11px Outfit, system-ui, sans-serif'; g.textBaseline = 'middle';
  g.strokeStyle = cor('--grade'); g.lineWidth = 1; g.fillStyle = cor('--tinta-3');
  for (let v = 0; v <= topo; v += passo) { g.beginPath(); g.moveTo(padL, y(v)); g.lineTo(W - padR, y(v)); g.stroke(); g.textAlign = 'right'; g.fillText(String(v), padL - 8, y(v)); }
  g.textAlign = 'center'; g.textBaseline = 'top';
  const cada = n > 16 ? Math.ceil(n / 8) : n > 8 ? 2 : 1;
  s.rotulos.forEach((r, i) => { if (i % cada === 0 || i === n - 1) g.fillText(r, x(i), H - padB + 10); });
  const suave = (pts) => { // curva Catmull-Rom → Bézier
    if (pts.length < 2) return; g.moveTo(pts[0][0], pts[0][1]);
    for (let i = 0; i < pts.length - 1; i++) { const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
      g.bezierCurveTo(p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6, p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6, p2[0], p2[1]); }
  };
  if (s.anterior && s.anterior.length === n) {
    g.beginPath(); suave(s.anterior.map((v, i) => [x(i), y(v)])); g.strokeStyle = cor('--linha-anterior'); g.setLineDash([4, 4]); g.lineWidth = 1.5; g.stroke(); g.setLineDash([]);
  }
  const pts = s.atual.map((v, i) => [x(i), y(v)]);
  if (n > 1) {
    g.beginPath(); suave(pts); g.lineTo(pts[n - 1][0], padT + h); g.lineTo(pts[0][0], padT + h); g.closePath();
    const grad = g.createLinearGradient(0, padT, 0, padT + h); grad.addColorStop(0, cor('--area-grafico')); grad.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = grad; g.fill();
    g.beginPath(); suave(pts); g.strokeStyle = cor('--linha-grafico'); g.lineWidth = 2.4; g.lineJoin = 'round'; g.stroke();
  }
  if (s.destaque && s.destaque.length === n) { // pontos de IA, menores, em dourado/verde
    g.fillStyle = cor('--verde');
    s.destaque.forEach((v, i) => { if (v > 0) { g.beginPath(); g.arc(x(i), y(v), 2.6, 0, Math.PI * 2); g.fill(); } });
  }
  const u = pts[n - 1]; g.beginPath(); g.arc(u[0], u[1], 4.5, 0, Math.PI * 2); g.fillStyle = cor('--papel'); g.fill(); g.lineWidth = 2.4; g.strokeStyle = cor('--linha-grafico'); g.stroke();
  // tooltip simples
  cv.onmousemove = (e) => { const rect = cv.getBoundingClientRect(); const i = Math.round((e.clientX - rect.left - padL) / (w / Math.max(1, n - 1))); const t = cv.parentElement.querySelector('.tt'); if (!t) return;
    if (i < 0 || i >= n) { t.hidden = true; return; } t.hidden = false; t.style.left = (x(i)) + 'px'; t.style.top = (y(s.atual[i]) - 34) + 'px';
    t.textContent = s.rotulos[i] + ' · ' + s.atual[i] + (s.anterior ? ' (antes ' + s.anterior[i] + ')' : ''); };
  cv.onmouseleave = () => { const t = cv.parentElement.querySelector('.tt'); if (t) t.hidden = true; };
}

/** donut(cv, [{rotulo, valor, cor}]) */
export function donut(cv, fatias) {
  const [g, W, H] = prepara(cv);
  const total = fatias.reduce((s, f) => s + f.valor, 0) || 1;
  const cx = W / 2, cy = H / 2, R = Math.min(W, H) / 2 - 4, r = R * .66;
  g.clearRect(0, 0, W, H);
  let a = -Math.PI / 2;
  fatias.forEach(f => { const d = (f.valor / total) * Math.PI * 2; g.beginPath(); g.arc(cx, cy, R, a, a + d); g.arc(cx, cy, r, a + d, a, true); g.closePath(); g.fillStyle = resolver(f.cor); g.fill();
    g.strokeStyle = cor('--papel'); g.lineWidth = 2; g.stroke(); a += d; });
  g.fillStyle = cor('--tinta'); g.font = '600 22px Outfit, system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(String(total === 1 && !fatias.length ? 0 : fatias.reduce((s, f) => s + f.valor, 0)), cx, cy - 6);
  g.fillStyle = cor('--tinta-3'); g.font = '10.5px Outfit, system-ui, sans-serif'; g.fillText('pessoas', cx, cy + 12);
}

/** barras horizontais simples para o funil de um evento */
export function barra(el, pct, cor_) { el.innerHTML = `<i style="width:${Math.max(2, Math.min(100, pct))}%;background:${cor_ || 'var(--ouro)'}"></i>`; }
