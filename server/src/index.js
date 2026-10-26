import { loadConfig } from './config.js';
import { log } from './logger.js';
import { Graylog } from './graylog.js';
import { Registry } from './registry.js';
import { startAgentServer } from './agents.js';
import { startWeb } from './web.js';

const cfg = loadConfig(process.argv[2] || process.env.RPIMON_CONFIG || 'config.json');
log.info(`rpi-monitor-server: ${cfg.stations.length} bancas configuradas (${cfg.file})`);

const graylog = new Graylog(cfg.graylog, log);
const registry = new Registry(cfg);

// Toda alerta/transición va a Graylog
registry.on('alert', (a) => {
  const { message, level, ts, id, name, ip, metric, event, ...rest } = a;
  const d = id ? registry.get(id) : null;
  graylog.send(message, {
    level: level === 'info' ? 'info' : level,
    timestamp: ts,
    station: id, station_name: name, station_ip: ip, station_mac: d?.mac, station_peer_ip: d?.peerIp !== ip ? d?.peerIp : undefined,
    metric, event: event || 'alert',
    overall: d?.overall, host: d?.host, ...rest,
  });
});

const agents = startAgentServer(cfg, registry, log);
startWeb(cfg, registry, agents, graylog, log);

// Opcional: métricas periódicas a Graylog (para dashboards/histórico)
if (cfg.graylog.enabled && cfg.graylog.metricsEverySec > 0) {
  setInterval(() => {
    for (const d of registry.snapshot()) {
      if (!d.online || !d.metrics) continue;
      const m = d.metrics;
      graylog.send(`${d.name}: métricas`, {
        level: 'debug', event: 'metrics', station: d.id, station_name: d.name, station_ip: d.ip, station_mac: d.mac, overall: d.overall,
        temp_c: m.temp_c, volt_core: m.volt_core, throttled: m.throttled, cpu_pct: m.cpu_pct, mem_pct: m.mem_pct,
        lat_ms: m.lat_ms, uptime_s: m.uptime_s, cpu_mhz: m.cpu_mhz, load1: m.load1,
      });
    }
  }, cfg.graylog.metricsEverySec * 1000).unref();
}

graylog.send('rpi-monitor-server iniciado', { level: 'info', event: 'server_start', stations: cfg.stations.length });
process.on('SIGTERM', () => { log.info('SIGTERM, saliendo'); process.exit(0); });
process.on('SIGINT', () => { log.info('SIGINT, saliendo'); process.exit(0); });
process.on('uncaughtException', (e) => log.error('excepción no capturada:', e.stack || e));
