#!/usr/bin/env bash
# Despliegue del agente rpimon en las bancas (Raspberry Pi 4).
#
# Copia el binario correcto según la arquitectura de cada equipo, instala el
# rpimon.conf que ya tenés armado tal cual está, registra el servicio en el init
# que use el sistema (systemd o SysV/BusyBox) y lo deja corriendo.
#
#   ./deploy-bancas.sh --dry-run          # muestra qué haría, sin tocar nada
#   ./deploy-bancas.sh                    # instala en 10.0.0.20 … 10.0.0.72
#   ./deploy-bancas.sh --only 10.0.0.20   # una sola banca (probar primero acá)
#   ./deploy-bancas.sh --action status    # ver si el agente corre en cada banca
#   ./deploy-bancas.sh --action restart   # reiniciar el agente en todas
#   ./deploy-bancas.sh --action logs      # traer el log de arranque de cada banca
#
# Requiere acceso SSH por clave como root. Transfiere los archivos por `ssh cat`
# en vez de scp, así funciona también en sistemas con dropbear o sin scp.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
AGENT_DIR="$HERE/../agent"

# ------------------------------------------------------------------ opciones
BASE=10.0.0
FIRST=20
LAST=72
USER_SSH=root
PORT=22
CONF="$AGENT_DIR/rpimon.conf"
ACTION=install
JOBS=8
PRIORITY=10
SUPERVISE=none
DRYRUN=0
FORCE=0
ONLY=()
LOGDIR=${RPIMON_LOGDIR:-/tmp/rpimon-deploy-$(date +%Y%m%d-%H%M%S)}

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Opciones:
  --range A-B        último octeto inicial y final (default 20-72)
  --base X.Y.Z       prefijo de red (default 10.0.0)
  --only IP          desplegar solo en esta IP (se puede repetir)
  --user USUARIO     usuario SSH (default root)
  --port N           puerto SSH (default 22)
  --conf ARCHIVO     rpimon.conf a instalar (default agent/rpimon.conf)
  --action ACCIÓN    install | status | restart | stop | logs (default install)
                     boot-probe       instala marcadores de control en rc?.d y en
                                      inittab; tras reiniciar, dmesg dice qué
                                      mecanismo de arranque funciona realmente
                     boot-probe-clean los quita
                     forensics        volcado completo: init real, cmdline del
                                      kernel, si kmsg funciona, qué servicios
                                      corren y el registro de bootlogd
                     status informa además si el agente arranca solo tras un reboot
  --jobs N           equipos en paralelo (default 8)
  --supervise MODO   cómo se garantiza que el agente esté corriendo:
                       none    (default) solo el init del runlevel
                       inittab línea `respawn` en /etc/inittab: init lo arranca
                               sin pasar por rc y lo revive si se muere
                       cron    entrada periódica en el crontab de root, que
                               también sirve de watchdog
  --priority NN      prioridad del enlace de arranque S<NN>rpimon (default 10).
                     Baja = arranca temprano. Útil si la secuencia de arranque
                     se traba en algún servicio y nunca llega a los S99.
  --dry-run          no ejecuta nada, solo muestra el plan
  --force            desplegar aunque el conf tenga valores de ejemplo
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --range) FIRST=${2%%-*}; LAST=${2##*-}; shift 2 ;;
        --base) BASE=$2; shift 2 ;;
        --only) ONLY+=("$2"); shift 2 ;;
        --user) USER_SSH=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --conf) CONF=$2; shift 2 ;;
        --action) ACTION=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --priority) PRIORITY=$2; shift 2 ;;
        --supervise) SUPERVISE=$2; shift 2 ;;
        --dry-run) DRYRUN=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "opción desconocida: $1" >&2; usage 2 ;;
    esac
done

BIN64="$AGENT_DIR/rpimon-arm64"
BIN32="$AGENT_DIR/rpimon-armv7"
UNIT="$AGENT_DIR/rpimon.service"
INIT="$AGENT_DIR/rpimon.init"

# ------------------------------------------------------------------ verificaciones previas
fail() { echo "ERROR: $*" >&2; exit 1; }

if [ "$ACTION" = install ]; then
    for f in "$BIN64" "$BIN32" "$UNIT" "$INIT" "$CONF"; do
        [ -f "$f" ] || fail "falta $f"
    done
    # No desplegar una configuración a medio armar en 53 equipos.
    problemas=()
    grep -qE '^[[:space:]]*token[[:space:]]*=[[:space:]]*"?cambiar-este-token"?[[:space:]]*$' "$CONF" \
        && problemas+=("el token sigue siendo el de ejemplo (cambiar-este-token)")
    grep -qE '^[[:space:]]*server[[:space:]]*=' "$CONF" \
        || problemas+=("no hay una línea 'server =' en el conf")
    if [ ${#problemas[@]} -gt 0 ] && [ "$FORCE" -eq 0 ]; then
        echo "El archivo $CONF tiene problemas:" >&2
        for p in "${problemas[@]}"; do echo "  · $p" >&2; done
        echo >&2
        echo "Corregilo antes de desplegar, o usá --force si es intencional." >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------ lista de equipos
HOSTS=()
if [ ${#ONLY[@]} -gt 0 ]; then
    HOSTS=("${ONLY[@]}")
else
    for n in $(seq "$FIRST" "$LAST"); do HOSTS+=("$BASE.$n"); done
fi

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -p $PORT ${SSH_EXTRA:-}"
SSH="ssh $SSH_OPTS"

echo "rpimon · ${ACTION} en ${#HOSTS[@]} equipos (${HOSTS[0]} … ${HOSTS[${#HOSTS[@]}-1]}) como $USER_SSH"
[ "$ACTION" = install ] && echo "conf: $CONF · servidor: $(grep -E '^[[:space:]]*server' "$CONF" | head -1 | sed 's/.*=[[:space:]]*//')"
echo "logs: $LOGDIR"
echo

if [ "$DRYRUN" -eq 1 ]; then
    echo "(--dry-run) equipos: ${HOSTS[*]}"
    echo "(--dry-run) se instalaría: /usr/local/bin/rpimon, /etc/rpimon.conf, servicio de arranque"
    exit 0
fi

mkdir -p "$LOGDIR"

# ------------------------------------------------------------------ script remoto de instalación
# Se ejecuta como root en la banca. Deja el resultado en una línea "RESULT ...".
read -r -d '' REMOTE_INSTALL <<'REMOTE'
set -e
stop_existing() {
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/rpimon.service ]; then
        systemctl stop rpimon >/dev/null 2>&1 || true
    fi
    for s in /etc/init.d/rpimon /etc/init.d/S99rpimon; do
        [ -x "$s" ] && "$s" stop >/dev/null 2>&1 || true
    done
    return 0
}
stop_existing

mkdir -p /usr/local/bin
# rename en vez de sobrescribir: evita "Text file busy" si el binario está corriendo
cat /tmp/rpimon.deploy.bin > /usr/local/bin/rpimon.new
chmod 755 /usr/local/bin/rpimon.new
mv -f /usr/local/bin/rpimon.new /usr/local/bin/rpimon
cat /tmp/rpimon.deploy.conf > /etc/rpimon.conf
chmod 600 /etc/rpimon.conf

BOOT=""
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    INIT=systemd
    cat /tmp/rpimon.deploy.service > /etc/systemd/system/rpimon.service
    chmod 644 /etc/systemd/system/rpimon.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable rpimon >/dev/null 2>&1 || true
    # verificar de verdad que quedó habilitado para el arranque
    systemctl is-enabled rpimon >/dev/null 2>&1 && BOOT=systemd
    systemctl restart rpimon
else
    INIT=sysv
    mkdir -p /etc/init.d
    cat /tmp/rpimon.deploy.init > /etc/init.d/rpimon
    chmod 755 /etc/init.d/rpimon

    # 1) SysV clásico con rc?.d (Debian, Raspbian, Yocto).
    #    Va PRIMERO: estos sistemas también tienen /etc/init.d/rcS, pero su rcS
    #    ejecuta /etc/rcS.d/*, NO /etc/init.d/S*.
    if [ -d /etc/rcS.d ] || [ -d /etc/rc5.d ] || [ -d /etc/rc3.d ] || [ -d /etc/rc2.d ]; then
        # Intento con la herramienta estándar, pero sin confiar en ella: en algunas
        # imágenes devuelve 0 y no crea nada, o crea los enlaces en menos runlevels
        # de los que el equipo realmente usa.
        # No se usa update-rc.d: crea enlaces en varios runlevels, que es
        # justamente lo que dispara la optimización del rc y deja el servicio
        # sin ejecutarse nunca.
        # Registrar el enlace S SOLO en el runlevel de arranque.
        #
        # El /etc/init.d/rc de Debian/Yocto trae esta optimización:
        #
        #   previous_start=/etc/rc$previous.d/S[0-9][0-9]$suffix
        #   [ -f $previous_start ] && [ ! -f $stop ] && continue
        #
        # Es decir: si el servicio ya tenía enlace de arranque en el runlevel
        # ANTERIOR, asume que sigue corriendo y NO lo ejecuta. Si el equipo
        # transiciona (por ejemplo 3 -> 5), tener enlaces en varios runlevels
        # hace que el script no se ejecute nunca. Con el enlace en uno solo,
        # previous_start no existe y siempre se ejecuta.
        P=${PRIORITY:-20}
        RL_BOOT=$(sed -n 's/^id:\([0-9]\):initdefault.*/\1/p' /etc/inittab 2>/dev/null | head -1)
        [ -n "$RL_BOOT" ] || RL_BOOT=$(runlevel 2>/dev/null | awk '{print $2}')
        [ -d "/etc/rc$RL_BOOT.d" ] || RL_BOOT=5
        [ -d "/etc/rc$RL_BOOT.d" ] || RL_BOOT=3
        # limpiar enlaces de arranque en cualquier otro runlevel
        for r in 2 3 4 5; do
            [ -d "/etc/rc$r.d" ] || continue
            [ "$r" = "$RL_BOOT" ] && continue
            rm -f /etc/rc$r.d/S[0-9][0-9]rpimon 2>/dev/null
        done
        rm -f /etc/rc$RL_BOOT.d/S[0-9][0-9]rpimon 2>/dev/null
        ln -sf ../init.d/rpimon "/etc/rc$RL_BOOT.d/S${P}rpimon" 2>/dev/null
        # Y la parada limpia al apagar o reiniciar.
        for k in 0 1 6; do
            [ -d "/etc/rc$k.d" ] || continue
            [ -e "/etc/rc$k.d/K01rpimon" ] || ln -sf ../init.d/rpimon "/etc/rc$k.d/K01rpimon" 2>/dev/null
        done
        BOOT=rcd
        # limpiar el S99 suelto en init.d: en este esquema no sirve y confunde
        rm -f /etc/init.d/S99rpimon
    fi

    # 2) BusyBox / Buildroot: solo si rcS realmente recorre /etc/init.d/S*
    if [ -z "$BOOT" ] && [ -f /etc/init.d/rcS ] && grep -q 'init\.d/S' /etc/init.d/rcS 2>/dev/null; then
        ln -sf /etc/init.d/rpimon /etc/init.d/S99rpimon 2>/dev/null \
            || { cat /etc/init.d/rpimon > /etc/init.d/S99rpimon; chmod 755 /etc/init.d/S99rpimon; }
        BOOT=init.d/S99rpimon
    fi

    # 3) OpenRC
    if [ -z "$BOOT" ] && command -v rc-update >/dev/null 2>&1; then
        rc-update add rpimon default >/dev/null 2>&1 && BOOT=openrc
    fi

    # 4) inittab sin rcS ni rc?.d: respawn directo (además reinicia el agente si muere)
    if [ -z "$BOOT" ] && [ -f /etc/inittab ] && ! grep -q 'rpimon' /etc/inittab 2>/dev/null; then
        if [ ! -d /etc/rc5.d ] && [ ! -f /etc/init.d/rcS ]; then
            echo '::respawn:/usr/local/bin/rpimon --config /etc/rpimon.conf' >> /etc/inittab
            kill -HUP 1 2>/dev/null || true
            BOOT=inittab
        fi
    fi

    # 5) último recurso: /etc/rc.local
    if [ -z "$BOOT" ] && [ -f /etc/rc.local ]; then
        if ! grep -q 'init\.d/rpimon' /etc/rc.local 2>/dev/null; then
            if grep -q '^exit 0' /etc/rc.local 2>/dev/null; then
                awk '/^exit 0/ && !d { print "/etc/init.d/rpimon start"; d=1 } { print }' /etc/rc.local > /tmp/rc.local.new \
                    && cat /tmp/rc.local.new > /etc/rc.local && rm -f /tmp/rc.local.new
            else
                echo '/etc/init.d/rpimon start' >> /etc/rc.local
            fi
        fi
        chmod 755 /etc/rc.local 2>/dev/null || true
        BOOT=rc.local
    fi

    # ---- supervisión adicional, independiente de rc ----
    case "${SUPERVISE:-none}" in
        inittab)
            if [ -f /etc/inittab ]; then
                # Con init supervisando, el enlace de rc sobra y podría duplicar el agente.
                rm -f /etc/rc[0-9].d/S[0-9][0-9]rpimon 2>/dev/null
                if ! grep -q '^rp:' /etc/inittab 2>/dev/null; then
                    cp /etc/inittab /etc/inittab.rpimon.bak 2>/dev/null
                    echo 'rp:2345:respawn:/etc/init.d/rpimon runforeground' >> /etc/inittab
                fi
                telinit q >/dev/null 2>&1 || kill -HUP 1 2>/dev/null || true
                BOOT="inittab:respawn"
                SUP_OK=1
            fi
            ;;
        cron)
            CRONCMD='*/2 * * * * /etc/init.d/rpimon start >/dev/null 2>&1'
            if command -v crontab >/dev/null 2>&1; then
                ( crontab -l 2>/dev/null | grep -v 'init.d/rpimon'; echo "$CRONCMD" ) | crontab - 2>/dev/null \
                    && BOOT="${BOOT:+$BOOT,}cron" && SUP_OK=1
            elif [ -d /etc/cron.d ]; then
                echo "*/2 * * * * root /etc/init.d/rpimon start >/dev/null 2>&1" > /etc/cron.d/rpimon
                BOOT="${BOOT:+$BOOT,}cron.d"; SUP_OK=1
            fi
            ;;
    esac

    # Con supervisión por inittab, init debería levantarlo tras `telinit q`.
    # Se le da margen y, si no aparece, se arranca a mano para no dejarlo caído
    # hasta el próximo reinicio.
    if [ "${SUPERVISE:-none}" = inittab ] && [ "${SUP_OK:-0}" = 1 ]; then
        i=0
        while [ $i -lt 6 ]; do
            pgrep -f /usr/local/bin/rpimon >/dev/null 2>&1 && break
            sleep 1; i=$((i + 1))
        done
    fi
    if ! pgrep -f /usr/local/bin/rpimon >/dev/null 2>&1; then
        /etc/init.d/rpimon restart >/dev/null 2>&1 || /etc/init.d/rpimon start >/dev/null 2>&1 || true
    fi
fi
rm -f /tmp/rpimon.deploy.*

# Verificar de verdad qué quedó registrado, en vez de confiar en el paso anterior.
VERIF=""
RL_ACTUAL=$(runlevel 2>/dev/null | awk '{print $2}')
[ -z "$RL_ACTUAL" ] && RL_ACTUAL=$(sed -n 's/^id:\([0-9]\):initdefault.*/\1/p' /etc/inittab 2>/dev/null | head -1)
if [ "$INIT" = systemd ]; then
    systemctl is-enabled rpimon >/dev/null 2>&1 && VERIF=systemd
else
    for d in /etc/rc[0-9].d /etc/rc.d/rc[0-9].d; do
        ls "$d"/S[0-9][0-9]rpimon >/dev/null 2>&1 && VERIF="${VERIF:+$VERIF,}$(basename "$d")/$(basename "$(ls "$d"/S[0-9][0-9]rpimon | head -1)")"
    done
    # Lo decisivo: ¿hay enlace en el runlevel en el que el equipo está corriendo?
    if [ -n "$RL_ACTUAL" ] && [ -d "/etc/rc$RL_ACTUAL.d" ] && ! ls "/etc/rc$RL_ACTUAL.d"/S[0-9][0-9]rpimon >/dev/null 2>&1; then
        VERIF=""   # da igual lo que haya en otros runlevels: en este no arranca
    fi
    # el S99 dentro de init.d solo cuenta si rcS lo recorre
    if [ -e /etc/init.d/S99rpimon ] && grep -q 'init\.d/S' /etc/init.d/rcS 2>/dev/null; then
        VERIF="${VERIF:+$VERIF,}init.d/S99rpimon"
    fi
    command -v rc-update >/dev/null 2>&1 && rc-update show default 2>/dev/null | grep -q rpimon && VERIF="${VERIF:+$VERIF,}openrc"
    grep -q '^rp:.*rpimon' /etc/inittab 2>/dev/null && VERIF="${VERIF:+$VERIF,}inittab:respawn"
    { crontab -l 2>/dev/null; cat /etc/cron.d/rpimon 2>/dev/null; } | grep -q 'init.d/rpimon' && VERIF="${VERIF:+$VERIF,}cron"
    grep -q 'init\.d/rpimon' /etc/rc.local 2>/dev/null && VERIF="${VERIF:+$VERIF,}rc.local"
fi
BOOT=$VERIF

sleep 2
PID=$(pgrep -f /usr/local/bin/rpimon 2>/dev/null | head -1)
[ -z "$PID" ] && PID=$(ps 2>/dev/null | grep '[r]pimon' | awk '{print $1}' | head -1)
IDB=$(grep -i '^[[:space:]]*idBanca' /var/local/settings.ini 2>/dev/null | head -1 \
      | sed 's/.*=//; s/;.*//; s/"//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
VCIO=no; [ -e /dev/vcio ] && VCIO=si
echo "RESULT init=$INIT runlevel=${RL_ACTUAL:-?} boot=${BOOT:-NO_REGISTRADO} pid=${PID:-NINGUNO} idBanca=${IDB:-SIN_DATO} vcio=$VCIO arch=$(uname -m)"
REMOTE

read -r -d '' REMOTE_STATUS <<'REMOTE'
PID=$(pgrep -f /usr/local/bin/rpimon 2>/dev/null | head -1)
[ -z "$PID" ] && PID=$(ps 2>/dev/null | grep '[r]pimon' | awk '{print $1}' | head -1)
IDB=$(grep -i '^[[:space:]]*idBanca' /var/local/settings.ini 2>/dev/null | head -1 \
      | sed 's/.*=//; s/;.*//; s/"//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
VER=$(/usr/local/bin/rpimon --help 2>&1 | grep -m1 '^rpimon ' | awk '{print $2}')
UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
# ¿va a volver a arrancar solo después de un reboot?
BOOT=""
RL_ACTUAL=$(runlevel 2>/dev/null | awk '{print $2}')
[ -z "$RL_ACTUAL" ] && RL_ACTUAL=$(sed -n 's/^id:\([0-9]\):initdefault.*/\1/p' /etc/inittab 2>/dev/null | head -1)
if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/rpimon.service ]; then
    systemctl is-enabled rpimon >/dev/null 2>&1 && BOOT=systemd
else
    for d in /etc/rc[0-9].d /etc/rc.d/rc[0-9].d; do
        [ -e "$d/S99rpimon" ] && BOOT="${BOOT:+$BOOT,}$(basename "$d")"
    done
    if [ -n "$RL_ACTUAL" ] && [ -d "/etc/rc$RL_ACTUAL.d" ] && [ ! -e "/etc/rc$RL_ACTUAL.d/S99rpimon" ]; then
        BOOT=""
    fi
    # un S99 suelto en /etc/init.d solo arranca si rcS recorre /etc/init.d/S*
    if [ -e /etc/init.d/S99rpimon ] && grep -q 'init\.d/S' /etc/init.d/rcS 2>/dev/null; then
        BOOT="${BOOT:+$BOOT,}init.d/S99rpimon"
    fi
    command -v rc-update >/dev/null 2>&1 && rc-update show default 2>/dev/null | grep -q rpimon && BOOT="${BOOT:+$BOOT,}openrc"
    grep -q 'rpimon' /etc/inittab 2>/dev/null && BOOT="${BOOT:+$BOOT,}inittab"
    grep -q 'init\.d/rpimon' /etc/rc.local 2>/dev/null && BOOT="${BOOT:+$BOOT,}rc.local"
fi
echo "RESULT runlevel=${RL_ACTUAL:-?} boot=${BOOT:-NO_REGISTRADO} pid=${PID:-NINGUNO} idBanca=${IDB:-SIN_DATO} version=${VER:-?} uptime_equipo=${UP:-?}s"
REMOTE

read -r -d '' REMOTE_PROBE <<'REMOTE'
# Experimento de control: instala marcadores mínimos en cada mecanismo de
# arranque. No dependen del agente ni de nada del proyecto: solo escriben una
# línea en el ring buffer del kernel. Tras reiniciar, dmesg dice cuáles se
# ejecutaron y cuáles no.
set -e
cat > /etc/init.d/rpimon-probe <<'EOF'
#!/bin/sh
echo "rpimon-probe: EJECUTADO por $1 (uptime $(cut -d. -f1 /proc/uptime 2>/dev/null)s)" > /dev/kmsg 2>/dev/null
exit 0
EOF
chmod 755 /etc/init.d/rpimon-probe

# 1) mecanismo rc?.d, en el runlevel de arranque
RL=$(sed -n 's/^id:\([0-9]\):initdefault.*/\1/p' /etc/inittab 2>/dev/null | head -1)
[ -n "$RL" ] || RL=$(runlevel 2>/dev/null | awk '{print $2}')
[ -d "/etc/rc$RL.d" ] || RL=5
rm -f /etc/rc[0-9].d/S[0-9][0-9]rpimon-probe 2>/dev/null
ln -sf ../init.d/rpimon-probe "/etc/rc$RL.d/S21rpimon-probe"

# 2) mecanismo inittab (acción `once`, se ejecuta una sola vez por runlevel)
if [ -f /etc/inittab ] && ! grep -q '^pb:' /etc/inittab; then
    cp /etc/inittab /etc/inittab.probe.bak 2>/dev/null
    echo 'pb:2345:once:/etc/init.d/rpimon-probe inittab' >> /etc/inittab
fi

# 3) marca de referencia: se escribe ahora, para confirmar que kmsg funciona
echo "rpimon-probe: instalado (esta linea prueba que /dev/kmsg escribe)" > /dev/kmsg 2>/dev/null

echo "RESULT probe instalado en rc$RL.d/S21rpimon-probe + inittab(pb) — reiniciar y revisar dmesg"
REMOTE

read -r -d '' REMOTE_PROBE_CLEAN <<'REMOTE'
rm -f /etc/init.d/rpimon-probe /etc/rc[0-9].d/S[0-9][0-9]rpimon-probe 2>/dev/null
if [ -f /etc/inittab ]; then
    sed -i '/^pb:/d' /etc/inittab 2>/dev/null
    telinit q >/dev/null 2>&1 || kill -HUP 1 2>/dev/null || true
fi
echo "RESULT probe eliminado"
REMOTE

read -r -d '' REMOTE_FORENSICS <<'REMOTE'
echo "=== 1. ¿reinició de verdad, y hace cuánto?"
echo "  uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s   fecha del equipo: $(date 2>/dev/null)"
echo "  runlevel (previo actual): $(runlevel 2>/dev/null)"

echo "=== 2. ¿quién es el init y qué le pide el kernel?"
echo "  /proc/cmdline: $(cat /proc/cmdline 2>/dev/null)"
echo "  PID 1: $(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null) -> $(readlink -f /proc/1/exe 2>/dev/null)"

echo "=== 3. ¿sobrevivieron los marcadores del experimento?"
for f in /etc/init.d/rpimon-probe /etc/rc5.d/S21rpimon-probe; do
    [ -e "$f" ] && echo "  OK      $f" || echo "  FALTA   $f  <-- se perdió tras el reinicio"
done
echo "  inittab: $(grep -c '^pb:\|^rp:' /etc/inittab 2>/dev/null) línea(s) nuestras"

echo "=== 4. ¿funciona /dev/kmsg? (si esto no aparece, el instrumento es inútil)"
echo "rpimon-probe: ESCRITURA-MANUAL-DE-PRUEBA" > /dev/kmsg 2>/dev/null
sleep 1
dmesg 2>/dev/null | grep -c "ESCRITURA-MANUAL-DE-PRUEBA" | sed 's/^/  líneas encontradas en dmesg: /'
echo "  tamaño del buffer de dmesg: $(dmesg 2>/dev/null | wc -l) líneas"

echo "=== 5. ¿el marcador se ejecuta cuando se lo llama a mano?"
[ -x /etc/init.d/rpimon-probe ] && { /etc/init.d/rpimon-probe manual; sleep 1; dmesg 2>/dev/null | grep 'rpimon-probe' | tail -3 | sed 's/^/  /'; } || echo "  (no está instalado)"

echo "=== 6. ¿hasta dónde llegó la secuencia de arranque?"
RL=$(runlevel 2>/dev/null | awk '{print $2}')
[ -n "$RL" ] || RL=5
PSOUT=$(ps 2>/dev/null)
for sc in /etc/rc$RL.d/S*; do
    [ -e "$sc" ] || continue
    b=$(basename "$sc")
    n=$(echo "$b" | sed 's/^S[0-9][0-9]//; s/\.sh$//')
    # comparar por los primeros caracteres: el proceso puede llamarse distinto
    short=$(echo "$n" | cut -c1-7)
    if echo "$PSOUT" | grep -qi "$short"; then
        echo "  $b -> hay proceso vivo"
    else
        echo "  $b -> SIN proceso  <-- la secuencia pudo haberse detenido acá o antes"
    fi
done
echo "  (un script que arranca su programa en primer plano bloquea todo lo que"
echo "   viene después en orden alfabético dentro del mismo runlevel)"

echo "=== 7. registro de bootlogd (lo que rc ejecutó de verdad)"
for f in /var/log/boot /var/log/boot.log /var/volatile/log/boot; do
    [ -f "$f" ] && { echo "  --- $f ($(wc -l < "$f") líneas), últimas 25:"; tail -25 "$f" | sed 's/^/  /'; break; }
done
[ -f /var/log/boot ] || [ -f /var/log/boot.log ] || [ -f /var/volatile/log/boot ] || echo "  (no hay boot log)"
echo "RESULT forense recolectado"
REMOTE

read -r -d '' REMOTE_LOGS <<'REMOTE'
echo "### estado"
PID=$(pgrep -f /usr/local/bin/rpimon 2>/dev/null | head -1)
[ -z "$PID" ] && PID=$(ps 2>/dev/null | grep '[/]usr/local/bin/rpimon' | awk '{print $1}' | head -1)
echo "pid=${PID:-NINGUNO}  uptime_equipo=$(cut -d. -f1 /proc/uptime 2>/dev/null)s  runlevel=$(runlevel 2>/dev/null | awk '{print $2}')"

echo "### ¿sobrevivió la instalación al reinicio?"
for f in /usr/local/bin/rpimon /etc/rpimon.conf /etc/init.d/rpimon; do
    [ -e "$f" ] && echo "  OK      $f" || echo "  FALTA   $f"
done
RL=$(runlevel 2>/dev/null | awk '{print $2}')
if [ -n "$RL" ]; then
    L=$(ls "/etc/rc$RL.d"/S[0-9][0-9]rpimon 2>/dev/null | head -1)
    [ -n "$L" ] && echo "  OK      $L -> $(readlink "$L" 2>/dev/null)" || echo "  FALTA   enlace S??rpimon en /etc/rc$RL.d"
fi

echo "### logs (se muestran TODOS los candidatos, no solo el primero)"
FOUND=0
SEEN=""
for f in /var/log/rpimon.log /var/volatile/log/rpimon.log /run/rpimon.log /dev/shm/rpimon.log /tmp/rpimon.log; do
    [ -f "$f" ] || continue
    RP=$(readlink -f "$f" 2>/dev/null) || RP=$f
    case " $SEEN " in *" $RP "*) continue ;; esac   # mismo archivo por symlink
    SEEN="$SEEN $RP"
    SZ=$(wc -c < "$f" 2>/dev/null)
    if [ "${SZ:-0}" -gt 0 ]; then
        echo "--- $f ($SZ bytes, últimas 25):"
        tail -25 "$f"
        FOUND=1
    else
        echo "--- $f (vacío)"
    fi
done
[ "$FOUND" = 1 ] || echo "  (ningún log con contenido: el init no llegó a ejecutarse, o LOG_MODE=none)"

echo "### ¿la secuencia de arranque llegó al final?"
RCPROC=$(ps 2>/dev/null | grep '[i]nit.d/rc ' | head -3)
[ -n "$RCPROC" ] && echo "  TRABADA: todavía hay un /etc/init.d/rc corriendo:" && echo "$RCPROC"
[ -f /etc/nologin ] && echo "  /etc/nologin existe -> S*rmnologin.sh NO se ejecutó (la secuencia no llegó ahí)"
pgrep -x bootlogd >/dev/null 2>&1 && echo "  bootlogd sigue vivo -> S*stop-bootlogd NO se ejecutó"
[ -z "$RCPROC" ] && [ ! -f /etc/nologin ] && ! pgrep -x bootlogd >/dev/null 2>&1 && echo "  la secuencia terminó normalmente"
echo "  scripts del runlevel actual, en orden:"
RL=$(runlevel 2>/dev/null | awk '{print $2}')
[ -n "$RL" ] && ls "/etc/rc$RL.d" 2>/dev/null | grep '^S' | tr '\n' ' ' && echo

echo "### transición de runlevels (previo -> actual)"
echo "  runlevel: $(runlevel 2>/dev/null)   [si el previo NO es N ni S, el rc aplica su"
echo "            optimización y saltea servicios que ya estaban en el runlevel anterior]"

echo "### registro de arranque (bootlogd): ¿qué scripts corrió el rc realmente?"
BOOTLOG=""
for f in /var/log/boot /var/log/boot.log /var/volatile/log/boot; do [ -f "$f" ] && { BOOTLOG=$f; break; }; done
if [ -n "$BOOTLOG" ]; then
    echo "  --- $BOOTLOG: líneas con S20/S99 o rpimon:"
    grep -aE 'rpimon|S[0-9][0-9](cliente|samba|ntpd|syslog)' "$BOOTLOG" 2>/dev/null | tail -20 | sed 's/^/  /'
    echo "  --- total de líneas del boot log: $(wc -l < "$BOOTLOG" 2>/dev/null)"
else
    echo "  (no hay boot log; bootlogd puede no estar guardando nada)"
fi

echo "### entorno que /etc/init.d/rc impone a los scripts de arranque"
if [ -f /etc/default/rcS ]; then
    grep -E '^[A-Z_]+=' /etc/default/rcS 2>/dev/null | sed 's/^/  /'
else
    echo "  (no hay /etc/default/rcS)"
fi
echo "  ulimit stack en esta sesión: $(ulimit -s 2>/dev/null)"
if echo "rpimon-init: prueba de escritura en kmsg" > /dev/kmsg 2>/dev/null; then
    echo "  /dev/kmsg: escribible (la traza es confiable)"
else
    echo "  /dev/kmsg: NO escribible -> una traza vacía no prueba nada acá"
fi

echo "### traza del kernel (dmesg) - prueba si el init se ejecutó al arrancar"
DM=$(dmesg 2>/dev/null | grep -i rpimon | grep -v 'prueba de escritura' | tail -20)
if [ -n "$DM" ]; then echo "$DM"; else echo "  (ninguna: el init NO se ejecutó, o el kernel ya rotó el buffer)"; fi

echo "### syslog (líneas de rpimon)"
{ logread 2>/dev/null || cat /var/log/messages 2>/dev/null; } | grep -i rpimon | tail -10
REMOTE

REMOTE_RESTART='if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/rpimon.service ]; then systemctl restart rpimon; else for s in /etc/init.d/S99rpimon /etc/init.d/rpimon; do [ -x "$s" ] && "$s" restart >/dev/null 2>&1 && break; done; fi; sleep 1; PID=$(pgrep -f /usr/local/bin/rpimon 2>/dev/null | head -1); echo "RESULT pid=${PID:-NINGUNO}"'
REMOTE_STOP='if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/rpimon.service ]; then systemctl stop rpimon; else for s in /etc/init.d/S99rpimon /etc/init.d/rpimon; do [ -x "$s" ] && "$s" stop >/dev/null 2>&1 && break; done; fi; echo "RESULT detenido"'

# ------------------------------------------------------------------ trabajo por equipo
do_host() {
    host=$1
    log="$LOGDIR/$host.log"
    target="$USER_SSH@$host"

    if ! arch=$($SSH "$target" 'uname -m' 2>>"$log"); then
        echo "$host|FALLO|sin acceso SSH" >> "$LOGDIR/results"
        return
    fi

    if [ "$ACTION" = logs ] || [ "$ACTION" = forensics ]; then
        SCR=$REMOTE_LOGS; [ "$ACTION" = forensics ] && SCR=$REMOTE_FORENSICS
        {
            echo "=============================================================="
            echo "banca $host"
            echo "--------------------------------------------------------------"
            $SSH "$target" "sh -s" <<< "$SCR" 2>>"$log" || echo "(sin acceso SSH)"
            echo
        } > "$LOGDIR/$host.out"
        echo "$host|OK|$ACTION recolectado" >> "$LOGDIR/results"
        return
    fi

    if [ "$ACTION" != install ]; then
        case "$ACTION" in
            status) script=$REMOTE_STATUS ;;
            logs) script=$REMOTE_LOGS ;;
            boot-probe) script=$REMOTE_PROBE ;;
            forensics) script=$REMOTE_FORENSICS ;;
            boot-probe-clean) script=$REMOTE_PROBE_CLEAN ;;
            restart) script=$REMOTE_RESTART ;;
            stop) script=$REMOTE_STOP ;;
            *) echo "$host|FALLO|acción desconocida" >> "$LOGDIR/results"; return ;;
        esac
        out=$($SSH "$target" "sh -s" <<< "$script" 2>>"$log" | grep '^RESULT' | head -1)
        if [ -z "$out" ]; then
            echo "$host|FALLO|sin respuesta" >> "$LOGDIR/results"
        elif echo "$out" | grep -qE 'boot=NO_REGISTRADO|pid=NINGUNO'; then
            echo "$host|AVISO|${out#RESULT }" >> "$LOGDIR/results"
        else
            echo "$host|OK|${out#RESULT }" >> "$LOGDIR/results"
        fi
        return
    fi

    case "$arch" in
        aarch64|arm64) bin=$BIN64 ;;
        armv7l|armv8l) bin=$BIN32 ;;
        armv6l) echo "$host|FALLO|arquitectura $arch no soportada (Pi 4 debería ser armv7l o aarch64)" >> "$LOGDIR/results"; return ;;
        *) echo "$host|FALLO|arquitectura desconocida: $arch" >> "$LOGDIR/results"; return ;;
    esac

    # Transferencia por ssh+cat: no necesita scp ni sftp en el equipo remoto
    if ! $SSH "$target" 'cat > /tmp/rpimon.deploy.bin' < "$bin" 2>>"$log"; then
        echo "$host|FALLO|no se pudo copiar el binario" >> "$LOGDIR/results"; return
    fi
    $SSH "$target" 'cat > /tmp/rpimon.deploy.conf' < "$CONF" 2>>"$log"
    $SSH "$target" 'cat > /tmp/rpimon.deploy.service' < "$UNIT" 2>>"$log"
    $SSH "$target" 'cat > /tmp/rpimon.deploy.init' < "$INIT" 2>>"$log"

    out=$($SSH "$target" "PRIORITY=$PRIORITY SUPERVISE=$SUPERVISE sh -s" <<< "$REMOTE_INSTALL" 2>>"$log" | grep '^RESULT' | head -1)
    if [ -z "$out" ]; then
        echo "$host|FALLO|la instalación no devolvió resultado (ver $log)" >> "$LOGDIR/results"
    elif echo "$out" | grep -q 'pid=NINGUNO'; then
        echo "$host|FALLO|instalado pero el agente no quedó corriendo · ${out#RESULT }" >> "$LOGDIR/results"
    elif echo "$out" | grep -q 'boot=NO_REGISTRADO'; then
        echo "$host|AVISO|corriendo, pero NO va a arrancar solo tras un reboot · ${out#RESULT }" >> "$LOGDIR/results"
    else
        echo "$host|OK|$(basename "$bin") · ${out#RESULT }" >> "$LOGDIR/results"
    fi
}

: > "$LOGDIR/results"
launched=0
for h in "${HOSTS[@]}"; do
    do_host "$h" &
    launched=$((launched + 1))
    [ $((launched % JOBS)) -eq 0 ] && wait
done
wait

# ------------------------------------------------------------------ resumen
ok=$(grep -c '|OK|' "$LOGDIR/results" 2>/dev/null || true); ok=${ok:-0}
warn=$(grep -c '|AVISO|' "$LOGDIR/results" 2>/dev/null || true); warn=${warn:-0}
bad=$(grep -c '|FALLO|' "$LOGDIR/results" 2>/dev/null || true); bad=${bad:-0}
if [ "$ACTION" = logs ] || [ "$ACTION" = forensics ]; then
    for h in "${HOSTS[@]}"; do [ -f "$LOGDIR/$h.out" ] && cat "$LOGDIR/$h.out"; done
fi
echo "----------------------------------------------------------------"
sort -t. -k4 -n "$LOGDIR/results" | while IFS='|' read -r h st msg; do
    printf '%-14s %-6s %s\n' "$h" "$st" "$msg"
done
echo "----------------------------------------------------------------"
echo "OK: $ok    AVISO: $warn    FALLO: $bad    (detalle por equipo en $LOGDIR)"
[ "$warn" -eq 0 ] || echo "AVISO: los equipos marcados corren ahora pero no tienen el arranque registrado."
[ "$bad" -eq 0 ] || exit 1
