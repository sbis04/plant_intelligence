#!/bin/sh
# Board-side half of the TV wake (see python/tvwake.py). The app runs in a container whose
# broadcasts never reach the LAN, so when it wants the TV on it leaves data/tv-wake.json and
# this script, run every minute by the arduino user's cron, broadcasts the Wake-on-LAN packet
# from the board itself. It checks every 5 s for the minute, so a request waits at most ~5 s.
REQ="$HOME/ArduinoApps/plant-intelligence/data/tv-wake.json"
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
    rm -f "$REQ"
  fi
  i=$((i + 1))
  sleep 5
done
