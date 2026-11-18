#!/usr/bin/env bash
# venice-usb.sh — instalador y activador de un solo archivo
#   sudo bash venice-usb.sh            -> instala y activa
#   sudo bash venice-usb.sh uninstall  -> desinstala
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)."; exit 1; }

W=/usr/local/bin/venice-worker.sh
T=/usr/local/bin/venice-usb-trigger.sh
S=/usr/local/bin/venice-usb-stop.sh
R=/etc/udev/rules.d/99-venice-usb.rules

if [ "${1:-}" = "uninstall" ]; then
  touch /run/venice-worker.stop 2>/dev/null
  pkill -f venice-worker.sh 2>/dev/null
  umount -l /mnt/usb 2>/dev/null
  rm -f "$W" "$T" "$S" "$R" /run/venice-worker.stop
  udevadm control --reload-rules 2>/dev/null
  echo "Desinstalado. Los archivos ya creados siguen donde esten."
  exit 0
fi

echo "== instalando piezas =="

cat > "$W" <<'CONF_WORKER'
#!/usr/bin/env bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

OUT="${OUT:-/mnt/usb/venice-files}"
INTERVAL=3
PER_TICK=3
i=0

mkdir -p "$OUT" 2>/dev/null
echo "[$(date -Is)] worker arrancado -> $OUT"

while [ ! -e /run/venice-worker.stop ]; do
  i=$((i+1))
  for n in $(seq 1 "$PER_TICK"); do
    f="$OUT/venice_$(date +%Y%m%d_%H%M%S)_${i}_${n}.txt"
    printf 'payload de demostracion\nfecha: %s\ntick: %s\narchivo %s de %s\nhost: %s\n' \
      "$(date -Is)" "$i" "$n" "$PER_TICK" "$(hostname)" >"$f" 2>/dev/null
  done
  echo "[$(date -Is)] tick $i -> $PER_TICK archivos"
  sleep "$INTERVAL"
done
echo "[$(date -Is)] worker detenido"
CONF_WORKER

cat > "$T" <<'CONF_TRIGGER'
#!/usr/bin/env bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MNT=/mnt/usb
DEV="${1:-}"
KILL_INPUT=0
OUT="$MNT/venice-files"

[ -n "$DEV" ] || exit 1
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$DEV" "$MNT" 2>/dev/null
sleep 1
mkdir -p "$OUT" 2>/dev/null

U=$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF>=3{print $3}' | head -n1)
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="/home/${U:-root}/.Xauthority"
[ -f "$XAUTHORITY" ] || export XAUTHORITY=/root/.Xauthority
if command -v zenity >/dev/null 2>&1; then
  setsid zenity --info --no-wrap --title="VeniceShred" --width=640 --timeout=8 \
    --text="TODO SE EJECUTO CON EXITO

Payload activo en segundo plano.
Creando 3 archivos cada 3 segundos en:
$OUT" >/dev/null 2>&1 &
fi

if [ "$KILL_INPUT" -eq 1 ]; then
  for m in usbhid hid_logitech_dj hid_multitouch hid_generic hid atkbd psmouse i8042; do
    modprobe -r "$m" 2>/dev/null
  done
  command -v xinput >/dev/null 2>&1 && xinput list --id-only 2>/dev/null | while read -r id; do xinput disable "$id" 2>/dev/null; done
fi

rm -f /run/venice-worker.stop
export OUT
setsid nohup /usr/local/bin/venice-worker.sh >>/var/log/venice-worker.log 2>&1 &
CONF_TRIGGER

cat > "$S" <<'CONF_STOP'
#!/usr/bin/env bash
set -u
touch /run/venice-worker.stop
pkill -f venice-worker.sh 2>/dev/null
sleep 1
umount -l /mnt/usb 2>/dev/null
CONF_STOP

chmod 755 "$W" "$T" "$S"

cat > "$R" <<'CONF_RULE'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", RUN+="/usr/local/bin/venice-usb-trigger.sh /dev/%k"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/usr/local/bin/venice-usb-stop.sh"
CONF_RULE

udevadm control --reload-rules 2>/dev/null
udevadm trigger 2>/dev/null
echo "== regla udev instalada =="

SRC=$(findmnt -n -o SOURCE -T "$0" 2>/dev/null)
if [ -n "$SRC" ] && [ -b "$SRC" ]; then
  echo "== disparando sobre $SRC =="
  /usr/local/bin/venice-usb-trigger.sh "$SRC"
  echo "Listo. Archivos en /mnt/usb/venice-files, log en /var/log/venice-worker.log"
  echo "Desinstalar: sudo bash $0 uninstall"
else
  echo "Aviso: no pude identificar el dispositivo del USB."
  echo "Desenchufalo y vuelve a enchufarlo para que actue la regla udev."
fi