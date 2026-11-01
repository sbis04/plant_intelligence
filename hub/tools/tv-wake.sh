#!/bin/sh
# Board-side half of the TV wake (see python/tvwake.py). The app runs in a container whose
# broadcasts never reach the LAN, so when it wants the TV on it leaves data/tv-wake.json and
# this script, run every minute by the arduino user's cron, broadcasts the Wake-on-LAN packet
# from the board itself. It checks every 5 s for the minute, so a request waits at most ~5 s.
# The router can give the TV a new address when it wakes from deep sleep, so afterwards it also
# finds the TV by its MAC (a quick ping sweep fills the neighbour table) and writes the address
# to data/tv-ip.json for the app.
# cron runs with a bare PATH; ping and friends live in the sbin folders too.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DATA="$HOME/ArduinoApps/plant-intelligence/data"
# One run at a time (cron starts one a minute; a wake can take longer).
LOCK=/tmp/tv-wake.lock
mkdir "$LOCK" 2>/dev/null || { [ -n "$(find "$LOCK" -mmin +5 2>/dev/null)" ] && rmdir "$LOCK" && mkdir "$LOCK"; } || exit 0
trap 'rmdir "$LOCK"' EXIT
REQ="$DATA/tv-wake.json"
i=0
while [ $i -lt 11 ]; do
  if [ -f "$REQ" ]; then
    python3 - "$REQ" <<'PY'
import json, socket, sys, time
req = json.load(open(sys.argv[1]))
if time.time() - req.get("at", 0) < 300:          # ignore stale requests
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    subnet = ".".join(req.get("ip", "255.255.255.255").split(".")[:3] + ["255"])
    for mac in req.get("macs", []):
        raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
        if len(raw) != 6:
            continue
        pkt = b"\xff" * 6 + raw * 16
        for _ in range(3):
            for dest in ("255.255.255.255", subnet, req.get("ip")):
                for port in (9, 7):
                    try:
                        s.sendto(pkt, (dest, port))
                    except OSError:
                        pass
            time.sleep(0.2)
PY
    MACS=$(python3 -c "import json,sys; print(' '.join(m.lower() for m in json.load(open(sys.argv[1])).get('macs', [])))" "$REQ")
    PREFIX=$(python3 -c "import json,sys; print('.'.join(json.load(open(sys.argv[1])).get('ip', '192.168.68.1').split('.')[:3]))" "$REQ")
    rm -f "$REQ"
    # Find the TV's address once it has rejoined Wi-Fi: up to ~60 s.
    tries=0
    while [ $tries -lt 6 ]; do
      sleep 10
      n=1
      while [ $n -le 254 ]; do ping -c1 -W1 "$PREFIX.$n" >/dev/null 2>&1 & n=$((n + 1)); done
      wait
      for mac in $MACS; do
        # The kernel's neighbour table: IP, type, flags (0x2 = complete), MAC, ...
        ip=$(awk -v m="$mac" 'tolower($4) == m && $3 == "0x2" {print $1; exit}' /proc/net/arp)
        if [ -n "$ip" ]; then
          printf '{"ip": "%s", "at": %s}\n' "$ip" "$(date +%s)" > "$DATA/tv-ip.json"
          tries=99
          break
        fi
      done
      tries=$((tries + 1))
    done
  fi
  i=$((i + 1))
  sleep 5
done
