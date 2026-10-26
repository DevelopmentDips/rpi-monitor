# rpi-monitor

Monitoreo en tiempo real de 53 Raspberry Pi 4 ("bancas", numeradas de la 0 a la 52) con panel web, alertas a Graylog y reinicio remoto individual.

```
 ┌───────────── Raspberry Pi (x53) ─────────────┐        ┌──────────── servidor ────────────┐
 │ rpimon (C++, estático, sin dependencias)      │  TCP   │ rpi-monitor-server (Node.js)     │
 │  · temperatura / voltajes / throttling (vcio) │ ─────▶ │  · registro de estado + umbrales │──▶ Graylog (GELF udp/tcp)
 │  · CPU, memoria, uptime, latencia (ICMP/TCP)  │ ◀───── │  · WebSocket → panel de 53 bancas│
 │  · recibe {"cmd":"reboot"} y reinicia         │  cmd   │  · POST /api/devices/:id/reboot  │◀── navegador (panel)
 └───────────────────────────────────────────────┘        └──────────────────────────────────┘
```

* **agent/**: agente `rpimon` en C++17. Un solo archivo, sin librerías externas, se compila estático para que corra en cualquier Linux ARM (glibc o musl, systemd o BusyBox).
* **server/**: servidor Node.js (≥18, única dependencia `ws`). Sirve el panel, recibe agentes, evalúa umbrales, loguea a Graylog y reenvía el comando de reinicio.
* **deploy/**: script para instalar/actualizar el agente en todas las bancas por SSH.

## 1. Agente (Raspberry Pi)

### Qué mide y de dónde

| Dato | Fuente principal | Fallbacks |
|---|---|---|
| Temperatura SoC | mailbox VideoCore `/dev/vcio` | `/sys/class/thermal/thermal_zone0/temp`, `vcgencmd measure_temp` |
| Voltajes core / sdram_c / sdram_p / sdram_i | mailbox `/dev/vcio` | `vcgencmd measure_volts` |
| Subvoltaje y throttling (`get_throttled`) | mailbox `/dev/vcio` | `/sys/devices/platform/soc/soc:firmware/get_throttled`, `vcgencmd get_throttled`, hwmon `rpi_volt` |
| Frecuencia ARM | mailbox | `cpufreq/scaling_cur_freq` |
| CPU % | `/proc/stat` (delta entre muestras) | |
| Memoria | `/proc/meminfo` (MemTotal − MemAvailable) | |
| Uptime / load | `/proc/uptime`, `/proc/loadavg` | |
| IP, MAC e interfaces | `getsockname()` de la conexión + `getifaddrs()` | MAC por `/sys/class/net/<if>/address` |
| Latencia | ICMP echo (socket `SOCK_DGRAM` o raw) hacia `ping_target` | tiempo de handshake TCP hacia `ping_target:ping_port` |

El mailbox es la misma interfaz que usa `vcgencmd`, por lo que **no hace falta tener `vcgencmd` ni las libs de Broadcom** en el SO custom; alcanza con que exista `/dev/vcio` (driver `vcio`/`bcm2835-vcio`, presente en los kernels de Raspberry Pi y en mainline desde 5.x). Si no existe, se usan los fallbacks y el panel mostrará "sin dato" en voltaje.

El voltaje de 5 V de la fuente no es legible directamente; el firmware lo reporta como bit de **subvoltaje** en `get_throttled`, que el panel muestra en la casilla "5V".

### Compilar

En la propia RPi (o cualquier Linux ARM con g++):

```bash
cd agent && make STATIC=1
```

Cross-compile desde una PC con Docker (usa qemu/binfmt, que Docker Desktop trae incluido). Compila en Alpine contra musl, así el binario (~1,2 MB) es 100 % estático y corre en cualquier Linux ARM sin importar la libc del SO custom:

```bash
cd agent && make docker-arm64     # kernel de 64 bits  → rpimon-arm64
cd agent && make docker-armv7     # kernel de 32 bits  → rpimon-armv7
```

Si se compila estático contra **glibc** (`make docker-arm64-glibc` o `make STATIC=1` en una distro glibc), la resolución de nombres necesita las libs NSS en la RPi; usando la IP del servidor en `server` no hay problema.

Con un toolchain cruzado instalado: `make CXX=aarch64-linux-gnu-g++ STATIC=1`.

Para saber si el SO custom es de 32 o 64 bits: `uname -m` (`aarch64` → arm64, `armv7l` → armv7).

### Instalar en una banca

```bash
install -m 755 rpimon-arm64 /usr/local/bin/rpimon
install -m 600 rpimon.conf.example /etc/rpimon.conf   # editar server, token, id
# systemd:
install -m 644 rpimon.service /etc/systemd/system/ && systemctl enable --now rpimon
# BusyBox / SysV:
install -m 755 rpimon.init /etc/init.d/S99rpimon && /etc/init.d/S99rpimon start
```

Probar sin instalar (imprime una muestra JSON y sale):

```bash
./rpimon --once --server 10.0.0.1
```

### Configuración (`/etc/rpimon.conf` o flags `--clave valor`)

| Clave | Default | Descripción |
|---|---|---|
| `server`, `port` | 127.0.0.1, 7070 | servidor rpi-monitor |
| `token` | | debe coincidir con `agents.token` del servidor |
| `id` | ver abajo | identificador de la banca; debe coincidir con un id de `stations` para ocupar su lugar en el panel |
| `id_file`, `id_key` | `/var/local/settings.ini`, `idBanca` | archivo INI y clave de donde se lee el número de banca |
| `id_prefix`, `id_pad` | `banca-`, 2 | el id se arma como `prefix + número con ceros` (idBanca `"49"` → `banca-49`) |
| `interval` | 5 | segundos entre reportes |
| `ping_target`, `ping_port` | server, port | host contra el que se mide latencia |
| `ping_timeout_ms` | 1000 | |
| `reboot_cmd` | | comando de reinicio; si se omite prueba `/sbin/reboot`, `reboot`, `systemctl reboot` y por último la syscall `reboot()` |
| `no_reboot` | 0 | modo prueba: no reinicia de verdad |
| `no_mailbox` | 0 | no usar `/dev/vcio` |

### IP y MAC

El agente reporta él mismo su dirección: la IP con la que llega al servidor (la del socket local, así elige la interfaz correcta cuando hay eth0 y wlan0), su MAC, el nombre de la interfaz y la lista completa de interfaces IPv4 activas. Va en el `hello` y la IP se repite en cada muestra de métricas, así que se actualiza sola si cambia por DHCP tras una reconexión.

El servidor prefiere siempre la IP reportada por la banca sobre la del socket, y guarda esta última como `peerIp`. Si difieren (NAT, proxy o túnel) el panel muestra ambas en el tooltip de la tarjeta. El buscador del panel filtra por IP y por MAC además de por nombre.

### Identificación de la banca

Orden de resolución del id: `--id` / `id` en el conf → número leído de `id_file` (`idBanca = "49"` en `/var/local/settings.ini` → `banca-49`) → hostname. El número crudo también viaja en el `hello` (campo `banca`) y se ve en el tooltip de la tarjeta. Con `stationsAuto` por defecto (`banca-` + 2 dígitos) cada equipo ocupa su lugar en el panel sin configuración adicional.

### Permisos

Lo más simple es correrlo como root (necesita `/dev/vcio`, ICMP y `reboot`). Si se quiere otro usuario:

* agregarlo al grupo dueño de `/dev/vcio` (normalmente `video`);
* `setcap cap_net_raw,cap_sys_boot+ep /usr/local/bin/rpimon` (en binarios estáticos funciona igual);
* o habilitar ICMP sin privilegios: `sysctl -w net.ipv4.ping_group_range="0 65535"`. Sin ICMP el agente mide latencia con handshake TCP automáticamente.

### Despliegue masivo

`deploy/deploy-bancas.sh` instala en todo el rango de IPs de una pasada: detecta la arquitectura de cada equipo y le manda el binario que corresponde, copia tu `agent/rpimon.conf` tal cual, registra el servicio en el init que use el sistema (systemd o SysV/BusyBox) y lo deja corriendo. Los archivos viajan por `ssh cat` en vez de `scp`, así que funciona también en equipos con dropbear o sin `scp`.

```bash
./deploy/deploy-bancas.sh --dry-run          # ver el plan sin tocar nada
./deploy/deploy-bancas.sh --only 10.0.0.20   # probar en una banca primero
./deploy/deploy-bancas.sh                    # instalar en 10.0.0.20 … 10.0.0.72
./deploy/deploy-bancas.sh --action status    # ¿está corriendo el agente en cada banca?
./deploy/deploy-bancas.sh --action restart   # reiniciar el agente en todas
```

Opciones: `--range 20-72`, `--base 10.0.0`, `--only IP` (repetible), `--user`, `--port`, `--conf`, `--jobs N` (paralelismo, default 8), `--force`.
Para claves SSH o un host de salto: `SSH_EXTRA="-i ~/.ssh/bancas" ./deploy/deploy-bancas.sh`.

Antes de instalar valida que el conf no tenga los valores de ejemplo, para no dejar 53 equipos apuntando a un token inválido. Al final imprime un resumen por equipo con el id de banca detectado, el pid, si hay `/dev/vcio` y **cómo quedó registrado el arranque**, y deja un log por equipo en `/tmp/rpimon-deploy-<fecha>/`. Volver a correrlo actualiza el binario sin romper el agente que ya está corriendo.

#### Supervisión: que arranque sí o sí, y que se reviva solo

Si el `rc` de la imagen no ejecuta el servicio (o si querés que además se reponga cuando el agente se muere), hay dos mecanismos que no dependen de `rc`:

```bash
./deploy/deploy-bancas.sh --supervise inittab   # recomendado
./deploy/deploy-bancas.sh --supervise cron
```

**`inittab`** agrega a `/etc/inittab` la línea `rp:2345:respawn:/etc/init.d/rpimon runforeground` y recarga init con `telinit q`. A partir de ahí es **init quien arranca y supervisa** el agente, sin pasar por `rc`: si el proceso muere, lo vuelve a levantar. El agente corre en primer plano (`runforeground` usa `exec`, así que el PID del pidfile es el del agente y init lo rastrea bien). Como init ya se encarga, el enlace de arranque en `rc?.d` se elimina para no duplicar el proceso; los `K01rpimon` de apagado se mantienen. Se guarda una copia previa en `/etc/inittab.rpimon.bak`.

**`cron`** agrega `*/2 * * * * /etc/init.d/rpimon start` al crontab de root (respetando lo que ya hubiera) o, si no hay `crontab`, un archivo en `/etc/cron.d`. Como `start` es idempotente —si ya está corriendo no hace nada—, la misma entrada sirve para arrancarlo después del boot y como watchdog. Requiere que el demonio de cron esté activo, y el arranque puede demorar hasta 2 minutos.

Para volver al comportamiento normal: `--supervise none` (el default).

#### Que el agente vuelva solo después de un reboot

Instalar el script de init no alcanza: hay que registrarlo en el mecanismo de arranque que use el sistema, y eso cambia entre distribuciones. El despliegue prueba en orden:

1. **systemd** — `systemctl enable rpimon`, verificado con `is-enabled`.
2. **SysV clásico con `rc?.d`** (Debian, Raspbian, Yocto/OpenEmbedded) — un único enlace `S<NN>rpimon` en el runlevel de arranque (el `id:N:initdefault:` del `inittab`), más `K01rpimon` en `rc0.d`, `rc1.d` y `rc6.d`.

   **Un solo runlevel, a propósito.** El `/etc/init.d/rc` de Debian y Yocto trae esta optimización:

   ```sh
   previous_start=/etc/rc$previous.d/S[0-9][0-9]$suffix
   [ -f $previous_start ] && [ ! -f $stop ] && continue
   ```

   Si el servicio ya tenía enlace de arranque en el runlevel **anterior**, `rc` asume que sigue corriendo y **no lo ejecuta**. Con enlaces en varios runlevels, un equipo que transiciona (por ejemplo 3 → 5 durante el arranque) nunca ejecuta el script: queda perfectamente registrado y jamás corre, sin dejar ningún rastro. Por eso tampoco se usa `update-rc.d`, que reparte enlaces en 2, 3, 4 y 5.

   **La prioridad del enlace es lo que más importa** (`--priority NN`, default **10**). `rc` ejecuta los enlaces en orden alfabético, y un script que arranca su programa **en primer plano** (sin `&`, o con `exec`) bloquea todo lo que viene después: los scripts siguientes quedan perfectamente instalados y no se ejecutan nunca, sin dejar ningún rastro. Como `sshd` suele ser `S09`, el equipo sigue accesible por SSH aunque el arranque haya quedado a medias, lo que hace que el problema pase inadvertido.

   Por eso el agente se registra en `S10`, después de `sshd` y antes de los servicios de aplicación. Corriendo temprano no pierde nada: espera la red por su cuenta.

   Para detectarlo, `--action forensics` lista los scripts del runlevel indicando cuáles tienen proceso vivo; el primero sin proceso marca dónde se detuvo la secuencia. Otro síntoma delator es el reloj desfasado, porque `ntpd` tampoco llega a arrancar.

   **La traza del kernel** (`dmesg | grep rpimon`) es la prueba independiente de si el init llegó a ejecutarse: el script escribe en `/dev/kmsg` en su primera línea, que es RAM pura, no toca el disco y no depende de que `/var` esté montado.

3. **BusyBox / Buildroot** — `/etc/init.d/S99rpimon`, que es lo que su `rcS` recorre.
4. **OpenRC** — `rc-update add rpimon default`.
5. **`/etc/inittab`** con una línea `::respawn:` si no hay ninguno de los anteriores.
6. **`/etc/rc.local`** como último recurso.

> **Cuidado con `/etc/init.d/rcS`**: existe tanto en Buildroot como en Debian/Yocto, pero significa cosas distintas. En Buildroot recorre `/etc/init.d/S??*`; en Debian/Yocto hace `exec /etc/init.d/rc S`, que recorre `/etc/rcS.d/`. Por eso el orden de detección mira primero si existen los directorios `rc?.d`: en un sistema SysV clásico, un `S99rpimon` dentro de `/etc/init.d/` no lo ejecuta nadie.

El resultado sale en la columna `boot=` del resumen. Si dice `NO_REGISTRADO`, el equipo queda marcado como **AVISO**: el agente está corriendo ahora pero no va a volver solo tras un reinicio, y hay que registrarlo a mano según el init de ese sistema.

Para auditar las 53 bancas sin tocar nada:

```bash
./deploy/deploy-bancas.sh --action status
```

Y si hace falta saber exactamente qué init usa cada equipo y cuál es el comando de registro que le corresponde:

```bash
./deploy/diagnose-init.sh --only 10.0.0.20   # detalle de una banca
./deploy/diagnose-init.sh                    # tabla de las 53
./deploy/diagnose-init.sh --print            # imprime el probe para pegarlo a mano por SSH
```

Informa quién es el PID 1, si systemd está realmente activo (`/run/systemd/system`), si hay `rcS`, `rc?.d`, `rc.local`, OpenRC o `inittab`, si el agente ya está registrado, y el comando exacto para registrarlo en ese sistema.

#### Sin escrituras en disco

Las bancas tienen tarjetas o SSD con años de uso, así que **el agente no escribe nada en el almacenamiento**:

* El binario solo lee (`/proc`, `/sys`, `/dev/vcio`, `/etc/rpimon.conf`, `/var/local/settings.ini`). No genera archivos.
* El log del init va siempre a un filesystem en RAM. No se asume nada: se resuelve el symlink y se busca el tipo real del montaje en `/proc/mounts`, aceptando solo `tmpfs` o `ramfs`. Se prueba `/var/log` (en imágenes Yocto suele ser un symlink a `/var/volatile/log`, que ya es tmpfs), `/run`, `/var/volatile`, `/dev/shm` y `/tmp`. Si ninguno está en RAM, no escribe nada.
* El pidfile sigue el mismo criterio.
* El log se recorta solo al superar `LOG_MAX_KB` (256 KB por defecto), conservando las últimas 100 líneas.

El precio es que el log se pierde al reiniciar. Queda el del arranque actual, que es justo lo que sirve para ver por qué una banca no levantó. El histórico persistente vive en el servidor y en Graylog, no en la Raspberry.

Todo se ajusta en `/etc/default/rpimon`, sin tocar el script:

```sh
LOG_MODE=ram        # ram (default) | none | syslog | /una/ruta/explícita
LOG_SYSLOG=no       # además a syslog; ojo que syslogd puede estar escribiendo a disco
LOG_MAX_KB=256
FS_WAIT=20
NET_WAIT=120
```

#### Esperas y diagnóstico en el arranque

El script de init está escrito pensando en que al bootear el sistema todavía no está listo:

* **Espera a `/var`** hasta `FS_WAIT` segundos (default 20) a que el directorio del pidfile sea escribible. En imágenes con rootfs de solo lectura, los volátiles los puebla `populate-volatile.sh` más tarde.
* **Espera a la red** hasta `NET_WAIT` segundos (default 60) a que haya una IP que no sea loopback. Esa espera va en segundo plano para **no bloquear el arranque**, y el agente igual reintenta la conexión por su cuenta.
* Registra el arranque, cuánto esperó y dónde dejó el log; si el agente murió apenas lanzado, incluye las últimas líneas.
* `status` muestra la cola del log y en qué ruta está.

> Dos detalles de shell que hacían fallar el arranque en silencio y están resueltos: `:` es un *builtin especial* de POSIX, así que si su redirección falla **el shell entero termina**, y `2>/dev/null` solo oculta el mensaje — por eso las pruebas de escritura van dentro de una subshell. Y la espera en segundo plano se lanza con `>/dev/null 2>&1 </dev/null`, porque si hereda los descriptores de quien la llamó deja colgada la sesión SSH (o la consola de arranque) hasta que el agente termine.

Para traer los logs de arranque de todas las bancas y ver por qué alguna no levantó:

```bash
./deploy/deploy-bancas.sh --action logs
```

`deploy/install-agent.sh` es la variante anterior, que genera el `/etc/rpimon.conf` a partir de un `hosts.txt` con id + IP en vez de usar tu conf ya armado.

## 2. Servidor y panel

```bash
cd server
npm install
cp config.example.json config.json   # editar token, Graylog, credenciales del panel
npm start
```

Panel: `http://<servidor>:8080/` (autenticación básica según `web.auth`). Agentes: puerto TCP 7070.

Como servicio: copiar el proyecto a `/opt/rpi-monitor`, crear el usuario `rpimon`, instalar `server/rpi-monitor-server.service` en `/etc/systemd/system/` y `systemctl enable --now rpi-monitor-server`.

### Probar sin Raspberrys

```bash
npm run simulate        # 53 agentes falsos (banca 0 … 52) contra 127.0.0.1:7070 con el token del config.example
```

### `config.json`

```jsonc
{
  "agents":  { "port": 7070, "token": "…", "offlineAfterSec": 20, "pingIntervalSec": 10, "allowUnknown": true },
  "web":     { "port": 8080, "auth": { "user": "admin", "pass": "…" }, "rebootCooldownSec": 60 },
  "graylog": { "enabled": true, "host": "graylog.local", "port": 12201, "protocol": "udp", "source": "rpi-monitor", "metricsEverySec": 0 },
  "thresholds": {
    "unknownLevel": "warn",                                   // nivel cuando un sensor no devuelve dato
    "temp_c":    { "warn": 70, "crit": 80 },
    "volt_core": null,                                        // ver nota abajo
    "lat_ms":    { "warn": 100, "crit": 300 },                // sin respuesta = crítico
    "cpu_pct":   { "warn": 85, "crit": 95 },
    "mem_pct":   { "warn": 85, "crit": 95 },
    "undervoltage": { "now": "crit", "occurred": "warn" },    // bits 0 y 16 de get_throttled
    "throttling":   { "now": "warn", "occurred": "ok" }       // bits 2/3 y 18/19
  },
  "stationsAuto": { "prefix": "banca-", "start": 0, "count": 53, "pad": 2, "nameFormat": "Banca {n}" },
  "stations": [ { "id": "caja-central", "name": "Caja central" } ]   // opcional, además de las autogeneradas
}
```

`stationsAuto` genera las bancas del panel: con `start: 0` y `count: 53` van de `banca-00` ("Banca 0") a `banca-52` ("Banca 52"). El `pad` de 2 dígitos es el que hace que `idBanca = "7"` en la Raspberry se corresponda con `banca-07`.

Cada umbral admite `warn`/`crit` (valor ≥) y `warnBelow`/`critBelow` (valor ≤). El color de cada casilla del panel sale de estas reglas; el color de la tarjeta es el peor de sus métricas. Una banca pasa a "sin conexión" si se corta el TCP o no manda datos en `offlineAfterSec`.

**Sobre el voltaje core.** En una Pi 4 debería rondar 0,83–0,95 V y variar con la frecuencia (DVFS), pero hay firmwares que no implementan la consulta y devuelven un valor fijo para *todos* los rieles. Se detecta fácil: si `core`, `sdram_c`, `sdram_p` y `sdram_i` informan exactamente el mismo número, la lectura no significa nada.

```bash
vcgencmd measure_volts core; vcgencmd measure_volts sdram_c
```

Por eso el umbral viene en `null`, que muestra el valor en el panel pero nunca alarma. Ponerle límites a una constante solo genera 53 críticos falsos. **La señal real de problemas de alimentación es la casilla "5V"**, que sale del bit de subvoltaje de `get_throttled` y sí funciona en estos equipos. Si tu firmware devuelve lecturas reales, se le pueden poner límites de nuevo:

```jsonc
"volt_core": { "warnBelow": 0.82, "critBelow": 0.78, "warn": 1.0, "crit": 1.1 }
```

### Graylog

Crear un input **GELF UDP** (o GELF TCP) en Graylog en el puerto configurado. Cada evento llega con `short_message` legible y campos:

`_event` (`threshold`, `online`, `offline`, `reboot_request`, `reboot_ack`, `reboot_failed`, `server_start`, `metrics`), `_station`, `_station_name`, `_station_ip` (la que reporta la banca), `_station_mac`, `_station_peer_ip` (solo si difiere de la anterior), `_metric`, `_from`, `_to`, `_value`, `_level_name`, `_by`, `_requester_ip`, `_overall`, `_facility=rpi-monitor`.

Nivel syslog: crítico → 2, aviso → 4, vuelta a normal / info → 6. Se loguea **cada transición** (ok→aviso, aviso→crítico, crítico→ok…), conexiones/desconexiones y todo pedido de reinicio con usuario e IP de quien lo pidió. No se repite una alerta mientras el estado no cambie. Con `metricsEverySec > 0` además se envían las métricas de todas las bancas cada N segundos (nivel debug) para armar dashboards en Graylog.

### API

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/state` | estado completo (bancas, alertas recientes, umbrales) |
| GET | `/api/health` | contadores y estado de Graylog |
| GET | `/api/alerts` | últimas 500 alertas |
| POST | `/api/devices/:id/reboot` | reinicia la banca (espera ack del agente; cooldown `rebootCooldownSec`) |
| POST | `/api/devices/:id/sample` | pide una muestra inmediata |
| WS | `/ws` | `snapshot` al conectar, luego `device`, `alert`, `tick` |

### Protocolo agente ↔ servidor

Una línea JSON por mensaje sobre TCP:

```
→ {"type":"hello","ip":"10.0.1.17","mac":"dc:a6:32:aa:bb:cc","iface":"eth0","ifaces":[{"name":"eth0","ip":"10.0.1.17","mac":"dc:a6:32:aa:bb:cc"}],"id":"banca-07","banca":"7","host":"rpi07","token":"…","version":"1.0.0","model":"Raspberry Pi 4 Model B Rev 1.4","kernel":"6.1.21-v8+","arch":"aarch64"}
← {"type":"hello_ack","serverTime":…}
→ {"type":"metrics","id":"banca-07","ip":"10.0.1.17","ts":…,"temp_c":52.1,"volt_core":0.85,"volt_sdram_c":1.1,…,"throttled":"0x0","throttled_raw":0,"cpu_pct":12.3,"cpu_mhz":1500,"load1":0.4,"mem_total_mb":3794,"mem_used_mb":610,"mem_pct":16.1,"lat_ms":1.2,"lat_target":"10.0.0.1","lat_method":"icmp","uptime_s":86400,"source":"mailbox"}
← {"type":"ping","t":…}            → {"type":"pong","t":…}
← {"type":"cmd","cmd":"reboot","req":"uuid","by":"admin@10.0.0.5"}
→ {"type":"ack","req":"uuid","cmd":"reboot","ok":true}      (y reinicia)
```

## 3. Seguridad

* El tráfico agente↔servidor va en claro con un token compartido. Está pensado para una LAN de bancas; si cruza redes no confiables, usar VPN (WireGuard) o un túnel TLS (stunnel/nginx stream) delante del puerto 7070.
* El panel usa autenticación básica; ponerlo detrás de un reverse proxy con HTTPS si se accede desde fuera de la red.
* El reinicio requiere estar autenticado en el panel, queda registrado en Graylog con usuario e IP, y tiene cooldown por banca.

## 4. Solución de problemas

* **Voltaje "—" / "sin dato"**: no hay `/dev/vcio` ni `vcgencmd`. Verificar `ls -l /dev/vcio`; si el driver no está, cargar `vcio` o compilar el kernel con `CONFIG_RASPBERRYPI_FIRMWARE` + vcio. Se puede bajar `thresholds.unknownLevel` a `"ok"` para que no tiña las tarjetas.
* **Latencia por TCP en vez de ICMP** (`lat_method: "tcp"`): faltan permisos ICMP; ver "Permisos".
* **La banca no aparece en su lugar**: el `id` del agente no coincide con el de `stations`. Aparece igual al final del panel si `allowUnknown` es true.
* **Reinicio "el agente no respondió"**: el agente está conectado pero no contestó en 5 s; revisar `journalctl -u rpimon` o `/var/log/rpimon.log`.
* **Reboot no efectivo**: en un init custom definir `reboot_cmd` con el comando correcto del sistema.
