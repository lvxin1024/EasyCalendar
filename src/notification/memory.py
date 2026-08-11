"""Deterministic process-local notification adapter for development and tests."""

from __future__ import annotations

import threading
from typing import Dict

from src.application.ports import NotificationRequest


class InMemoryNotificationScheduler:
    """Store schedules in memory without claiming to deliver OS notifications."""

    def __init__(self) -> None:
        self._scheduled: Dict[str, NotificationRequest] = {}
        self._lock = threading.RLock()

    @property
    def scheduled(self) -> Dict[str, NotificationRequest]:
        with self._lock:
            return dict(self._scheduled)

    def schedule(self, request: NotificationRequest) -> str:
        platform_id = f"memory:{request.notification_id}"
        with self._lock:
            self._scheduled[platform_id] = request
        return platform_id

    def cancel(self, platform_schedule_id: str) -> None:
        with self._lock:
            self._scheduled.pop(platform_schedule_id, None)
