// HTTP (panel estático + API) y WebSocket para tiempo real.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(__dirname, '..', 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };

export function startWeb(cfg, registry, agents, graylog, log) {
  const w = cfg.web;
  const lastRebootAt = new Map();

  function authUser(req) {
    if (!w.auth || !w.auth.user) return 'anónimo';
    const h = req.headers.authorization || '';
    if (!h.startsWith('Basic ')) return null;
    const [u, p] = Buffer.from(h.slice(6), 'base64').toString('utf8').split(':');
    return u === w.auth.user && p === w.auth.pass ? u : null;
  }
  const clientIp = (req) => (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim().replace(/^::ffff:/, '');
  const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); };

  function statePayload() {
    return { serverTime: Date.now(), devices: registry.snapshot(), alerts: registry.alerts.slice(-100), counts: registry.counts(),
      thresholds: cfg.thresholds, graylog: graylog.status(), offlineAfterSec: cfg.agents.offlineAfterSec, rebootCooldownSec: w.rebootCooldownSec };
  }

  async function handleReboot(req, res, id, user) {
    const d = registry.get(id);
    if (!d) return json(res, 404, { ok: false, error: 'banca desconocida' });
    const ip = clientIp(req);
    const last = lastRebootAt.get(id) || 0;
    if (Date.now() - last < w.rebootCooldownSec * 1000) {
      return json(res, 429, { ok: false, error: `ya se pidió un reinicio hace ${Math.round((Date.now() - last) / 1000)} s` });
    }
    const by = `${user}@${ip}`;
    // Los eventos van a Graylog vía registry.on('alert') en index.js
    registry.addEvent(id, 'warn', `Reinicio solicitado para ${d.name} por ${by}`, { event: 'reboot_request', by, user, requester_ip: ip });
    try {
      const ack = await agents.sendCommand(id, 'reboot', { by });
      if (ack.ok === false) throw new Error(ack.error || 'rechazado por el agente');
      lastRebootAt.set(id, Date.now());
      registry.noteReboot(id, by);
      registry.addEvent(id, 'info', `${d.name} confirmó el reinicio`, { event: 'reboot_ack', by });
      log.info(`[web] reinicio de ${id} confirmado (por ${by})`);
      json(res, 200, { ok: true });
    } catch (e) {
      registry.addEvent(id, 'crit', `Falló el reinicio de ${d.name}: ${e.message}`, { event: 'reboot_failed', by, error: e.message });
      log.warn(`[web] reinicio de ${id} falló: ${e.message}`);
      json(res, 502, { ok: false, error: e.message });
    }
  }

  const server = http.createServer(async (req, res) => {
    const user = authUser(req);
    if (!user) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="rpi-monitor", charset="UTF-8"' });
      return res.end('Autenticación requerida');
    }
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname;
    try {
      if (p === '/api/state' && req.method === 'GET') return json(res, 200, statePayload());
      if (p === '/api/alerts' && req.method === 'GET') return json(res, 200, { alerts: registry.alerts });
      if (p === '/api/health') return json(res, 200, { ok: true, counts: registry.counts(), agentsConnected: agents.connectedCount(), graylog: graylog.status() });
      let m;
      if ((m = p.match(/^\/api\/devices\/([^/]+)\/reboot$/)) && req.method === 'POST') return handleReboot(req, res, decodeURIComponent(m[1]), user);
      if ((m = p.match(/^\/api\/devices\/([^/]+)\/sample$/)) && req.method === 'POST') {
        try { await agents.sendCommand(decodeURIComponent(m[1]), 'sample'); return json(res, 200, { ok: true }); }
        catch (e) { return json(res, 502, { ok: false, error: e.message }); }
      }
      if (p.startsWith('/api/')) return json(res, 404, { ok: false, error: 'no encontrado' });

      // estáticos
      let file = p === '/' ? '/index.html' : p;
      file = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
      const abs = path.join(PUBLIC, file);
      if (!abs.startsWith(PUBLIC) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) { res.writeHead(404); return res.end('404'); }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(abs)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
      fs.createReadStream(abs).pipe(res);
    } catch (e) {
      log.error(`[web] ${req.method} ${p}: ${e.stack || e.message}`);
      json(res, 500, { ok: false, error: 'error interno' });
    }
  });

  const wss = new WebSocketServer({ noServer: true, clientTracking: true });
  server.on('upgrade', (req, sock, head) => {
    if (!authUser(req)) { sock.write('HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="rpi-monitor"\r\n\r\n'); sock.destroy(); return; }
    if (new URL(req.url, 'http://localhost').pathname !== '/ws') { sock.destroy(); return; }
    wss.handleUpgrade(req, sock, head, (ws) => wss.emit('connection', ws, req));
  });
  wss.on('connection', (ws) => {
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('error', () => {});
    ws.send(JSON.stringify({ type: 'snapshot', ...statePayload() }));
  });
  const broadcast = (obj) => {
    const s = JSON.stringify(obj);
    for (const c of wss.clients) if (c.readyState === 1) c.send(s);
  };
  registry.on('update', (d) => broadcast({ type: 'device', device: d, counts: registry.counts() }));
  registry.on('alert', (a) => broadcast({ type: 'alert', alert: a }));
  setInterval(() => {
    for (const c of wss.clients) { if (!c.isAlive) { c.terminate(); continue; } c.isAlive = false; c.ping(); }
    broadcast({ type: 'tick', serverTime: Date.now(), counts: registry.counts(), graylog: graylog.status() });
  }, 15000).unref();

  server.on('error', (e) => { log.error(`[web] ${e.message}`); process.exit(1); });
  server.listen(w.port, w.bind, () => log.info(`[web] panel en http://${w.bind}:${w.port}/ ${w.auth?.user ? '(con autenticación básica)' : '(SIN autenticación)'}`));
  return { broadcast };
}
