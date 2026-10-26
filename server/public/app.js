// Panel en tiempo real: recibe snapshot + actualizaciones por WebSocket.
const $ = (s, r = document) => r.querySelector(s);
const grid = $('#grid'), alertList = $('#alertList'), tpl = $('#cardTpl');
const cards = new Map(); // id -> { el, device }
let thresholds = {}, offlineAfterSec = 20, rebootCooldownSec = 60;
let ws, reconnectDelay = 1000;

const fmt = {
  temp: (v) => v == null ? '—' : `${Number(v).toFixed(1)}°`,
  volt: (v) => v == null ? '—' : `${Number(v).toFixed(2)}V`,
  pct: (v) => v == null ? '—' : `${Math.round(v)}%`,
  lat: (v) => v == null ? 'sin resp.' : v < 10 ? `${Number(v).toFixed(1)}ms` : `${Math.round(v)}ms`,
  uptime: (s) => { if (s == null) return '—'; s = Math.floor(s); const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`; },
  ago: (ts) => { if (!ts) return 'nunca'; const s = Math.max(0, Math.round((Date.now() - ts) / 1000)); return s < 60 ? `hace ${s} s` : s < 3600 ? `hace ${Math.floor(s / 60)} min` : `hace ${Math.floor(s / 3600)} h`; },
  time: (ts) => new Date(ts).toLocaleTimeString('es-AR', { hour12: false }),
};
const STATE_LABEL = { ok: 'ok', warn: 'aviso', crit: 'crítico', offline: 'sin conexión', unknown: 'sin datos', rebooting: 'reiniciando' };

function toast(msg, err = false) {
  const t = $('#toast'); t.textContent = msg; t.className = 'toast' + (err ? ' err' : ''); t.hidden = false;
  clearTimeout(toast.timer); toast.timer = setTimeout(() => { t.hidden = true; }, 4000);
}

function undervoltText(m) {
  if (!m || m.throttled_raw == null) return '—';
  const b = Number(m.throttled_raw);
  if (b & 1) return 'BAJO';
  if (b & 0x10000) return 'ocurrió';
  return 'ok';
}

function render(d) {
  let c = cards.get(d.id);
  if (!c) {
    const el = tpl.content.firstElementChild.cloneNode(true);
    el.dataset.id = d.id;
    $('.reboot', el).addEventListener('click', () => reboot(d.id));
    c = { el, device: d };
    cards.set(d.id, c);
    grid.appendChild(el);
  }
  c.device = d;
  const el = c.el;
  const rebooting = d.rebootPending && (Date.now() - (d.lastReboot?.at || 0)) < 180000;
  const overall = rebooting && !d.online ? 'rebooting' : d.overall;
  el.className = `card ${overall}`;
  $('.name', el).textContent = d.name;
  $('.id', el).textContent = d.id !== d.name ? d.id : (d.host && d.host !== d.id ? d.host : '');
  $('.state', el).textContent = STATE_LABEL[overall] || overall;
  const ifaceList = (d.ifaces || []).map((f) => `  ${f.name}: ${f.ip}${f.mac ? ' · ' + f.mac : ''}`).join('\n');
  el.title = [d.banca != null && `idBanca ${d.banca} (settings.ini)`,
    d.ip && `IP ${d.ip}${d.iface ? ' (' + d.iface + ')' : ''}`,
    d.mac && `MAC ${d.mac}`,
    d.peerIp && d.peerIp !== d.ip && `visto por el servidor como ${d.peerIp}`,
    ifaceList && `interfaces:\n${ifaceList}`,
    d.model, d.host && `host ${d.host}`, d.kernel && `kernel ${d.kernel}`, d.version && `rpimon ${d.version}`, d.metrics?.lat_target && `latencia hacia ${d.metrics.lat_target} (${d.metrics.lat_method})`, d.metrics?.cpu_mhz && `ARM ${d.metrics.cpu_mhz} MHz · load ${d.metrics.load1}`, d.metrics?.throttled && `throttled ${d.metrics.throttled}`, d.lastReboot && `último reinicio ${fmt.time(d.lastReboot.at)} por ${d.lastReboot.by}`].filter(Boolean).join('\n');
  const m = d.metrics || {}, st = d.online ? d.status : {};
  const set = (key, text) => { const me = $(`.metric[data-m="${key}"]`, el); me.className = `metric ${st[key] || ''}`; $('.val', me).textContent = text; };
  set('temp_c', fmt.temp(m.temp_c));
  set('volt_core', fmt.volt(m.volt_core));
  set('cpu_pct', fmt.pct(m.cpu_pct));
  set('mem_pct', fmt.pct(m.mem_pct));
  set('lat_ms', d.online ? fmt.lat(m.lat_ms) : '—');
  set('undervoltage', undervoltText(d.online ? m : null));
  $('.info', el).textContent = d.online ? `${d.ip || ''} · up ${fmt.uptime(m.uptime_s)} · ${fmt.ago(d.lastSeen)}` : `${d.ip ? d.ip + ' · ' : ''}visto ${fmt.ago(d.lastSeen)}`;
  $('.reboot', el).disabled = !d.online;
  applyFilter(c);
}

function applyFilter(c) {
  const q = $('#filter').value.trim().toLowerCase();
  const only = $('#onlyProblems').checked;
  const d = c.device;
  const match = !q || d.id.toLowerCase().includes(q) || d.name.toLowerCase().includes(q) || (d.ip || '').includes(q) ||
    (d.mac || '').toLowerCase().includes(q) || (d.ifaces || []).some((f) => f.ip.includes(q) || (f.mac || '').toLowerCase().includes(q));
  const problem = d.overall !== 'ok';
  c.el.classList.toggle('hiddenCard', !match || (only && !problem));
}

function renderCounts(counts) {
  if (!counts) return;
  const map = { ok: 'ok', warn: 'aviso', crit: 'crítico', offline: 'sin conexión' };
  for (const [k, label] of Object.entries(map)) $(`#counts [data-k="${k}"]`).textContent = `${counts[k] || 0} ${label}`;
  document.title = `${counts.crit ? '🔴 ' : counts.warn ? '🟡 ' : ''}Bancas ${counts.ok}/${counts.total} ok`;
}

function renderGraylog(g) {
  const el = $('#graylog');
  if (!g) return;
  el.className = 'graylog ' + (!g.enabled ? '' : g.errors && g.lastError && g.sent === 0 ? 'err' : 'on');
  el.textContent = g.enabled ? `Graylog ${g.sent}${g.errors ? ` / ${g.errors} err` : ''}` : 'Graylog off';
  el.title = g.enabled ? `${g.protocol}://${g.host}:${g.port}${g.lastError ? '\núltimo error: ' + g.lastError : ''}` : 'Envío a Graylog deshabilitado';
}

function addAlert(a, prepend = true) {
  const li = document.createElement('li');
  li.className = a.level;
  li.innerHTML = `<time>${fmt.time(a.ts)}</time>${escapeHtml(a.message)}`;
  if (prepend) alertList.prepend(li); else alertList.appendChild(li);
  while (alertList.children.length > 300) alertList.lastChild.remove();
}
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

async function reboot(id) {
  const d = cards.get(id)?.device;
  if (!d) return;
  if (!confirm(`¿Reiniciar ${d.name} (${d.id}${d.ip ? ', ' + d.ip : ''})?`)) return;
  try {
    const r = await fetch(`/api/devices/${encodeURIComponent(id)}/reboot`, { method: 'POST' });
    const j = await r.json();
    if (j.ok) toast(`${d.name}: reinicio confirmado por el agente`);
    else toast(`${d.name}: ${j.error}`, true);
  } catch (e) { toast(`Error: ${e.message}`, true); }
}

function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws`);
  ws.onopen = () => { $('#conn').classList.add('on'); reconnectDelay = 1000; };
  ws.onclose = () => { $('#conn').classList.remove('on'); setTimeout(connect, reconnectDelay); reconnectDelay = Math.min(reconnectDelay * 2, 15000); };
  ws.onerror = () => ws.close();
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'snapshot') {
      thresholds = msg.thresholds; offlineAfterSec = msg.offlineAfterSec; rebootCooldownSec = msg.rebootCooldownSec;
      for (const c of cards.values()) c.el.remove();
      cards.clear();
      alertList.innerHTML = '';
      msg.devices.forEach(render);
      msg.alerts.slice().reverse().forEach((a) => addAlert(a, false));
      renderCounts(msg.counts); renderGraylog(msg.graylog);
    } else if (msg.type === 'device') { render(msg.device); renderCounts(msg.counts); }
    else if (msg.type === 'alert') addAlert(msg.alert);
    else if (msg.type === 'tick') { renderCounts(msg.counts); renderGraylog(msg.graylog); }
  };
}

$('#filter').addEventListener('input', () => cards.forEach(applyFilter));
$('#onlyProblems').addEventListener('change', () => cards.forEach(applyFilter));
$('#toggleAlerts').addEventListener('click', () => $('#alerts').classList.toggle('hidden'));
$('#clearAlerts').addEventListener('click', () => { alertList.innerHTML = ''; });
setInterval(() => { $('#clock').textContent = new Date().toLocaleTimeString('es-AR', { hour12: false }); for (const c of cards.values()) { const info = $('.info', c.el); const d = c.device; if (d.online) info.textContent = `${d.ip || ''} · up ${fmt.uptime(d.metrics?.uptime_s)} · ${fmt.ago(d.lastSeen)}`; } }, 1000);
connect();
