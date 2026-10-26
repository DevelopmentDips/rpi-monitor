// rpimon — agente de monitoreo para Raspberry Pi 4 (sin dependencias externas).
//
// Recolecta temperatura, voltajes (core / sdram), estado de throttling y subvoltaje,
// uso de CPU, memoria, uptime y latencia hacia un host, y lo envía por TCP al
// servidor rpi-monitor (un objeto JSON por línea). Mantiene la conexión abierta para
// recibir comandos del panel (p.ej. "reboot").
//
// Fuentes de datos, en orden de preferencia:
//   - Mailbox de VideoCore (/dev/vcio): temperatura, voltajes, throttled, clock ARM.
//     Es lo mismo que usa vcgencmd por debajo, pero sin depender del binario.
//   - vcgencmd (si existe en el PATH).
//   - sysfs: /sys/class/thermal, /sys/class/hwmon (rpi_volt), cpufreq, get_throttled.
//   - procfs: /proc/stat, /proc/meminfo, /proc/uptime, /proc/loadavg.
//
// Compilar:  g++ -O2 -std=c++17 -static -o rpimon rpimon.cpp
// Uso:       rpimon --server 10.0.0.1 --port 7070 --id banca-07 --token XXXX

#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static const char* RPIMON_VERSION = "1.0.0";
static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

// ------------------------------------------------------------------ logging
static void logmsg(const char* level, const char* fmt, ...) {
    char ts[32];
    time_t t = time(nullptr);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(stderr, "%s [%s] ", ts, level);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}
#define LOGI(...) logmsg("INFO", __VA_ARGS__)
#define LOGW(...) logmsg("WARN", __VA_ARGS__)
#define LOGE(...) logmsg("ERROR", __VA_ARGS__)

// ------------------------------------------------------------------ utils
static int64_t now_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static double now_hr_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
static int64_t epoch_ms() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}
static std::string read_file(const std::string& path) {
    std::ifstream f(path);
    if (!f) return "";
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}
static std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}
static std::string run_cmd(const std::string& cmd) {
    FILE* p = popen((cmd + " 2>/dev/null").c_str(), "r");
    if (!p) return "";
    char buf[256];
    std::string out;
    while (fgets(buf, sizeof buf, p)) out += buf;
    pclose(p);
    return out;
}
static std::string json_escape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
                else o += (char)c;
        }
    }
    return o;
}
static std::string jstr(const std::string& s) { return "\"" + json_escape(s) + "\""; }
static std::string jnum(double v, int prec = 2) {
    if (std::isnan(v) || std::isinf(v)) return "null";
    char b[64];
    snprintf(b, sizeof b, "%.*f", prec, v);
    return b;
}
// Extrae el valor de una clave en un objeto JSON plano (suficiente para los
// mensajes de control del servidor). Devuelve "" si no está.
static std::string json_get(const std::string& s, const std::string& key) {
    std::string k = "\"" + key + "\"";
    size_t p = s.find(k);
    if (p == std::string::npos) return "";
    p = s.find(':', p + k.size());
    if (p == std::string::npos) return "";
    p++;
    while (p < s.size() && isspace((unsigned char)s[p])) p++;
    if (p >= s.size()) return "";
    if (s[p] == '"') {
        std::string out;
        for (p++; p < s.size() && s[p] != '"'; p++) {
            if (s[p] == '\\' && p + 1 < s.size()) { p++; out += s[p]; }
            else out += s[p];
        }
        return out;
    }
    size_t e = p;
    while (e < s.size() && s[e] != ',' && s[e] != '}') e++;
    return trim(s.substr(p, e - p));
}

// ------------------------------------------------------------------ config
struct Config {
    std::string config_file = "/etc/rpimon.conf";
    std::string server = "127.0.0.1";
    int port = 7070;
    std::string token;
    std::string id;              // identificador de la banca (default: desde id_file, si no hostname)
    std::string id_file = "/var/local/settings.ini";  // archivo INI con el número de banca
    std::string id_key = "idBanca";                   // clave dentro del INI
    std::string id_prefix = "banca-";                 // id = prefix + número con ceros a la izquierda
    int id_pad = 2;
    std::string banca;           // número de banca crudo (informativo, va en el hello)
    int interval = 5;            // segundos entre envíos
    std::string ping_target;     // host para medir latencia (default: server)
    int ping_port = 0;           // puerto para fallback TCP (default: port)
    int ping_timeout_ms = 1000;
    std::string reboot_cmd;      // comando de reinicio (default: reboot / syscall)
    bool no_reboot = false;      // modo prueba: no reinicia realmente
    bool no_mailbox = false;     // no usar /dev/vcio
};

static bool apply_kv(Config& c, const std::string& k, const std::string& v) {
    if (k == "server") c.server = v;
    else if (k == "port") c.port = atoi(v.c_str());
    else if (k == "token") c.token = v;
    else if (k == "id") c.id = v;
    else if (k == "id_file") c.id_file = v;
    else if (k == "id_key") c.id_key = v;
    else if (k == "id_prefix") c.id_prefix = v;
    else if (k == "id_pad") c.id_pad = atoi(v.c_str());
    else if (k == "interval") c.interval = atoi(v.c_str());
    else if (k == "ping_target" || k == "ping") c.ping_target = v;
    else if (k == "ping_port") c.ping_port = atoi(v.c_str());
    else if (k == "ping_timeout_ms") c.ping_timeout_ms = atoi(v.c_str());
    else if (k == "reboot_cmd") c.reboot_cmd = v;
    else if (k == "no_reboot") c.no_reboot = (v == "1" || v == "true" || v == "yes");
    else if (k == "no_mailbox") c.no_mailbox = (v == "1" || v == "true" || v == "yes");
    else return false;
    return true;
}

static void load_config_file(Config& c, const std::string& path) {
    std::ifstream f(path);
    if (!f) return;
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        n++;
        std::string t = trim(line);
        if (t.empty() || t[0] == '#' || t[0] == ';') continue;
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        std::string k = trim(t.substr(0, eq)), v = trim(t.substr(eq + 1));
        if (v.size() >= 2 && (v[0] == '"' || v[0] == '\'') && v.back() == v[0]) v = v.substr(1, v.size() - 2);
        if (!apply_kv(c, k, v)) LOGW("%s:%d clave desconocida '%s'", path.c_str(), n, k.c_str());
    }
    LOGI("configuración cargada de %s", path.c_str());
}

// Lee una clave de un archivo INI (ignora secciones, comentarios ; y #, y comillas).
static std::string ini_get(const std::string& path, const std::string& key) {
    std::ifstream f(path);
    if (!f) return "";
    std::string line;
    while (std::getline(f, line)) {
        std::string t = trim(line);
        if (t.empty() || t[0] == ';' || t[0] == '#' || t[0] == '[') continue;
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        if (trim(t.substr(0, eq)) != key) continue;
        std::string v = trim(t.substr(eq + 1));
        size_t c = v.find(" ;");  // comentario al final de línea
        if (c != std::string::npos) v = trim(v.substr(0, c));
        if (v.size() >= 2 && (v[0] == '"' || v[0] == '\'') && v.back() == v[0]) v = v.substr(1, v.size() - 2);
        return v;
    }
    return "";
}

// Determina el id de la banca: --id > id_file (idBanca) > hostname.
static void resolve_id(Config& c) {
    if (!c.id_file.empty()) {
        std::string n = ini_get(c.id_file, c.id_key);
        if (!n.empty()) {
            c.banca = n;
            if (c.id.empty()) {
                std::string num = n;
                bool digits = !num.empty() && num.find_first_not_of("0123456789") == std::string::npos;
                if (digits) while ((int)num.size() < c.id_pad) num = "0" + num;
                c.id = c.id_prefix + num;
                LOGI("banca %s leída de %s (%s) -> id %s", n.c_str(), c.id_file.c_str(), c.id_key.c_str(), c.id.c_str());
            }
        } else if (c.id.empty()) {
            LOGW("no se pudo leer %s de %s; se usa el hostname como id", c.id_key.c_str(), c.id_file.c_str());
        }
    }
    if (c.id.empty()) {
        char h[256] = {0};
        gethostname(h, sizeof h - 1);
        c.id = h;
    }
}

static void usage(const char* argv0) {
    fprintf(stderr,
        "rpimon %s — agente de monitoreo Raspberry Pi\n"
        "Uso: %s [opciones]\n"
        "  --config FILE        archivo de configuración (default /etc/rpimon.conf)\n"
        "  --server HOST        servidor rpi-monitor\n"
        "  --port N             puerto TCP del servidor (default 7070)\n"
        "  --token TOKEN        token compartido con el servidor\n"
        "  --id ID              identificador de la banca (default: desde id_file, si no hostname)\n"
        "  --id-file FILE       INI con el número de banca (default /var/local/settings.ini)\n"
        "  --id-key KEY         clave en el INI (default idBanca)\n"
        "  --id-prefix PFX      prefijo del id (default banca-)\n"
        "  --id-pad N           ceros a la izquierda del número (default 2)\n"
        "  --interval SEG       segundos entre reportes (default 5)\n"
        "  --ping HOST          host para medir latencia (default: el servidor)\n"
        "  --ping-port N        puerto para latencia TCP si ICMP no está disponible\n"
        "  --ping-timeout MS    timeout de latencia (default 1000)\n"
        "  --reboot-cmd CMD     comando para reiniciar (default: reboot)\n"
        "  --no-reboot          modo prueba: registra pero no reinicia\n"
        "  --no-mailbox         no usar /dev/vcio (solo sysfs/vcgencmd)\n"
        "  --once               imprime una muestra en JSON y termina\n",
        RPIMON_VERSION, argv0);
}

static Config parse_args(int argc, char** argv, bool& once) {
    Config c;
    once = false;
    // Primera pasada: --config
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--config" && i + 1 < argc) c.config_file = argv[++i];
        else if (a.rfind("--config=", 0) == 0) c.config_file = a.substr(9);
    }
    load_config_file(c, c.config_file);
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help") { usage(argv[0]); exit(0); }
        if (a == "--once") { once = true; continue; }
        if (a == "--no-reboot") { c.no_reboot = true; continue; }
        if (a == "--no-mailbox") { c.no_mailbox = true; continue; }
        if (a.rfind("--", 0) != 0) { usage(argv[0]); exit(2); }
        std::string k, v;
        size_t eq = a.find('=');
        if (eq != std::string::npos) { k = a.substr(2, eq - 2); v = a.substr(eq + 1); }
        else { k = a.substr(2); if (i + 1 < argc) v = argv[++i]; }
        for (auto& ch : k) if (ch == '-') ch = '_';
        if (k == "config") continue;
        if (k == "ping_timeout") k = "ping_timeout_ms";
        if (!apply_kv(c, k, v)) { fprintf(stderr, "opción desconocida: %s\n", a.c_str()); usage(argv[0]); exit(2); }
    }
    resolve_id(c);
    if (c.ping_target.empty()) c.ping_target = c.server;
    if (c.ping_port <= 0) c.ping_port = c.port;
    if (c.interval < 1) c.interval = 1;
    return c;
}

// ------------------------------------------------------------------ mailbox VideoCore
// Interfaz de propiedades del firmware (misma que usa vcgencmd).
// Docs: https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface
#define MBOX_IOCTL_PROPERTY _IOWR(100, 0, char*)
static const uint32_t TAG_GET_CLOCK_RATE = 0x00030002;
static const uint32_t TAG_GET_VOLTAGE    = 0x00030003;
static const uint32_t TAG_GET_TEMPERATURE = 0x00030006;
static const uint32_t TAG_GET_THROTTLED  = 0x00030046;

class Mailbox {
public:
    Mailbox() {
        fd_ = ::open("/dev/vcio", O_RDWR | O_CLOEXEC);
        if (fd_ < 0) fd_ = ::open("/dev/vcio", O_RDONLY | O_CLOEXEC);
    }
    ~Mailbox() { if (fd_ >= 0) ::close(fd_); }
    bool ok() const { return fd_ >= 0; }
    // vals: palabras de entrada/salida del tag (se sobreescriben con la respuesta)
    bool query(uint32_t tag, uint32_t* vals, int nwords) {
        if (fd_ < 0) return false;
        alignas(16) uint32_t buf[32] = {0};
        int i = 0;
        buf[i++] = 0;            // tamaño total (se completa abajo)
        buf[i++] = 0;            // request
        buf[i++] = tag;
        buf[i++] = nwords * 4;   // tamaño del buffer de valores
        buf[i++] = 0;            // request/response size
        for (int k = 0; k < nwords; k++) buf[i++] = vals[k];
        buf[i++] = 0;            // end tag
        buf[0] = i * 4;
        if (ioctl(fd_, MBOX_IOCTL_PROPERTY, buf) < 0) return false;
        if (buf[1] != 0x80000000u) return false;
        for (int k = 0; k < nwords; k++) vals[k] = buf[5 + k];
        return true;
    }
private:
    int fd_ = -1;
};

// ------------------------------------------------------------------ sensores
struct Metrics {
    double temp_c = NAN;
    double volt_core = NAN, volt_sdram_c = NAN, volt_sdram_p = NAN, volt_sdram_i = NAN;
    bool throttled_ok = false;
    uint32_t throttled = 0;
    double cpu_pct = NAN, cpu_mhz = NAN, load1 = NAN;
    double mem_total_mb = NAN, mem_used_mb = NAN, mem_pct = NAN;
    double lat_ms = NAN;         // NAN = sin respuesta / no medible
    std::string lat_method;      // icmp | tcp | none
    double uptime_s = NAN;
    std::string source;          // mailbox | vcgencmd | sysfs
};

class Sensors {
public:
    explicit Sensors(const Config& cfg) : cfg_(cfg) {
        use_mbox_ = !cfg.no_mailbox && mbox_.ok();
        if (!cfg.no_mailbox && !mbox_.ok())
            LOGW("/dev/vcio no disponible (%s): voltajes/throttling por vcgencmd o sysfs", strerror(errno));
        vcgencmd_ok_ = !run_cmd("vcgencmd version").empty();
        if (!use_mbox_ && !vcgencmd_ok_)
            LOGW("sin mailbox ni vcgencmd: voltajes no disponibles, temperatura por sysfs");
        hwmon_volt_ = find_hwmon("rpi_volt");
        sample_cpu();  // primera muestra para tener delta en la próxima
    }

    Metrics sample() {
        Metrics m;
        m.source = use_mbox_ ? "mailbox" : (vcgencmd_ok_ ? "vcgencmd" : "sysfs");
        m.temp_c = read_temp();
        m.volt_core = read_volt(1, "core");
        m.volt_sdram_c = read_volt(2, "sdram_c");
        m.volt_sdram_p = read_volt(3, "sdram_p");
        m.volt_sdram_i = read_volt(4, "sdram_i");
        m.throttled_ok = read_throttled(m.throttled);
        m.cpu_mhz = read_cpu_mhz();
        m.cpu_pct = sample_cpu();
        read_mem(m);
        m.uptime_s = atof(read_file("/proc/uptime").c_str());
        {
            std::string la = read_file("/proc/loadavg");
            if (!la.empty()) m.load1 = atof(la.c_str());
        }
        measure_latency(m);
        return m;
    }

private:
    const Config& cfg_;
    Mailbox mbox_;
    bool use_mbox_ = false;
    bool vcgencmd_ok_ = false;
    std::string hwmon_volt_;
    unsigned long long prev_busy_ = 0, prev_total_ = 0;
    bool have_prev_ = false;
    uint16_t icmp_seq_ = 0;

    static std::string find_hwmon(const std::string& name) {
        for (int i = 0; i < 16; i++) {
            std::string base = "/sys/class/hwmon/hwmon" + std::to_string(i);
            std::string n = trim(read_file(base + "/name"));
            if (n.empty()) continue;
            if (n == name) return base;
        }
        return "";
    }

    double read_temp() {
        if (use_mbox_) {
            uint32_t v[2] = {0, 0};
            if (mbox_.query(TAG_GET_TEMPERATURE, v, 2)) return v[1] / 1000.0;
        }
        std::string s = read_file("/sys/class/thermal/thermal_zone0/temp");
        if (!s.empty()) return atof(s.c_str()) / 1000.0;
        if (vcgencmd_ok_) {
            std::string o = run_cmd("vcgencmd measure_temp");  // temp=45.0'C
            size_t p = o.find('=');
            if (p != std::string::npos) return atof(o.c_str() + p + 1);
        }
        return NAN;
    }

    double read_volt(int id, const char* name) {
        if (use_mbox_) {
            uint32_t v[2] = {(uint32_t)id, 0};
            if (mbox_.query(TAG_GET_VOLTAGE, v, 2)) return v[1] / 1e6;
        }
        if (vcgencmd_ok_) {
            std::string o = run_cmd(std::string("vcgencmd measure_volts ") + name);  // volt=0.8500V
            size_t p = o.find('=');
            if (p != std::string::npos) return atof(o.c_str() + p + 1);
        }
        return NAN;
    }

    bool read_throttled(uint32_t& out) {
        if (use_mbox_) {
            uint32_t v[1] = {0};  // 0 = no limpiar los bits "sticky"
            if (mbox_.query(TAG_GET_THROTTLED, v, 1)) { out = v[0]; return true; }
        }
        std::string s = trim(read_file("/sys/devices/platform/soc/soc:firmware/get_throttled"));
        if (!s.empty()) { out = (uint32_t)strtoul(s.c_str(), nullptr, 16); return true; }
        if (vcgencmd_ok_) {
            std::string o = run_cmd("vcgencmd get_throttled");  // throttled=0x50000
            size_t p = o.find('=');
            if (p != std::string::npos) { out = (uint32_t)strtoul(o.c_str() + p + 1, nullptr, 16); return true; }
        }
        if (!hwmon_volt_.empty()) {
            // Kernel mainline: solo indica subvoltaje actual.
            std::string a = trim(read_file(hwmon_volt_ + "/in0_lcrit_alarm"));
            if (!a.empty()) { out = (a == "1") ? 0x1 : 0x0; return true; }
        }
        return false;
    }

    double read_cpu_mhz() {
        if (use_mbox_) {
            uint32_t v[2] = {3 /* ARM */, 0};
            if (mbox_.query(TAG_GET_CLOCK_RATE, v, 2) && v[1] > 0) return v[1] / 1e6;
        }
        std::string s = read_file("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq");
        if (!s.empty()) return atof(s.c_str()) / 1000.0;
        return NAN;
    }

    // Uso de CPU global desde /proc/stat (delta entre muestras).
    double sample_cpu() {
        std::ifstream f("/proc/stat");
        std::string cpu;
        unsigned long long user = 0, nice = 0, sys = 0, idle = 0, iow = 0, irq = 0, sirq = 0, steal = 0;
        if (!(f >> cpu >> user >> nice >> sys >> idle >> iow >> irq >> sirq >> steal)) return NAN;
        unsigned long long idle_all = idle + iow;
        unsigned long long total = user + nice + sys + idle_all + irq + sirq + steal;
        unsigned long long busy = total - idle_all;
        double pct = NAN;
        if (have_prev_ && total > prev_total_) {
            pct = 100.0 * (double)(busy - prev_busy_) / (double)(total - prev_total_);
            if (pct < 0) pct = 0;
            if (pct > 100) pct = 100;
        }
        prev_busy_ = busy;
        prev_total_ = total;
        have_prev_ = true;
        return pct;
    }

    static void read_mem(Metrics& m) {
        std::ifstream f("/proc/meminfo");
        std::string key;
        unsigned long long val = 0, total = 0, avail = 0, freem = 0, buffers = 0, cached = 0;
        bool have_avail = false;
        std::string unit;
        while (f >> key >> val) {
            std::getline(f, unit);
            if (key == "MemTotal:") total = val;
            else if (key == "MemAvailable:") { avail = val; have_avail = true; }
            else if (key == "MemFree:") freem = val;
            else if (key == "Buffers:") buffers = val;
            else if (key == "Cached:") cached = val;
        }
        if (total == 0) return;
        if (!have_avail) avail = freem + buffers + cached;  // kernels viejos
        m.mem_total_mb = total / 1024.0;
        m.mem_used_mb = (total - avail) / 1024.0;
        m.mem_pct = 100.0 * (double)(total - avail) / (double)total;
    }

    // ---- latencia
    static bool resolve_ipv4(const std::string& host, sockaddr_in& out) {
        struct addrinfo hints;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo* res = nullptr;
        if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) return false;
        memcpy(&out, res->ai_addr, sizeof out);
        freeaddrinfo(res);
        return true;
    }

    static uint16_t icmp_checksum(const void* data, size_t len) {
        const uint16_t* p = (const uint16_t*)data;
        uint32_t sum = 0;
        while (len > 1) { sum += *p++; len -= 2; }
        if (len) sum += *(const uint8_t*)p;
        while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
        return (uint16_t)~sum;
    }

    // Devuelve ms; -1 sin respuesta; -2 ICMP no disponible (permisos).
    double icmp_ping(sockaddr_in addr, int timeout_ms) {
        bool raw = false;
        int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, IPPROTO_ICMP);
        if (fd < 0) { fd = socket(AF_INET, SOCK_RAW | SOCK_CLOEXEC, IPPROTO_ICMP); raw = true; }
        if (fd < 0) return -2;
        struct Pkt { uint8_t type, code; uint16_t cksum, id, seq; uint8_t data[24]; } pkt;
        memset(&pkt, 0, sizeof pkt);
        uint16_t seq = ++icmp_seq_;
        pkt.type = 8;
        pkt.id = htons((uint16_t)(getpid() & 0xffff));
        pkt.seq = htons(seq);
        memset(pkt.data, 0x42, sizeof pkt.data);
        pkt.cksum = icmp_checksum(&pkt, sizeof pkt);
        addr.sin_port = 0;
        double t0 = now_hr_ms();
        if (sendto(fd, &pkt, sizeof pkt, 0, (sockaddr*)&addr, sizeof addr) < 0) { close(fd); return -1; }
        double result = -1;
        for (;;) {
            int remaining = timeout_ms - (int)(now_hr_ms() - t0);
            if (remaining <= 0) break;
            pollfd p{fd, POLLIN, 0};
            int r = poll(&p, 1, remaining);
            if (r <= 0) { if (r < 0 && errno == EINTR) continue; break; }
            uint8_t buf[512];
            sockaddr_in from;
            socklen_t fl = sizeof from;
            ssize_t n = recvfrom(fd, buf, sizeof buf, 0, (sockaddr*)&from, &fl);
            if (n <= 0) continue;
            size_t off = raw ? (size_t)((buf[0] & 0x0f) * 4) : 0;
            if ((size_t)n < off + 8) continue;
            const Pkt* rp = (const Pkt*)(buf + off);
            if (rp->type != 0) continue;
            if (ntohs(rp->seq) != seq) continue;
            if (raw && rp->id != pkt.id) continue;  // con SOCK_DGRAM el kernel reescribe el id
            result = now_hr_ms() - t0;
            break;
        }
        close(fd);
        return result;
    }

    // Tiempo de conexión TCP (handshake). Un RST (ECONNREFUSED) también cuenta como respuesta.
    static double tcp_ping(sockaddr_in addr, int port, int timeout_ms) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0) return -1;
        addr.sin_port = htons((uint16_t)port);
        double t0 = now_hr_ms();
        int rc = connect(fd, (sockaddr*)&addr, sizeof addr);
        double result = -1;
        if (rc == 0) result = now_hr_ms() - t0;
        else if (errno == EINPROGRESS) {
            pollfd p{fd, POLLOUT, 0};
            int r;
            do { r = poll(&p, 1, timeout_ms); } while (r < 0 && errno == EINTR);
            if (r > 0) {
                int err = 0;
                socklen_t el = sizeof err;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                if (err == 0 || err == ECONNREFUSED) result = now_hr_ms() - t0;
            }
        } else if (errno == ECONNREFUSED) result = now_hr_ms() - t0;
        close(fd);
        return result;
    }

    void measure_latency(Metrics& m) {
        sockaddr_in addr;
        if (!resolve_ipv4(cfg_.ping_target, addr)) { m.lat_method = "none"; return; }
        double r = icmp_ping(addr, cfg_.ping_timeout_ms);
        if (r == -2) {
            r = tcp_ping(addr, cfg_.ping_port, cfg_.ping_timeout_ms);
            m.lat_method = "tcp";
        } else {
            m.lat_method = "icmp";
        }
        m.lat_ms = (r >= 0) ? r : NAN;
    }
};

// ------------------------------------------------------------------ interfaces de red
struct IfaceInfo { std::string name, ip, mac; };

static std::string mac_from_sysfs(const std::string& name) {
    std::string m = trim(read_file("/sys/class/net/" + name + "/address"));
    return (m.size() == 17) ? m : "";
}

// IPv4 de todas las interfaces activas (sin loopback), con su MAC.
static std::vector<IfaceInfo> list_ifaces() {
    std::vector<IfaceInfo> out;
    struct ifaddrs* head = nullptr;
    if (getifaddrs(&head) != 0) return out;
    for (auto* p = head; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((sockaddr_in*)p->ifa_addr)->sin_addr, buf, sizeof buf);
        out.push_back({p->ifa_name ? p->ifa_name : "", buf, ""});
    }
    for (auto* p = head; p; p = p->ifa_next) {  // MAC por AF_PACKET
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_PACKET || !p->ifa_name) continue;
        auto* ll = (struct sockaddr_ll*)p->ifa_addr;
        if (ll->sll_halen != 6) continue;
        char mac[18];
        snprintf(mac, sizeof mac, "%02x:%02x:%02x:%02x:%02x:%02x",
                 ll->sll_addr[0], ll->sll_addr[1], ll->sll_addr[2], ll->sll_addr[3], ll->sll_addr[4], ll->sll_addr[5]);
        for (auto& e : out) if (e.name == p->ifa_name) e.mac = mac;
    }
    freeifaddrs(head);
    for (auto& e : out) if (e.mac.empty()) e.mac = mac_from_sysfs(e.name);  // fallback sysfs
    return out;
}

// IP local con la que el equipo llega al servidor (la del socket ya conectado).
static std::string local_ip_of(int fd) {
    sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    if (getsockname(fd, (sockaddr*)&ss, &sl) != 0) return "";
    char buf[INET6_ADDRSTRLEN] = {0};
    if (ss.ss_family == AF_INET) inet_ntop(AF_INET, &((sockaddr_in*)&ss)->sin_addr, buf, sizeof buf);
    else if (ss.ss_family == AF_INET6) {
        auto* a6 = &((sockaddr_in6*)&ss)->sin6_addr;
        if (IN6_IS_ADDR_V4MAPPED(a6)) inet_ntop(AF_INET, ((const uint8_t*)a6) + 12, buf, sizeof buf);
        else inet_ntop(AF_INET6, a6, buf, sizeof buf);
    }
    return buf;
}

// Datos de red reportados al servidor; se refrescan en cada (re)conexión.
struct NetInfo {
    std::string ip, mac, iface;
    std::vector<IfaceInfo> ifaces;

    void refresh(int fd) {
        ifaces = list_ifaces();
        ip = local_ip_of(fd);
        mac.clear();
        iface.clear();
        for (const auto& e : ifaces) if (e.ip == ip) { mac = e.mac; iface = e.name; break; }
        if (ip.empty() && !ifaces.empty()) { ip = ifaces[0].ip; mac = ifaces[0].mac; iface = ifaces[0].name; }
        if (mac.empty()) for (const auto& e : ifaces) if (!e.mac.empty()) { mac = e.mac; break; }
    }

    std::string json() const {
        std::string s = "\"ip\":" + (ip.empty() ? "null" : jstr(ip)) +
                        ",\"mac\":" + (mac.empty() ? "null" : jstr(mac)) +
                        ",\"iface\":" + (iface.empty() ? "null" : jstr(iface)) + ",\"ifaces\":[";
        for (size_t i = 0; i < ifaces.size(); i++) {
            if (i) s += ",";
            s += "{\"name\":" + jstr(ifaces[i].name) + ",\"ip\":" + jstr(ifaces[i].ip) +
                 ",\"mac\":" + (ifaces[i].mac.empty() ? "null" : jstr(ifaces[i].mac)) + "}";
        }
        return s + "]";
    }
};
static NetInfo g_net;

// ------------------------------------------------------------------ JSON de salida
static std::string sys_info_json() {
    struct utsname u;
    std::string kernel, arch;
    if (uname(&u) == 0) { kernel = u.release; arch = u.machine; }
    std::string model = read_file("/proc/device-tree/model");
    if (!model.empty() && model.back() == '\0') model.pop_back();
    return ",\"kernel\":" + jstr(kernel) + ",\"arch\":" + jstr(arch) + ",\"model\":" + jstr(model);
}

static std::string hello_json(const Config& cfg) {
    char h[256] = {0};
    gethostname(h, sizeof h - 1);
    std::string s = "{\"type\":\"hello\"," + g_net.json() + ",\"id\":" + jstr(cfg.id) + ",\"host\":" + jstr(h) +
                    ",\"token\":" + jstr(cfg.token) + ",\"version\":" + jstr(RPIMON_VERSION) +
                    ",\"interval\":" + std::to_string(cfg.interval) +
                    ",\"banca\":" + (cfg.banca.empty() ? "null" : jstr(cfg.banca)) + sys_info_json() + "}\n";
    return s;
}

static std::string metrics_json(const Config& cfg, const Metrics& m) {
    char thr[16];
    snprintf(thr, sizeof thr, "0x%x", m.throttled);
    std::string s = "{\"type\":\"metrics\",\"id\":" + jstr(cfg.id) +
        ",\"ip\":" + (g_net.ip.empty() ? "null" : jstr(g_net.ip)) +
        ",\"ts\":" + std::to_string(epoch_ms()) +
        ",\"temp_c\":" + jnum(m.temp_c, 1) +
        ",\"volt_core\":" + jnum(m.volt_core, 4) +
        ",\"volt_sdram_c\":" + jnum(m.volt_sdram_c, 4) +
        ",\"volt_sdram_p\":" + jnum(m.volt_sdram_p, 4) +
        ",\"volt_sdram_i\":" + jnum(m.volt_sdram_i, 4) +
        ",\"throttled\":" + (m.throttled_ok ? jstr(thr) : "null") +
        ",\"throttled_raw\":" + (m.throttled_ok ? std::to_string(m.throttled) : "null") +
        ",\"cpu_pct\":" + jnum(m.cpu_pct, 1) +
        ",\"cpu_mhz\":" + jnum(m.cpu_mhz, 0) +
        ",\"load1\":" + jnum(m.load1, 2) +
        ",\"mem_total_mb\":" + jnum(m.mem_total_mb, 0) +
        ",\"mem_used_mb\":" + jnum(m.mem_used_mb, 0) +
        ",\"mem_pct\":" + jnum(m.mem_pct, 1) +
        ",\"lat_ms\":" + jnum(m.lat_ms, 2) +
        ",\"lat_target\":" + jstr(cfg.ping_target) +
        ",\"lat_method\":" + jstr(m.lat_method) +
        ",\"uptime_s\":" + jnum(m.uptime_s, 0) +
        ",\"source\":" + jstr(m.source) + "}\n";
    return s;
}

// ------------------------------------------------------------------ red
static int connect_timeout(const std::string& host, int port, int timeout_ms) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* res = nullptr;
    int rc = getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res);
    if (rc != 0) { LOGE("no se resuelve %s: %s", host.c_str(), gai_strerror(rc)); return -1; }
    int fd = -1;
    for (auto* ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC | SOCK_NONBLOCK, ai->ai_protocol);
        if (fd < 0) continue;
        int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (r < 0 && errno == EINPROGRESS) {
            pollfd p{fd, POLLOUT, 0};
            do { r = poll(&p, 1, timeout_ms); } while (r < 0 && errno == EINTR);
            if (r > 0) {
                int err = 0;
                socklen_t el = sizeof err;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                r = (err == 0) ? 0 : -1;
                if (err) errno = err;
            } else { if (r == 0) errno = ETIMEDOUT; r = -1; }
        }
        if (r == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef TCP_KEEPIDLE
        int idle = 15, intvl = 5, cnt = 3;
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
#endif
    }
    return fd;
}

static bool send_all(int fd, const std::string& s) {
    size_t off = 0;
    while (off < s.size()) {
        ssize_t n = send(fd, s.data() + off, s.size() - off, MSG_NOSIGNAL);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            pollfd p{fd, POLLOUT, 0};
            if (poll(&p, 1, 5000) <= 0) return false;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        return false;
    }
    return true;
}

// ------------------------------------------------------------------ reinicio
static void do_reboot(const Config& cfg) {
    if (cfg.no_reboot) { LOGW("--no-reboot: se omite el reinicio real"); return; }
    LOGW("reiniciando el equipo por pedido del servidor");
    sync();
    if (!cfg.reboot_cmd.empty()) {
        int rc = system(cfg.reboot_cmd.c_str());
        if (rc == 0) return;
        LOGE("reboot_cmd '%s' devolvió %d", cfg.reboot_cmd.c_str(), rc);
    } else {
        const char* cmds[] = {"/sbin/reboot", "/bin/reboot", "reboot", "systemctl reboot", "busybox reboot"};
        for (const char* c : cmds) {
            int rc = system(c);
            if (rc == 0) return;
        }
        LOGE("ningún comando de reboot funcionó; usando syscall reboot()");
    }
    sync();
    sleep(1);
    reboot(RB_AUTOBOOT);
    LOGE("reboot() falló: %s", strerror(errno));
}

// ------------------------------------------------------------------ main loop
// Devuelve false si hay que reconectar.
static bool handle_line(int fd, const std::string& line, const Config& cfg, Sensors& sensors) {
    std::string type = json_get(line, "type");
    if (type == "ping") {
        std::string t = json_get(line, "t");
        return send_all(fd, "{\"type\":\"pong\",\"t\":" + (t.empty() ? "0" : t) + "}\n");
    }
    if (type == "cmd") {
        std::string cmd = json_get(line, "cmd"), req = json_get(line, "req");
        LOGI("comando recibido: %s (req %s)", cmd.c_str(), req.c_str());
        if (cmd == "reboot") {
            send_all(fd, "{\"type\":\"ack\",\"req\":" + jstr(req) + ",\"cmd\":\"reboot\",\"ok\":true}\n");
            usleep(300 * 1000);  // dejar salir el ack
            do_reboot(cfg);
            return true;
        }
        if (cmd == "sample") {
            Metrics m = sensors.sample();
            send_all(fd, "{\"type\":\"ack\",\"req\":" + jstr(req) + ",\"cmd\":\"sample\",\"ok\":true}\n");
            return send_all(fd, metrics_json(cfg, m));
        }
        return send_all(fd, "{\"type\":\"ack\",\"req\":" + jstr(req) + ",\"cmd\":" + jstr(cmd) +
                            ",\"ok\":false,\"error\":\"comando desconocido\"}\n");
    }
    if (type == "error") { LOGE("servidor: %s", json_get(line, "error").c_str()); return false; }
    if (type == "hello_ack") { LOGI("registrado en el servidor como '%s'", cfg.id.c_str()); return true; }
    return true;
}

int main(int argc, char** argv) {
    bool once = false;
    Config cfg = parse_args(argc, argv, once);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    Sensors sensors(cfg);
    if (once) {
        g_net.refresh(-1);
        sleep(1);  // para tener delta de CPU
        Metrics m = sensors.sample();
        fputs(metrics_json(cfg, m).c_str(), stdout);
        return 0;
    }

    LOGI("rpimon %s id=%s servidor=%s:%d intervalo=%ds latencia->%s",
         RPIMON_VERSION, cfg.id.c_str(), cfg.server.c_str(), cfg.port, cfg.interval, cfg.ping_target.c_str());

    int backoff = 1;
    while (!g_stop) {
        int fd = connect_timeout(cfg.server, cfg.port, 5000);
        if (fd < 0) {
            LOGW("no se pudo conectar a %s:%d (%s); reintento en %ds", cfg.server.c_str(), cfg.port, strerror(errno), backoff);
            for (int i = 0; i < backoff && !g_stop; i++) sleep(1);
            backoff = std::min(backoff * 2, 30);
            continue;
        }
        backoff = 1;
        g_net.refresh(fd);
        LOGI("conectado a %s:%d desde %s%s%s", cfg.server.c_str(), cfg.port,
             g_net.ip.empty() ? "?" : g_net.ip.c_str(),
             g_net.iface.empty() ? "" : (" por " + g_net.iface).c_str(),
             g_net.mac.empty() ? "" : (" (" + g_net.mac + ")").c_str());
        if (!send_all(fd, hello_json(cfg))) { close(fd); continue; }

        std::string inbuf;
        int64_t next = now_ms();
        bool alive = true;
        while (!g_stop && alive) {
            int64_t wait = next - now_ms();
            if (wait < 0) wait = 0;
            pollfd p{fd, POLLIN, 0};
            int r = poll(&p, 1, (int)wait);
            if (r < 0) { if (errno == EINTR) continue; break; }
            if (r > 0) {
                if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) { LOGW("conexión cerrada"); break; }
                char b[4096];
                ssize_t n = recv(fd, b, sizeof b, 0);
                if (n == 0) { LOGW("el servidor cerró la conexión"); break; }
                if (n < 0) { if (errno == EAGAIN || errno == EINTR) continue; LOGW("recv: %s", strerror(errno)); break; }
                inbuf.append(b, (size_t)n);
                if (inbuf.size() > 65536) { LOGW("buffer de entrada excedido"); break; }
                size_t pos;
                while ((pos = inbuf.find('\n')) != std::string::npos) {
                    std::string line = trim(inbuf.substr(0, pos));
                    inbuf.erase(0, pos + 1);
                    if (!line.empty() && !handle_line(fd, line, cfg, sensors)) { alive = false; break; }
                }
            }
            if (alive && now_ms() >= next) {
                Metrics m = sensors.sample();
                if (!send_all(fd, metrics_json(cfg, m))) { LOGW("error enviando métricas: %s", strerror(errno)); break; }
                next += (int64_t)cfg.interval * 1000;
                if (next < now_ms()) next = now_ms() + (int64_t)cfg.interval * 1000;
            }
        }
        close(fd);
        if (!g_stop) sleep(1);
    }
    LOGI("rpimon finalizado");
    return 0;
}
