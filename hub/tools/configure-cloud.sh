#!/usr/bin/env bash
# Point the hub at a Firebase project.
#
# The credentials go straight from here into hub/data/config.json on the
# board, which is gitignored and never leaves it. They are not echoed, not
# written to a temp file, and not stored in shell history — pass them by
# prompt, or by exporting the four variables before running this.
#
#   ./configure-cloud.sh [hub-address]
#
# Defaults to plantintelligence.local:7000.
set -euo pipefail

HUB="${1:-plantintelligence.local:7000}"

: "${FIREBASE_PROJECT_ID:=}"
: "${FIREBASE_API_KEY:=}"
: "${FIREBASE_EMAIL:=}"
: "${FIREBASE_PASSWORD:=}"

[ -n "$FIREBASE_PROJECT_ID" ] || read -r -p "Firebase project id: " FIREBASE_PROJECT_ID
[ -n "$FIREBASE_API_KEY" ]    || read -r -s -p "Web API key: " FIREBASE_API_KEY && echo
[ -n "$FIREBASE_EMAIL" ]      || read -r -p "Hub account email: " FIREBASE_EMAIL
[ -n "$FIREBASE_PASSWORD" ]   || read -r -s -p "Hub account password: " FIREBASE_PASSWORD && echo

echo "Configuring $HUB ..."
curl -sS -f -X POST "http://$HUB/api/cloud/config" \
  --data-urlencode "project_id=$FIREBASE_PROJECT_ID" \
  --data-urlencode "api_key=$FIREBASE_API_KEY" \
  --data-urlencode "email=$FIREBASE_EMAIL" \
  --data-urlencode "password=$FIREBASE_PASSWORD" \
  -G >/dev/null

echo "Waiting for the first documents to land ..."
for _ in $(seq 1 12); do
  sleep 5
  if curl -sS -m 10 "http://$HUB/api/cloud/status" \
     | grep -q '"connected": *true'; then
    echo "Connected. Firestore is mirroring."
    curl -sS "http://$HUB/api/cloud/status"; echo
    exit 0
  fi
done

echo "Not connected yet. What the hub reports:"
curl -sS "http://$HUB/api/cloud/status"; echo
exit 1
