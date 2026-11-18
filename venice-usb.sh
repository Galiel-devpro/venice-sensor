#!/bin/bash
# venice-usb.sh — Instalador y activador de sensor de USB en Debian
# Uso: sudo bash venice-usb.sh          -> Instala y activa
#      sudo bash venice-usb.sh uninstall -> Desinstala

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)."; exit 1; }

# Directorio de salida: ahora va al disco duro
OUT_DIR="/var/log/venice-usb-sensor"
W=/usr/local/bin/venice-worker.sh
T=/usr/local/bin/venice-usb-trigger.sh
S=/usr/local/bin/venice-usb-stop.sh
R=/etc/udev/rules.d/99-venice-usb.rules

if [ "${1:-}" = "uninstall" ]; then
    touch /run/venice-worker.stop 2>/dev/null
    pkill -f venice-worker.sh 2>/dev/null || true
    umount -l /mnt/usb 2>/dev/null || true
    rm -f "$W" "$T" "$S" "$R" /run/venice-worker.stop
    udevadm control --reload-rules 2>/dev/null
    echo "Desinstalado. Los archivos de log permanecen en $OUT_DIR."
    exit 0
fi

echo "== Instalando piezas =="

# Worker: crea archivos en /var/log/venice-usb-sensor
cat > "$W" <<'CONF_WORKER'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

OUT="${OUT:-/var/log/venice-usb-sensor}"
INTERVAL=3
PER_TICK=3
i=0

mkdir -p "$OUT" 2>/dev/null
chmod 755 "$OUT" 2>/dev/null
echo "[$(date -Is)] worker arrancado -> $OUT"

while [ ! -e /run/venice-worker.stop ]; do
  i=$((i+1))
  for n in $(seq 1 "$PER_TICK"); do
    f="$OUT/venice_$(date +%Y%m%d_%H%M%S)_${i}_${n}.log"
    printf 'payload de demostracion\nfecha: %s\ntick: %s\narchivo %s de %s\nhost: %s\n' \
      "$(date -Is)" "$i" "$n" "$PER_TICK" "$(hostname)" >"$f" 2>/dev/null
  done
  echo "[$(date -Is)] tick $i -> $PER_TICK archivos"
  sleep "$INTERVAL"
done
echo "[$(date -Is)] worker detenido"
CONF_WORKER

# Trigger: detecta USB, muestra notificación gráfica y lanza worker
cat > "$T" <<'CONF_TRIGGER'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MNT=/mnt/usb
DEV="${1:-}"
OUT="/var/log/venice-usb-sensor"

[ -n "$DEV" ] || exit 1

# Montar solo si no está montado
if ! mountpoint -q "$MNT" 2>/dev/null; then
    mkdir -p "$MNT"
    mount "$DEV" "$MNT" 2>/dev/null || { echo "No se pudo montar $DEV"; exit 1; }
fi

sleep 1
mkdir -p "$OUT" 2>/dev/null

# Detectar usuario gráfico activo para mostrar notificación
U=$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF>=3{print $3}' | head -n1)
if [ -z "$U" ]; then U="root"; fi

# Configurar entorno gráfico
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="/run/user/$(id -u $U 2>/dev/null || echo 0)"
export XAUTHORITY="/home/${U}/.Xauthority"
[ -f "$XAUTHORITY" ] || export XAUTHORITY="/root/.Xauthority"

# Lanzar notificación zenity en segundo plano
if command -v zenity >/dev/null 2>&1; then
    setsid su - "$U" -c "zenity --info --no-wrap --title='VeniceShred' --width=640 --timeout=8 --text='TODO SE EJECUTO CON EXITO

Payload activo en segundo plano.
Creando 3 archivos cada 3 segundos en:
$OUT'" >/dev/null 2>&1 &
fi

# Limpiar estado anterior
rm -f /run/venice-worker.stop

# Lanzar worker
setsid env OUT="$OUT" nohup /usr/local/bin/venice-worker.sh >>/var/log/venice-worker.log 2>&1 &
echo "Trigger activado para $DEV"
CONF_TRIGGER

# Stop: detiene worker y desmonta
cat > "$S" <<'CONF_STOP'
#!/bin/bash
set -euo pipefail
touch /run/venice-worker.stop
pkill -f venice-worker.sh 2>/dev/null || true
sleep 1
umount -l /mnt/usb 2>/dev/null || true
CONF_STOP

chmod 755 "$W" "$T" "$S"

# Regla udev: dispara trigger al conectar USB con filesystem
cat > "$R" <<'CONF_RULE'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", RUN+="/usr/local/bin/venice-usb-trigger.sh /dev/%k"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/usr/local/bin/venice-usb-stop.sh"
CONF_RULE

udevadm control --reload-rules 2>/dev/null
udevadm trigger 2>/dev/null
echo "== Regla udev instalada =="

# Auto-disparar si se ejecuta desde el propio USB conectado
SRC=$(findmnt -n -o SOURCE -T "$0" 2>/dev/null)
if [ -n "$SRC" ] && [ -b "$SRC" ]; then
    echo "== Disparando sobre $SRC =="
    /usr/local/bin/venice-usb-trigger.sh "$SRC"
    echo "Listo. Archivos en $OUT_DIR, log en /var/log/venice-worker.log"
else
    echo "Aviso: no pude identificar el dispositivo del USB."
    echo "Desenchufalo y vuelve a enchufarlo para que actue la regla udev."
fi

echo "Desinstalar: sudo bash $0 uninstall"