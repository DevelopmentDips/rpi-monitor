#!/bin/sh
# Instala/actualiza el agente rpimon en todas las bancas listadas por SSH.
#
#   ./install-agent.sh hosts.txt ../agent/rpimon-arm64 [usuario_ssh] [--restart-only]
#
# El id de la banca lo toma el agente de /var/local/settings.ini (idBanca). Si en hosts.txt
# la primera columna es "-" o "auto" no se fuerza id; si es otro valor se escribe id=… en el conf.
#
# Requiere: ssh/scp con acceso (clave) a cada RPi, y que el usuario pueda usar sudo
# (o sea root). Lee SERVER, PORT y TOKEN del entorno o de deploy.env.
set -u
HOSTS=${1:?archivo de hosts}; BIN=${2:?binario rpimon}; USER_SSH=${3:-root}
[ -f "$(dirname "$0")/deploy.env" ] && . "$(dirname "$0")/deploy.env"
: "${SERVER:?definir SERVER (host del servidor rpi-monitor)}"; : "${PORT:=7070}"; : "${TOKEN:?definir TOKEN}"
UNIT="$(dirname "$0")/../agent/rpimon.service"; INIT="$(dirname "$0")/../agent/rpimon.init"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
ok=0; fail=0
grep -v '^\s*#' "$HOSTS" | grep -v '^\s*$' | while read -r ID HOST _; do
  printf '%-12s %-16s ' "$ID" "$HOST"
  if [ "${4:-}" = "--restart-only" ]; then
    $SSH "$USER_SSH@$HOST" 'systemctl restart rpimon 2>/dev/null || /etc/init.d/S99rpimon restart' >/dev/null 2>&1 && echo "reiniciado" || echo "FALLÓ"
    continue
  fi
  SUDO=$([ "$USER_SSH" = root ] && echo "" || echo "sudo")
  if scp -q -o BatchMode=yes -o ConnectTimeout=8 "$BIN" "$UNIT" "$INIT" "$USER_SSH@$HOST:/tmp/" 2>/dev/null && $SSH "$USER_SSH@$HOST" "
    set -e
    $SUDO install -m 755 /tmp/$(basename "$BIN") /usr/local/bin/rpimon
    $SUDO sh -c 'cat > /etc/rpimon.conf' <<CONF
server = $SERVER
port = $PORT
token = $TOKEN
$([ "$ID" = "-" ] || [ "$ID" = "auto" ] || echo "id = $ID")
interval = 5
CONF
    $SUDO chmod 600 /etc/rpimon.conf
    if command -v systemctl >/dev/null 2>&1; then
      $SUDO install -m 644 /tmp/rpimon.service /etc/systemd/system/rpimon.service
      $SUDO systemctl daemon-reload; $SUDO systemctl enable rpimon >/dev/null 2>&1; $SUDO systemctl restart rpimon
    else
      $SUDO install -m 755 /tmp/rpimon.init /etc/init.d/S99rpimon
      $SUDO /etc/init.d/S99rpimon restart >/dev/null 2>&1
    fi
    rm -f /tmp/$(basename "$BIN") /tmp/rpimon.service /tmp/rpimon.init
  " >/dev/null 2>&1; then echo "instalado"; ok=$((ok+1)); else echo "FALLÓ"; fail=$((fail+1)); fi
done
