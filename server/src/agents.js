// Servidor TCP para los agentes rpimon. Protocolo: un JSON por línea en ambos sentidos.
//   agente -> servidor: hello, metrics, pong, ack
//   servidor -> agente: hello_ack, error, ping, cmd {cmd:'reboot'|'sample', req}
import net from 'node:net';
import crypto from 'node:crypto';

export function startAgentServer(cfg, registry, log) {
  const a = cfg.agents;
  const conns = new Map();   // id -> ctx
  const pending = new Map(); // req -> { resolve, reject, timer }

  function send(ctx, obj) {
    if (ctx.sock.writable) ctx.sock.write(JSON.stringify(obj) + '\n');
  }

  function handleLine(ctx, line) {
    let msg;
    try { msg = JSON.parse(line); } catch { log.warn(`[agents] JSON inválido desde ${ctx.ip}`); return; }
    ctx.lastRx = Date.now();

    if (msg.type === 'hello') {
      if (a.token && msg.token !== a.token) {
        log.warn(`[agents] token inválido desde ${ctx.ip} (id=${msg.id})`);
        send(ctx, { type: 'error', error: 'token inválido' });
        ctx.sock.destroy();
        return;
      }
      const id = String(msg.id || '').trim();
      if (!id || id.length > 64) { send(ctx, { type: 'error', error: 'id inválido' }); ctx.sock.destroy(); return; }
      if (a.allowUnknown === false && !registry.has(id)) {
        log.warn(`[agents] id desconocido rechazado: ${id} (${ctx.ip})`);
        send(ctx, { type: 'error', error: 'id no registrado' });
        ctx.sock.destroy();
        return;
      }
      const prev = conns.get(id);
      if (prev && prev !== ctx) {
        log.warn(`[agents] ${id} reconectó desde ${ctx.ip}; cerrando conexión anterior (${prev.ip})`);
        prev.id = null; // que el close no marque offline
        prev.sock.destroy();
      }
      ctx.id = id;
      conns.set(id, ctx);
      clearTimeout(ctx.helloTimer);
      registry.setOnline(id, { ip: msg.ip || ctx.ip, peerIp: ctx.ip, mac: msg.mac ?? null, iface: msg.iface ?? null,
        ifaces: Array.isArray(msg.ifaces) ? msg.ifaces.slice(0, 8) : null,
        host: msg.host, version: msg.version, model: msg.model, kernel: msg.kernel, arch: msg.arch, interval: msg.interval, banca: msg.banca ?? null });
      send(ctx, { type: 'hello_ack', serverTime: Date.now() });
      log.info(`[agents] ${id} conectada desde ${msg.ip || ctx.ip}${msg.ip && msg.ip !== ctx.ip ? ` (socket ${ctx.ip})` : ''}${msg.mac ? ` mac ${msg.mac}` : ''} (${msg.model || 'modelo desconocido'}, rpimon ${msg.version})`);
      return;
    }
    if (!ctx.id) { send(ctx, { type: 'error', error: 'hello requerido' }); ctx.sock.destroy(); return; }

    switch (msg.type) {
      case 'metrics':
        registry.update(ctx.id, msg, ctx.ip);
        break;
      case 'pong':
        if (typeof msg.t === 'number') registry.setServerRtt(ctx.id, Date.now() - msg.t);
        break;
      case 'ack': {
        const p = pending.get(msg.req);
        if (p) { clearTimeout(p.timer); pending.delete(msg.req); p.resolve(msg); }
        break;
      }
      case 'log':
        log.info(`[${ctx.id}] ${msg.msg}`);
        break;
      default:
        log.debug(`[agents] tipo desconocido de ${ctx.id}: ${msg.type}`);
    }
  }

  const server = net.createServer((sock) => {
    sock.setNoDelay(true);
    sock.setKeepAlive(true, 10000);
    const ctx = { sock, id: null, buf: '', ip: (sock.remoteAddress || '').replace(/^::ffff:/, ''), lastRx: Date.now() };
    ctx.helloTimer = setTimeout(() => {
      if (!ctx.id) { log.warn(`[agents] ${ctx.ip} no envió hello; cerrando`); sock.destroy(); }
    }, 10000);
    sock.on('data', (d) => {
      ctx.buf += d.toString('utf8');
      let i;
      while ((i = ctx.buf.indexOf('\n')) >= 0) {
        const line = ctx.buf.slice(0, i).trim();
        ctx.buf = ctx.buf.slice(i + 1);
        if (line) handleLine(ctx, line);
      }
      if (ctx.buf.length > 65536) { log.warn(`[agents] buffer excedido desde ${ctx.ip}`); sock.destroy(); }
    });
    sock.on('error', (e) => log.debug(`[agents] socket ${ctx.id || ctx.ip}: ${e.message}`));
    sock.on('close', () => {
      clearTimeout(ctx.helloTimer);
      if (ctx.id && conns.get(ctx.id) === ctx) {
        conns.delete(ctx.id);
        registry.setOffline(ctx.id, 'conexión cerrada');
      }
    });
  });

  server.on('error', (e) => { log.error(`[agents] ${e.message}`); process.exit(1); });
  server.listen(a.port, a.bind, () => log.info(`[agents] escuchando agentes en ${a.bind}:${a.port}`));

  setInterval(() => {
    for (const ctx of conns.values()) send(ctx, { type: 'ping', t: Date.now() });
  }, Math.max(2, a.pingIntervalSec) * 1000).unref();
  setInterval(() => registry.checkTimeouts(a.offlineAfterSec * 1000), 1000).unref();

  return {
    isConnected: (id) => conns.has(id),
    connectedCount: () => conns.size,
    sendCommand(id, cmd, extra = {}, timeoutMs = 5000) {
      return new Promise((resolve, reject) => {
        const ctx = conns.get(id);
        if (!ctx) return reject(new Error('el agente no está conectado'));
        const req = crypto.randomUUID();
        const timer = setTimeout(() => { pending.delete(req); reject(new Error('el agente no respondió')); }, timeoutMs);
        pending.set(req, { resolve, reject, timer });
        send(ctx, { type: 'cmd', cmd, req, ...extra });
      });
    },
  };
}
