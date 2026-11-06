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
LOG=$HOME/mcu-watchdog.log
# Reason flags are written into the app's data directory, not $HOME: the
# app runs in a container whose home is not this one, so a flag left here
# was never seen and the log never said why the hub had come back up.
DATA=$HOME/ArduinoApps/plant-intelligence/data
FLAG=$DATA/.restarted-mcu-down
DOWN_LIMIT=600          # commands failing this long (s) means restart
COOLDOWN=1800           # never restart more often than this (s)

# Two more reasons to restart, both added for running unattended:
#   - the app asked. It cannot restart itself from inside its container, so
#     it leaves this file in the data directory (the one path shared with
#     the host) and we do it. This is the emergency button in the phone app.
#   - the API has stopped answering altogether. The check below could only
#     ever act on a hub that was healthy enough to describe its own problem;
#     a Python process that is fully wedged said nothing and got nothing.
REQUEST=$DATA/restart.requested
UNREACHABLE=$HOME/.mcu-watchdog-unreachable   # consecutive failed polls
UNREACHABLE_LIMIT=5                           # minutes before we act

restart_app() {   # $1 = reason, $2 = flag file the app reads on boot
  now=$(date +%s)
  last=$(cat "$STATE" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    echo "$(date -Is) wanted to restart ($1) but a restart ran <${COOLDOWN}s ago" >> "$LOG"
    return 1
  fi
  echo "$now" > "$STATE"
  touch "$2"
  echo "$(date -Is) restarting: $1" >> "$LOG"
  arduino-app-cli app restart "$APP" >> "$LOG" 2>&1
  echo "$(date -Is) restart exit=$?" >> "$LOG"
}

json=$(curl -s --max-time 10 "$API") || json=""
if [ -z "$json" ]; then
  n=$(( $(cat "$UNREACHABLE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$UNREACHABLE"
  if [ "$n" -ge "$UNREACHABLE_LIMIT" ]; then
    rm -f "$UNREACHABLE"
    restart_app "API unreachable for ${n} min" "$DATA/.restarted-unreachable"
  fi
  exit 0
fi
rm -f "$UNREACHABLE"

# A requested restart is honoured before anything else is inspected. The
# app already refused to file the request while watering, so this does not
# need to check for that again.
if [ -f "$REQUEST" ]; then
  who=$(cat "$REQUEST" 2>/dev/null)
  rm -f "$REQUEST"
  # A request is deliberate; the MCU cooldown is about not thrashing on a
  # flapping bridge, so a request is allowed straight through.
  echo 0 > "$STATE"
  restart_app "requested ($who)" "$DATA/.restarted-requested"
  exit 0
fi

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

restart_app "MCU commands down ${down}s" "$FLAG"
