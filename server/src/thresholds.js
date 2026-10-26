// Evaluación de umbrales. Cada métrica devuelve 'ok' | 'warn' | 'crit' | 'unknown'.

export const LEVEL_ORDER = { ok: 0, unknown: 1, warn: 2, crit: 3, offline: 4 };

export const METRIC_LABELS = {
  temp_c: 'temperatura',
  volt_core: 'voltaje core',
  lat_ms: 'latencia',
  cpu_pct: 'uso de CPU',
  mem_pct: 'uso de memoria',
  undervoltage: 'subvoltaje (5V)',
  throttling: 'throttling',
};

const UNITS = { temp_c: ' °C', volt_core: ' V', lat_ms: ' ms', cpu_pct: ' %', mem_pct: ' %' };

export function worst(levels) {
  let w = 'ok';
  for (const l of levels) if ((LEVEL_ORDER[l] ?? 0) > (LEVEL_ORDER[w] ?? 0)) w = l;
  return w;
}

function levelOf(value, t) {
  if (!t) return 'ok';
  if (value === null || value === undefined || Number.isNaN(value)) return 'unknown';
  if (t.crit != null && value >= t.crit) return 'crit';
  if (t.critBelow != null && value <= t.critBelow) return 'crit';
  if (t.warn != null && value >= t.warn) return 'warn';
  if (t.warnBelow != null && value <= t.warnBelow) return 'warn';
  return 'ok';
}

// Bits de get_throttled (firmware Raspberry Pi):
// 0 subvoltaje ahora, 1 freq ARM limitada, 2 throttled ahora, 3 límite térmico soft;
// 16..19 lo mismo pero "ocurrió desde el arranque".
export function decodeThrottled(raw) {
  if (raw === null || raw === undefined) return null;
  const b = Number(raw) | 0;
  return {
    undervoltNow: !!(b & 0x1),
    freqCappedNow: !!(b & 0x2),
    throttledNow: !!(b & 0x4),
    softTempNow: !!(b & 0x8),
    undervoltOccurred: !!(b & 0x10000),
    freqCappedOccurred: !!(b & 0x20000),
    throttledOccurred: !!(b & 0x40000),
    softTempOccurred: !!(b & 0x80000),
  };
}

export function evaluate(m, th) {
  const unk = th.unknownLevel || 'warn';
  const norm = (l) => (l === 'unknown' ? unk : l);
  const s = {};
  s.temp_c = norm(levelOf(m.temp_c, th.temp_c));
  s.volt_core = norm(levelOf(m.volt_core, th.volt_core));
  // Latencia: null significa "sin respuesta" -> crítico
  s.lat_ms = m.lat_ms == null ? 'crit' : levelOf(m.lat_ms, th.lat_ms);
  s.cpu_pct = norm(levelOf(m.cpu_pct, th.cpu_pct));
  s.mem_pct = norm(levelOf(m.mem_pct, th.mem_pct));
  const t = decodeThrottled(m.throttled_raw);
  if (t) {
    s.undervoltage = t.undervoltNow ? th.undervoltage.now : t.undervoltOccurred ? th.undervoltage.occurred : 'ok';
    s.throttling = t.throttledNow || t.softTempNow ? th.throttling.now : t.throttledOccurred || t.softTempOccurred ? th.throttling.occurred : 'ok';
  } else {
    s.undervoltage = unk;
    s.throttling = unk;
  }
  return s;
}

export function describe(metric, level, m, th) {
  const label = METRIC_LABELS[metric] || metric;
  const lvl = { ok: 'normal', warn: 'advertencia', crit: 'crítico', unknown: 'sin dato' }[level] || level;
  if (metric === 'undervoltage' || metric === 'throttling') {
    const t = decodeThrottled(m.throttled_raw);
    const detail = !t ? 'sin dato' : metric === 'undervoltage'
      ? (t.undervoltNow ? 'activo ahora' : t.undervoltOccurred ? 'ocurrió desde el arranque' : 'sin subvoltaje')
      : (t.throttledNow ? 'activo ahora' : t.softTempNow ? 'límite térmico activo' : t.throttledOccurred ? 'ocurrió desde el arranque' : 'sin throttling');
    return `${label}: ${detail} (${lvl}, throttled=${m.throttled ?? 'null'})`;
  }
  const v = m[metric];
  const val = v == null ? 'sin respuesta' : `${Number(v).toFixed(metric === 'volt_core' ? 3 : 1)}${UNITS[metric] || ''}`;
  const t = th[metric] || {};
  const lim = level === 'crit' ? (t.crit != null && v >= t.crit ? `≥ ${t.crit}` : t.critBelow != null ? `≤ ${t.critBelow}` : '')
    : level === 'warn' ? (t.warn != null && v >= t.warn ? `≥ ${t.warn}` : t.warnBelow != null ? `≤ ${t.warnBelow}` : '') : '';
  return `${label}: ${val} (${lvl}${lim ? `, umbral ${lim}` : ''})`;
}
