// Estado en memoria de todas las bancas + detección de transiciones (alertas).
import { EventEmitter } from 'node:events';
import { evaluate, worst, describe, voltReadingBogus } from './thresholds.js';

const METRIC_KEYS = ['ts', 'temp_c', 'volt_core', 'volt_sdram_c', 'volt_sdram_p', 'volt_sdram_i', 'volt_valid', 'throttled', 'throttled_raw',
  'cpu_pct', 'cpu_mhz', 'load1', 'mem_total_mb', 'mem_used_mb', 'mem_pct', 'lat_ms', 'lat_target', 'lat_method', 'uptime_s', 'source'];

export class Registry extends EventEmitter {
  constructor(cfg) {
    super();
    this.cfg = cfg;
    this.devices = new Map();
    this.alerts = [];
    this.maxAlerts = 500;
    cfg.stations.forEach((s, i) => this.devices.set(s.id, this._blank(s.id, s.name, i)));
  }

  _blank(id, name, order) {
    return {
      id, name: name || id, order,
      online: false, lastSeen: null, connectedAt: null,
      ip: null, peerIp: null, mac: null, iface: null, ifaces: null,
      host: null, model: null, kernel: null, arch: null, version: null, interval: null, banca: null,
      metrics: null, status: {}, overall: 'offline', serverRtt: null,
      lastReboot: null, rebootPending: false,
    };
  }

  has(id) { return this.devices.has(id); }
  get(id) { return this.devices.get(id); }

  _getOrCreate(id) {
    let d = this.devices.get(id);
    if (!d) {
      d = this._blank(id, id, 1000 + this.devices.size);
      this.devices.set(id, d);
    }
    return d;
  }

  setOnline(id, info) {
    const d = this._getOrCreate(id);
    const was = d.online;
    Object.assign(d, {
      online: true, connectedAt: Date.now(), lastSeen: Date.now(),
      ip: info.ip ?? d.ip, peerIp: info.peerIp ?? d.peerIp, mac: info.mac ?? d.mac, iface: info.iface ?? d.iface,
      ifaces: info.ifaces ?? d.ifaces, host: info.host ?? d.host, model: info.model ?? d.model,
      kernel: info.kernel ?? d.kernel, arch: info.arch ?? d.arch, version: info.version ?? d.version, interval: info.interval ?? d.interval, banca: info.banca ?? d.banca,
    });
    if (d.overall === 'offline') d.overall = 'unknown';
    if (!was) this._alert(d, 'online', 'info', `${d.name} conectada desde ${d.ip}${d.rebootPending ? ' (volvió tras reinicio)' : ''}`, { event: 'online' });
    d.rebootPending = false;
    this.emit('update', d);
    return d;
  }

  setOffline(id, reason) {
    const d = this.devices.get(id);
    if (!d || !d.online) return;
    d.online = false;
    d.overall = 'offline';
    d.status = {};
    d.serverRtt = null;
    const lvl = d.rebootPending ? 'warn' : 'crit';
    this._alert(d, 'offline', lvl, `${d.name} sin conexión (${reason})${d.rebootPending ? ' — reinicio en curso' : ''}`, { event: 'offline', reason });
    this.emit('update', d);
  }

  update(id, msg, ip) {
    const d = this._getOrCreate(id);
    d.lastSeen = Date.now();
    d.online = true;
    if (msg.ip) d.ip = msg.ip;
    else if (ip) d.ip = ip;
    if (ip) d.peerIp = ip;
    const m = {};
    for (const k of METRIC_KEYS) if (msg[k] !== undefined) m[k] = msg[k];
    if (voltReadingBogus(m)) m.volt_valid = false;
    m.receivedAt = Date.now();
    d.metrics = m;
    const prev = d.status || {};
    const st = evaluate(m, this.cfg.thresholds);
    d.status = st;
    d.overall = worst(Object.values(st));
    for (const [metric, level] of Object.entries(st)) {
      const p = prev[metric];
      if (p && p !== level) {
        const alertLevel = level === 'ok' ? 'info' : level;
        this._alert(d, metric, alertLevel, `${d.name}: ${describe(metric, level, m, this.cfg.thresholds)}`, {
          event: 'threshold', from: p, to: level, value: m[metric] ?? m.throttled,
        });
      } else if (!p && (level === 'warn' || level === 'crit')) {
        // primera muestra ya en alerta
        this._alert(d, metric, level, `${d.name}: ${describe(metric, level, m, this.cfg.thresholds)}`, {
          event: 'threshold', from: 'none', to: level, value: m[metric] ?? m.throttled,
        });
      }
    }
    this.emit('update', d);
    return d;
  }

  setServerRtt(id, rtt) {
    const d = this.devices.get(id);
    if (d) d.serverRtt = rtt;
  }

  noteReboot(id, by) {
    const d = this.devices.get(id);
    if (!d) return;
    d.lastReboot = { at: Date.now(), by };
    d.rebootPending = true;
    this.emit('update', d);
  }

  checkTimeouts(ms) {
    const now = Date.now();
    for (const d of this.devices.values()) {
      if (d.online && now - d.lastSeen > ms) this.setOffline(d.id, `sin datos hace ${Math.round((now - d.lastSeen) / 1000)} s`);
    }
  }

  _alert(d, metric, level, message, extra = {}) {
    const a = { ts: Date.now(), id: d.id, name: d.name, ip: d.ip, metric, level, message, ...extra };
    this.alerts.push(a);
    if (this.alerts.length > this.maxAlerts) this.alerts.splice(0, this.alerts.length - this.maxAlerts);
    this.emit('alert', a);
    return a;
  }

  addEvent(id, level, message, extra = {}) {
    const d = id ? this._getOrCreate(id) : { id: null, name: 'servidor', ip: null };
    return this._alert(d, extra.event || 'event', level, message, extra);
  }

  snapshot() {
    return [...this.devices.values()].sort((a, b) => a.order - b.order || a.id.localeCompare(b.id));
  }

  counts() {
    const c = { total: 0, ok: 0, warn: 0, crit: 0, offline: 0, unknown: 0 };
    for (const d of this.devices.values()) { c.total++; c[d.overall] = (c[d.overall] || 0) + 1; }
    return c;
  }
}
