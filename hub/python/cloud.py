"""Cloud sync seam — intentionally empty for now.

The system is local-first: SQLite is the source of truth and the mobile app
talks to the hub over the LAN. When remote access is needed again, implement
CloudSync against this interface and swap it in at the composition root
(main.py). Nothing else in the codebase should know or care whether a cloud
is attached.

Design notes for the future implementation:
  - The document shapes emitted by store.py already mirror the old Firestore
    collections (water_history, system_logs), so a Firebase sync is a field-
    for-field mapping. The `synced` column in both tables is the outbox flag:
    push rows where synced=0, mark them on ack, and the sync survives
    restarts and offline periods for free.
  - Auth pattern (email/password → Firestore REST) already exists in
    plant_water_data/fetch_logs.py in the previous repo; lift it from there.
  - Push notifications previously hooked Firestore document creation via
    Cloud Functions; recreating the water_history documents re-enables them
    unchanged.
"""

from typing import Protocol


class CloudSync(Protocol):
    def push_watering_event(self, doc: dict) -> None: ...
    def push_log(self, doc: dict) -> None: ...
    def push_health(self, doc: dict) -> None: ...


class NullSync:
    """The no-op sync used while the system is local-only."""

    def push_watering_event(self, doc: dict) -> None:
        pass

    def push_log(self, doc: dict) -> None:
        pass

    def push_health(self, doc: dict) -> None:
        pass
