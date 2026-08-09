"""Local HTTP + WebSocket API, served by the web_ui Brick.

This is the surface the mobile app talks to over the LAN, and it also backs
the built-in dashboard in assets/. REST for request/response, a WebSocket
"telemetry" event for live updates.

The Brick wraps handlers in FastAPI, which builds the request contract from
each function's signature — so handlers take exactly the parameters they
expect (typed, with defaults for optional ones) and nothing else. Optional
values arrive as query parameters: POST /api/water?duration_s=120.

Endpoints:
  GET  /api/status    → live sensors, watering state, current plan, weather
  GET  /api/history   → recent watering events
  GET  /api/logs      → recent system log entries
  GET  /api/config    → active configuration
  POST /api/water     → start a manual watering (?duration_s=, optional)
  POST /api/stop      → stop watering now
  POST /api/location  → set coordinates (?latitude=&longitude=), e.g. phone GPS
"""

from typing import Optional


def register(ui, ctx):
    """Wire endpoints onto the WebUI brick. `ctx` is the AppContext from main."""

    def status():
        snap = ctx.hardware.snapshot()
        snap["soil_pct"] = ctx.config.soil_raw_to_pct(snap.get("soil_raw", -1))
        return {
            "status": snap,
            "plan": ctx.current_plan.to_dict() if ctx.current_plan else None,
            "weather": ctx.current_weather.to_dict() if ctx.current_weather else None,
        }

    def history():
        return {"history": ctx.store.recent_history(30)}

    def logs():
        return {"logs": ctx.store.recent_logs(50)}

    def get_config():
        from dataclasses import asdict
        return {"config": asdict(ctx.config)}

    def water(duration_s: Optional[int] = None):
        duration = duration_s if duration_s else ctx.config.base_duration_s
        duration = max(ctx.config.min_duration_s,
                       min(ctx.config.max_duration_s, duration))
        ok = ctx.request_manual_watering(duration)
        return {"accepted": ok, "duration_s": duration}

    def stop():
        ctx.hardware.stop_watering()
        ctx.store.log("OVERRIDE", "Manual stop requested via API")
        return {"accepted": True}

    def set_location(latitude: float, longitude: float,
                     source: str = "device", name: str = ""):
        """Precise fix from a client — e.g. the mobile app sending phone GPS."""
        if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
            return {"accepted": False, "error": "coordinates out of range"}
        ctx.set_location(latitude, longitude, source=source, name=name)
        return {"accepted": True, "latitude": latitude, "longitude": longitude}

    ui.expose_api("GET", "/api/status", status)
    ui.expose_api("GET", "/api/history", history)
    ui.expose_api("GET", "/api/logs", logs)
    ui.expose_api("GET", "/api/config", get_config)
    ui.expose_api("POST", "/api/water", water)
    ui.expose_api("POST", "/api/stop", stop)
    ui.expose_api("POST", "/api/location", set_location)

    # WebSocket commands (the dashboard uses these; the app may too)
    ui.on_message("water", lambda _client, _data=None: water())
    ui.on_message("stop", lambda _client, _data=None: stop())


def push_telemetry(ui, ctx):
    """Push a live snapshot to connected dashboard/app clients."""
    snap = ctx.hardware.snapshot()
    snap["soil_pct"] = ctx.config.soil_raw_to_pct(snap.get("soil_raw", -1))
    ui.send_message("telemetry", {
        "status": snap,
        "plan": ctx.current_plan.to_dict() if ctx.current_plan else None,
        "weather": ctx.current_weather.to_dict() if ctx.current_weather else None,
    })
