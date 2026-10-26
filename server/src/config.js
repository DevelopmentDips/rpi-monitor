import fs from 'node:fs';
import path from 'node:path';

const DEFAULTS = {
  agents: { bind: '0.0.0.0', port: 7070, token: '', offlineAfterSec: 20, pingIntervalSec: 10, allowUnknown: true },
  web: { bind: '0.0.0.0', port: 8080, auth: null, rebootCooldownSec: 60 },
  graylog: { enabled: false, host: '127.0.0.1', port: 12201, protocol: 'udp', source: 'rpi-monitor', facility: 'rpi-monitor', compress: false, metricsEverySec: 0 },
  thresholds: {
    unknownLevel: 'warn',
    temp_c: { warn: 70, crit: 80 },
    volt_core: { warnBelow: 0.82, critBelow: 0.78, warn: 1.0, crit: 1.1 },
    lat_ms: { warn: 100, crit: 300 },
    cpu_pct: { warn: 85, crit: 95 },
    mem_pct: { warn: 85, crit: 95 },
    undervoltage: { now: 'crit', occurred: 'warn' },
    throttling: { now: 'warn', occurred: 'ok' },
  },
  stationsAuto: null,
  stations: [],
};

function merge(base, over) {
  if (Array.isArray(base) || Array.isArray(over)) return over ?? base;
  if (typeof base !== 'object' || base === null || typeof over !== 'object' || over === null) return over ?? base;
  const out = { ...base };
  for (const k of Object.keys(over)) out[k] = merge(base[k], over[k]);
  return out;
}

export function loadConfig(file) {
  let user = {};
  const abs = path.resolve(file);
  if (fs.existsSync(abs)) {
    user = JSON.parse(fs.readFileSync(abs, 'utf8'));
  } else {
    console.warn(`[config] ${abs} no existe; usando valores por defecto`);
  }
  const cfg = merge(DEFAULTS, user);
  cfg.file = abs;

  // Variables de entorno útiles para contenedores
  if (process.env.RPIMON_TOKEN) cfg.agents.token = process.env.RPIMON_TOKEN;
  if (process.env.GRAYLOG_HOST) { cfg.graylog.host = process.env.GRAYLOG_HOST; cfg.graylog.enabled = true; }
  if (process.env.GRAYLOG_PORT) cfg.graylog.port = Number(process.env.GRAYLOG_PORT);

  // Estaciones: lista explícita + autogeneradas
  const stations = [...(cfg.stations || [])];
  if (cfg.stationsAuto && cfg.stationsAuto.count > 0) {
    const { prefix = 'banca-', start = 1, count, pad = 2, nameFormat = 'Banca {n}' } = cfg.stationsAuto;
    for (let n = start; n < start + count; n++) {
      const num = String(n).padStart(pad, '0');
      const id = `${prefix}${num}`;
      if (!stations.some((s) => s.id === id)) {
        stations.push({ id, name: nameFormat.replace('{n}', String(n)).replace('{nn}', num) });
      }
    }
  }
  cfg.stations = stations;
  if (!cfg.agents.token) console.warn('[config] agents.token vacío: cualquier agente podrá conectarse');
  return cfg;
}
