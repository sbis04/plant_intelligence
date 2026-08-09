"""Board vitals — CPU load, memory, storage, SoC temperature.

Read straight from /proc and /sys, which the app container shares with the
host kernel, so these are true board-level numbers (the same ones App Lab
shows in its status bar). No dependencies.
"""

import os
import shutil


def _read(path: str) -> str:
    with open(path) as f:
        return f.read()


def cpu_percent() -> float:
    """1-minute load average scaled by core count — a stable, honest
    utilisation figure without needing to keep sampling state."""
    load1 = float(_read("/proc/loadavg").split()[0])
    cores = os.cpu_count() or 1
    return round(min(100.0, load1 / cores * 100.0), 1)


def memory() -> dict:
    total = available = 0
    for line in _read("/proc/meminfo").splitlines():
        if line.startswith("MemTotal:"):
            total = int(line.split()[1]) * 1024
        elif line.startswith("MemAvailable:"):
            available = int(line.split()[1]) * 1024
    return {"total_bytes": total, "used_bytes": total - available}


def storage() -> dict:
    root = shutil.disk_usage("/")
    out = {"root_total_bytes": root.total, "root_used_bytes": root.used}
    try:
        app = shutil.disk_usage("/app")
        out["data_total_bytes"] = app.total
        out["data_used_bytes"] = app.used
    except OSError:
        pass
    return out


def soc_temperature_c():
    """Hottest thermal zone — the number that matters for throttling."""
    best = None
    base = "/sys/class/thermal"
    try:
        for zone in os.listdir(base):
            if not zone.startswith("thermal_zone"):
                continue
            try:
                milli = int(_read(f"{base}/{zone}/temp").strip())
            except (OSError, ValueError):
                continue
            if 1000 < milli < 150000:   # sanity: 1–150 °C
                c = milli / 1000.0
                best = c if best is None else max(best, c)
    except OSError:
        return None
    return round(best, 1) if best is not None else None


def snapshot() -> dict:
    try:
        return {
            "cpu_percent": cpu_percent(),
            "memory": memory(),
            "storage": storage(),
            "soc_temperature_c": soc_temperature_c(),
        }
    except Exception as e:
        return {"error": str(e)}
