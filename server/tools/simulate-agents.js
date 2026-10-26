// Simula N agentes contra el servidor para probar el panel sin Raspberrys.
//   node tools/simulate-agents.js [host] [port] [token] [count]
import net from 'node:net';

const [host = '127.0.0.1', port = '7070', token = 'cambiar-este-token', count = '53', start = '0'] = process.argv.slice(2);
const N = Number(count), FIRST = Number(start);

function agent(n) {
  const id = `banca-${String(n).padStart(2, '0')}`;
  const ip = `10.0.1.${10 + n}`;
  const mac = `dc:a6:32:${String(n).padStart(2, '0')}:0a:${(n * 7 % 256).toString(16).padStart(2, '0')}`;
  let temp = 45 + Math.random() * 20, cpu = 10 + Math.random() * 30, mem = 25 + Math.random() * 30, lat = 1 + Math.random() * 5;
  let sock, timer;
  const connect = () => {
    sock = net.createConnection({ host, port: Number(port) }, () => {
      sock.write(JSON.stringify({ type: 'hello', id, host: id, token, version: 'sim', interval: 5, banca: String(n),
        ip, mac, iface: 'eth0', ifaces: [{ name: 'eth0', ip, mac }], model: 'Raspberry Pi 4 Model B Rev 1.4 (sim)', kernel: '6.1.0', arch: 'aarch64' }) + '\n');
      timer = setInterval(sendMetrics, 5000);
      sendMetrics();
    });
    let buf = '';
    sock.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        try {
          const msg = JSON.parse(line);
          if (msg.type === 'ping') sock.write(JSON.stringify({ type: 'pong', t: msg.t }) + '\n');
          if (msg.type === 'cmd') {
            sock.write(JSON.stringify({ type: 'ack', req: msg.req, cmd: msg.cmd, ok: true }) + '\n');
            if (msg.cmd === 'reboot') { console.log(`${id}: reboot simulado`); clearInterval(timer); sock.end(); setTimeout(connect, 20000 + Math.random() * 10000); }
            if (msg.cmd === 'sample') sendMetrics();
          }
        } catch {}
      }
    });
    sock.on('error', () => {});
    sock.on('close', () => { clearInterval(timer); });
  };
  const sendMetrics = () => {
    temp += (Math.random() - 0.5) * 3; cpu += (Math.random() - 0.5) * 10; mem += (Math.random() - 0.5) * 2; lat += (Math.random() - 0.5) * 2;
    temp = Math.max(35, Math.min(88, temp)); cpu = Math.max(0, Math.min(100, cpu)); mem = Math.max(10, Math.min(99, mem)); lat = Math.max(0.3, lat);
    const spike = Math.random() < 0.02;
    const throttled = n % 13 === 0 ? 0x50000 : n % 17 === 0 ? 0x50005 : 0;
    const m = { type: 'metrics', id, ip, ts: Date.now(), temp_c: +temp.toFixed(1), volt_core: +(0.85 + (Math.random() - 0.5) * 0.02).toFixed(4),
      volt_sdram_c: 1.1, volt_sdram_p: 1.1, volt_sdram_i: 1.1, throttled: '0x' + throttled.toString(16), throttled_raw: throttled,
      cpu_pct: +cpu.toFixed(1), cpu_mhz: cpu > 50 ? 1500 : 600, load1: +(cpu / 25).toFixed(2), mem_total_mb: 3794, mem_used_mb: Math.round(3794 * mem / 100), mem_pct: +mem.toFixed(1),
      lat_ms: spike ? null : +(lat + (Math.random() < 0.05 ? 150 : 0)).toFixed(2), lat_target: host, lat_method: 'icmp', uptime_s: 86400 * n + 1234, source: 'sim' };
    if (sock.writable) sock.write(JSON.stringify(m) + '\n');
  };
  setTimeout(connect, Math.random() * 2000);
}
for (let n = FIRST; n < FIRST + N; n++) agent(n);
console.log(`simulando ${N} agentes (banca ${FIRST} … ${FIRST + N - 1}) contra ${host}:${port}`);
