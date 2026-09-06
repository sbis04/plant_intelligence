#!/bin/sh
# Restart the app when the MCU stops accepting commands.
#
# Twice now the Bridge has gone one-way: telemetry keeps arriving, so the
# board looks healthy, while every command the hub sends is dropped. The
# hub cannot water, the MCU's dead-man timer expires, and it waters on its
# own failsafe every 14 hours until someone notices. It ran that way for
# 57 hours once. A restart clears it every time.
#
# This lives on the host because arduino-app-cli is outside the container
# the app runs in. Install with hub/tools/install-watchdog.sh, run by cron
# once a minute.

API=http://localhost:7000/api/status
APP=user:plant-intelligence
STATE=$HOME/.mcu-watchdog-last-restart
FLAG=$HOME/.mcu-watchdog-restarted
LOG=$HOME/mcu-watchdog.log
DOWN_LIMIT=600          # commands failing this long (s) means restart
COOLDOWN=1800           # never restart more often than this (s)

json=$(curl -s --max-time 10 "$API") || exit 0
[ -z "$json" ] && exit 0

read -r down state <<EOF2
$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)["status"]
except Exception:
    sys.exit(1)
print(int(s.get("mcu_commands_down_s") or 0), s.get("watering_state") or "unknown")
' 2>/dev/null)
EOF2
[ -z "$down" ] && exit 0
[ "$down" -lt "$DOWN_LIMIT" ] && exit 0

# Never reset the MCU mid-watering: a reflash would stop the pump partway.
if [ "$state" != "idle" ]; then
  echo "$(date -Is) down ${down}s but watering ($state) — deferring" >> "$LOG"
  exit 0
fi

now=$(date +%s)
last=$(cat "$STATE" 2>/dev/null || echo 0)
if [ $((now - last)) -lt "$COOLDOWN" ]; then
  exit 0                # a restart just happened; give it time to settle
fi

echo "$now" > "$STATE"
touch "$FLAG"           # the app logs the reason when it comes back up
echo "$(date -Is) restarting: MCU commands down ${down}s" >> "$LOG"
arduino-app-cli app restart "$APP" >> "$LOG" 2>&1
echo "$(date -Is) restart exit=$?" >> "$LOG"
