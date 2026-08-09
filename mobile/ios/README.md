# iOS companion app

Native iOS client for the Plant Intelligence hub. Not started yet — this
directory reserves the spot in the monorepo.

## Planned scope

- Live garden status over the hub's local API (`/api/status` + the
  WebSocket `telemetry` event), discovered via Bonjour/mDNS on the LAN
- Manual watering with duration, stop, history, and the "why" behind every
  scheduled decision
- Plant photo diagnosis and assistant features (details to be defined)
- Remote access arrives when the hub grows its cloud sync (`hub/python/cloud.py`)

## Contract

The hub's API is the single interface — this app should need nothing the
dashboard (`hub/assets/`) doesn't already use. Payload shapes are documented
in the repository README and `docs/ARCHITECTURE.md`.
