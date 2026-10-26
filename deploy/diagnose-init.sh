#!/usr/bin/env bash
# Diagnóstico del sistema de arranque de las bancas.
#
# Dice qué init usa cada equipo (systemd, BusyBox/SysV, OpenRC), si el agente
# rpimon está registrado para arrancar solo, y cuál es el comando exacto para
# registrarlo en ese sistema.
#
#   ./diagnose-init.sh --only 10.0.0.20      # una banca, salida detallada
#   ./diagnose-init.sh                       # las 53, una línea por equipo
#   ./diagnose-init.sh --print               # imprime el probe para pegarlo a mano
#                                            # en una sesión SSH de la banca
set -u

BASE=10.0.0; FIRST=20; LAST=72
USER_SSH=root; PORT=22; JOBS=8
ONLY=(); PRINT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --range) FIRST=${2%%-*}; LAST=${2##*-}; shift 2 ;;
        --base) BASE=$2; shift 2 ;;
        --only) ONLY+=("$2"); shift 2 ;;
        --user) USER_SSH=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --print) PRINT=1; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "opción desconocida: $1" >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------------ probe remoto
# Corre en la banca. Imprime líneas "K: valor" y al final VEREDICTO / COMANDO.
read -r -d '' PROBE <<'PROBE_EOF'
#!/bin/sh
# --- quién es el PID 1
P1=$(cat /proc/1/comm 2>/dev/null)
P1EXE=$(readlink -f /proc/1/exe 2>/dev/null)
case "$P1EXE" in *busybox*) P1TIPO="BusyBox init" ;; *systemd*) P1TIPO="systemd" ;; *)
    case "$P1" in systemd) P1TIPO="systemd" ;; init) P1TIPO="init clásico (SysV)" ;; *) P1TIPO="${P1:-desconocido}" ;; esac ;;
esac
# /run/systemd/system solo existe si systemd es realmente el init en ejecución
SYSTEMD_ACTIVO=no; [ -d /run/systemd/system ] && SYSTEMD_ACTIVO=si
SYSTEMCTL=no; command -v systemctl >/dev/null 2>&1 && SYSTEMCTL=si
OPENRC=no; command -v rc-update >/dev/null 2>&1 && OPENRC=si
UPDATERCD=no; command -v update-rc.d >/dev/null 2>&1 && UPDATERCD=si
CHKCONFIG=no; command -v chkconfig >/dev/null 2>&1 && CHKCONFIG=si

INITTAB=no; [ -f /etc/inittab ] && INITTAB=si
SYSINIT=$(grep -E '^[^#]*sysinit' /etc/inittab 2>/dev/null | head -1)
RCS=no; [ -f /etc/init.d/rcS ] && RCS=si
RCDIRS=$(ls -d /etc/rc[0-9].d /etc/rc.d/rc[0-9].d 2>/dev/null | tr '\n' ' ')
RCLOCAL=no; [ -f /etc/rc.local ] && RCLOCAL=si
RUNLEVEL=$( (runlevel 2>/dev/null | awk '{print $2}') || true)
[ -z "$RUNLEVEL" ] && RUNLEVEL=$(grep -E '^id:' /etc/inittab 2>/dev/null | cut -d: -f2)

# --- arranque basado en dependencias (startpar): si está activo, un enlace
# --- suelto en rc?.d no alcanza; el servicio tiene que estar en .depend.start
CONCURRENCY=$(sed -n 's/^CONCURRENCY=//p' /etc/default/rcS 2>/dev/null | head -1)
DEPEND=no; [ -f /etc/init.d/.depend.start ] && DEPEND=si
DEPEND_TIENE_RPIMON=no
grep -q 'rpimon' /etc/init.d/.depend.start 2>/dev/null && DEPEND_TIENE_RPIMON=si

# --- ¿en qué runlevel está el equipo AHORA y hay enlace ahí?
RL_AHORA=$(runlevel 2>/dev/null | awk '{print $2}')
[ -z "$RL_AHORA" ] && RL_AHORA=$(sed -n 's/^id:\([0-9]\):initdefault.*/\1/p' /etc/inittab 2>/dev/null | head -1)
EN_RL_ACTUAL=no
[ -n "$RL_AHORA" ] && [ -e "/etc/rc$RL_AHORA.d/S99rpimon" ] && EN_RL_ACTUAL=si
RL_CON_ENLACE=""
for d in /etc/rc[0-9].d; do
    [ -e "$d/S99rpimon" ] && RL_CON_ENLACE="${RL_CON_ENLACE:+$RL_CON_ENLACE,}$(basename "$d")"
done
# de referencia: dónde está registrado un servicio propio del equipo que sí arranca
REF=$(ls /etc/rc[0-9].d/S*clienteBancas* 2>/dev/null | tr '\n' ' ')

# --- almacenamiento: qué está en RAM (para no escribir en disco)
fs_type_of() {
    awk -v path="$1" '"'"'
        { mp = $2; type = $3
          if (mp == "/" || path == mp || substr(path, 1, length(mp) + 1) == mp "/") {
              if (length(mp) >= best) { best = length(mp); found = type }
          } }
        END { print found }'"'"' /proc/mounts 2>/dev/null
}
RAMDIRS=""
for d in /var/log /run /var/volatile/log /dev/shm /tmp /var/run; do
    [ -d "$d" ] || continue
    rp=$(readlink -f "$d" 2>/dev/null); [ -n "$rp" ] || rp=$d
    case "$(fs_type_of "$rp")" in tmpfs|ramfs) RAMDIRS="${RAMDIRS:+$RAMDIRS }$d" ;; esac
done
LOGPATH=$(/etc/init.d/rpimon logpath 2>/dev/null | tail -1)

# --- estado del agente
BIN=no; [ -x /usr/local/bin/rpimon ] && BIN=si
INITSCRIPT=no; [ -x /etc/init.d/rpimon ] && INITSCRIPT=si
UNIT=no; [ -f /etc/systemd/system/rpimon.service ] && UNIT=si
CORRIENDO=no
PID=$(pgrep -x rpimon 2>/dev/null | head -1)
[ -z "$PID" ] && PID=$(ps 2>/dev/null | grep '[/]usr/local/bin/rpimon' | awk '{print $1}' | head -1)
[ -n "$PID" ] && CORRIENDO=si

# --- ¿está registrado para el arranque?
REG=""
[ "$SYSTEMCTL" = si ] && systemctl is-enabled rpimon >/dev/null 2>&1 && REG="systemd:enabled"
if [ -e /etc/init.d/S99rpimon ] && grep -q 'init\.d/S' /etc/init.d/rcS 2>/dev/null; then
    REG="${REG:+$REG,}/etc/init.d/S99rpimon"
elif [ -e /etc/init.d/S99rpimon ]; then
    REG_INUTIL="hay /etc/init.d/S99rpimon pero este init NO lo ejecuta"
fi
for d in /etc/rc[0-9].d /etc/rc.d/rc[0-9].d; do
    [ -e "$d/S99rpimon" ] && REG="${REG:+$REG,}$d/S99rpimon"
done
grep -q 'rpimon' /etc/rc.local 2>/dev/null && REG="${REG:+$REG,}rc.local"
grep -q 'rpimon' /etc/inittab 2>/dev/null && REG="${REG:+$REG,}inittab"

# --- veredicto y comando de registro
if [ "$SYSTEMD_ACTIVO" = si ] || { [ "$SYSTEMCTL" = si ] && [ "$P1TIPO" = systemd ]; }; then
    MODO="systemd"
    if [ "$UNIT" = no ]; then
        CMD="copiar rpimon.service a /etc/systemd/system/ y luego: systemctl daemon-reload && systemctl enable --now rpimon"
    else
        CMD="systemctl daemon-reload && systemctl enable --now rpimon && systemctl is-enabled rpimon"
    fi
elif [ -n "$RCDIRS" ]; then
    # SysV clásico (Debian, Raspbian, Yocto). Ojo: también tiene /etc/init.d/rcS,
    # pero ese rcS corre /etc/rcS.d/*, no /etc/init.d/S*.
    RL=$(sed -n 's/^id:\([0-9]\):initdefault.*/\1/p' /etc/inittab 2>/dev/null | head -1)
    [ -z "$RL" ] && RL=${RUNLEVEL:-5}
    [ -d "/etc/rc$RL.d" ] || RL=3
    MODO="SysV con rc?.d (runlevel por defecto: $RL)"
    CMD="for r in 2 3 4 5; do ln -sf ../init.d/rpimon /etc/rc\$r.d/S99rpimon; done; for k in 0 1 6; do ln -sf ../init.d/rpimon /etc/rc\$k.d/K01rpimon; done"
elif [ "$RCS" = si ] && grep -q 'init\.d/S' /etc/init.d/rcS 2>/dev/null; then
    MODO="BusyBox/Buildroot (rcS recorre /etc/init.d/S??*)"
    CMD="ln -sf /etc/init.d/rpimon /etc/init.d/S99rpimon"
elif [ "$OPENRC" = si ]; then
    MODO="OpenRC"
    CMD="rc-update add rpimon default"
elif [ "$INITTAB" = si ]; then
    MODO="init con /etc/inittab (sin rcS ni rc?.d)"
    CMD="agregar a /etc/inittab la línea:  ::respawn:/usr/local/bin/rpimon --config /etc/rpimon.conf   y luego: kill -HUP 1"
elif [ "$RCLOCAL" = si ]; then
    MODO="solo /etc/rc.local"
    CMD="agregar '/etc/init.d/rpimon start' antes del 'exit 0' de /etc/rc.local"
else
    MODO="desconocido"
    CMD="revisar a mano cómo arranca este sistema (ver /proc/1/comm y /etc/inittab)"
fi

echo "pid1: $P1TIPO ($P1, $P1EXE)"
echo "systemd_activo: $SYSTEMD_ACTIVO   systemctl: $SYSTEMCTL   openrc: $OPENRC   update-rc.d: $UPDATERCD   chkconfig: $CHKCONFIG"
echo "inittab: $INITTAB   sysinit: ${SYSINIT:-ninguno}"
echo "init.d/rcS: $RCS   rc?.d: ${RCDIRS:-ninguno}   rc.local: $RCLOCAL   runlevel: ${RUNLEVEL:-?}"
echo "runlevel ahora: ${RL_AHORA:-?}   enlace S99rpimon en ese runlevel: $EN_RL_ACTUAL   (está en: ${RL_CON_ENLACE:-ninguno})"
echo "referencia clienteBancas: ${REF:-no encontrado}"
echo "arranque por dependencias: CONCURRENCY=${CONCURRENCY:-no definido}  .depend.start=$DEPEND  incluye rpimon=$DEPEND_TIENE_RPIMON"
echo "dirs en RAM: ${RAMDIRS:-NINGUNO}   log del agente: ${LOGPATH:-?}"
echo "binario: $BIN   init.d/rpimon: $INITSCRIPT   unit systemd: $UNIT   corriendo: $CORRIENDO${PID:+ (pid $PID)}"
[ -n "${REG_INUTIL:-}" ] && echo "OJO: $REG_INUTIL"
echo "FLAGS: rl=${RL_AHORA:-?} enlace_en_rl=$EN_RL_ACTUAL dep=$DEPEND dep_rpimon=$DEPEND_TIENE_RPIMON concurrency=${CONCURRENCY:-no} corriendo=$CORRIENDO"
echo "MODO: $MODO"
echo "REGISTRADO: ${REG:-NO}"
echo "COMANDO: $CMD"
PROBE_EOF

if [ "$PRINT" -eq 1 ]; then
    printf '%s\n' "$PROBE"
    exit 0
fi

HOSTS=()
if [ ${#ONLY[@]} -gt 0 ]; then HOSTS=("${ONLY[@]}")
else for n in $(seq "$FIRST" "$LAST"); do HOSTS+=("$BASE.$n"); done; fi

SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -p $PORT ${SSH_EXTRA:-}"
DETALLE=0; [ ${#HOSTS[@]} -le 3 ] && DETALLE=1
TMP=$(mktemp -d)

probe_host() {
    host=$1
    out=$($SSH "$USER_SSH@$host" 'sh -s' <<< "$PROBE" 2>/dev/null)
    if [ -z "$out" ]; then
        echo "$host|-|SIN ACCESO SSH|-|-" > "$TMP/$host.res"
        return
    fi
    printf '%s\n' "$out" > "$TMP/$host.full"
    modo=$(printf '%s\n' "$out" | sed -n 's/^MODO: //p')
    flags=$(printf '%s\n' "$out" | sed -n 's/^FLAGS: //p')
    reg=$(printf '%s\n' "$out" | sed -n 's/^REGISTRADO: //p')
    cmd=$(printf '%s\n' "$out" | sed -n 's/^COMANDO: //p')
    echo "$host|$modo|$reg|$cmd|$flags" > "$TMP/$host.res"
}

i=0
for h in "${HOSTS[@]}"; do
    probe_host "$h" &
    i=$((i + 1)); [ $((i % JOBS)) -eq 0 ] && wait
done
wait

if [ "$DETALLE" -eq 1 ]; then
    for h in "${HOSTS[@]}"; do
        echo "=============================================================="
        echo "banca $h"
        echo "--------------------------------------------------------------"
        [ -f "$TMP/$h.full" ] && cat "$TMP/$h.full" || cat "$TMP/$h.res"
        echo
    done
else
    printf '%-14s %-3s %-10s %-5s %-9s %s\n' EQUIPO RL EN-SU-RL DEP CORRIENDO REGISTRADO
    for h in "${HOSTS[@]}"; do
        [ -f "$TMP/$h.res" ] || continue
        IFS='|' read -r host modo reg cmd flags < "$TMP/$h.res"
        # cada flag es un par clave=valor separado por espacios
        flag() { echo "$flags" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
        rl=$(flag rl); enrl=$(flag enlace_en_rl); dep=$(flag dep); corr=$(flag corriendo)
        printf '%-14s %-3s %-10s %-5s %-9s %s\n' "$host" "${rl:--}" "${enrl:--}" "${dep:--}" "${corr:--}" "$reg"
    done
    echo
    echo "RL = runlevel actual · EN-SU-RL = hay S99rpimon en ese runlevel · DEP = arranque por dependencias (.depend.start)"
    echo
    echo "Comandos de registro sugeridos (por modo detectado):"
    cat "$TMP"/*.res 2>/dev/null | awk -F'|' '$3=="NO" || $3=="" {print $2"\t"$4}' | sort -u | while IFS=$'\t' read -r m c; do
        [ -n "$c" ] && echo "  [$m]"$'\n'"    $c"
    done
fi
rm -rf "$TMP"
