// Envío de mensajes GELF 1.1 a Graylog por UDP (con chunking) o TCP (null-terminated).
import dgram from 'node:dgram';
import net from 'node:net';
import os from 'node:os';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

const GELF_LEVEL = { crit: 2, error: 3, warn: 4, notice: 5, info: 6, ok: 6, debug: 7 };
const UDP_CHUNK = 8000;

export class Graylog {
  constructor(cfg, log) {
    this.cfg = cfg;
    this.log = log;
    this.enabled = !!cfg.enabled;
    this.sent = 0;
    this.errors = 0;
    this.lastError = null;
    if (!this.enabled) return;
    if (cfg.protocol === 'tcp') this._connectTcp();
    else this.udp = dgram.createSocket('udp4');
  }

  status() {
    return { enabled: this.enabled, host: this.cfg.host, port: this.cfg.port, protocol: this.cfg.protocol, sent: this.sent, errors: this.errors, lastError: this.lastError, connected: this.cfg.protocol === 'tcp' ? !!this.tcpReady : this.enabled };
  }

  // send('mensaje corto', { level: 'warn', station: 'banca-07', ... })
  send(shortMessage, fields = {}) {
    const { level = 'info', fullMessage, timestamp, ...extra } = fields;
    const gelf = {
      version: '1.1',
      host: this.cfg.source || os.hostname(),
      short_message: shortMessage,
      timestamp: (timestamp ?? Date.now()) / 1000,
      level: typeof level === 'number' ? level : GELF_LEVEL[level] ?? 6,
      _facility: this.cfg.facility || 'rpi-monitor',
      _level_name: typeof level === 'number' ? String(level) : level,
    };
    if (fullMessage) gelf.full_message = fullMessage;
    for (const [k, v] of Object.entries(extra)) {
      if (v === undefined || v === null) continue;
      gelf[`_${k}`] = typeof v === 'object' ? JSON.stringify(v) : v;
    }
    if (!this.enabled) {
      this.log.info(`[graylog:off] ${shortMessage}`);
      return;
    }
    const payload = Buffer.from(JSON.stringify(gelf), 'utf8');
    if (this.cfg.protocol === 'tcp') this._sendTcp(payload);
    else this._sendUdp(payload);
  }

  _sendUdp(payload) {
    let data = this.cfg.compress ? zlib.gzipSync(payload) : payload;
    const done = (err) => {
      if (err) { this.errors++; this.lastError = err.message; this.log.warn(`graylog udp: ${err.message}`); }
      else this.sent++;
    };
    if (data.length <= UDP_CHUNK) {
      this.udp.send(data, this.cfg.port, this.cfg.host, done);
      return;
    }
    const id = crypto.randomBytes(8);
    const total = Math.ceil(data.length / UDP_CHUNK);
    if (total > 128) { this.errors++; this.lastError = 'mensaje demasiado grande'; return; }
    for (let i = 0; i < total; i++) {
      const chunk = data.subarray(i * UDP_CHUNK, (i + 1) * UDP_CHUNK);
      const hdr = Buffer.from([0x1e, 0x0f, ...id, i, total]);
      this.udp.send(Buffer.concat([hdr, chunk]), this.cfg.port, this.cfg.host, i === total - 1 ? done : undefined);
    }
  }

  _connectTcp() {
    this.tcpReady = false;
    this.tcpQueue = this.tcpQueue || [];
    const sock = net.createConnection({ host: this.cfg.host, port: this.cfg.port });
    sock.setKeepAlive(true, 30000);
    sock.on('connect', () => {
      this.tcpReady = true;
      this.log.info(`graylog tcp conectado a ${this.cfg.host}:${this.cfg.port}`);
      for (const p of this.tcpQueue.splice(0)) this._sendTcp(p);
    });
    sock.on('error', (e) => { this.errors++; this.lastError = e.message; });
    sock.on('close', () => {
      this.tcpReady = false;
      this.tcp = null;
      setTimeout(() => this._connectTcp(), 5000);
    });
    this.tcp = sock;
  }

  _sendTcp(payload) {
    if (!this.tcpReady || !this.tcp) {
      if (this.tcpQueue.length < 1000) this.tcpQueue.push(payload);
      return;
    }
    this.tcp.write(Buffer.concat([payload, Buffer.from([0])]), (err) => {
      if (err) { this.errors++; this.lastError = err.message; } else this.sent++;
    });
  }
}
