"""Lazy composition root for local application services."""

from __future__ import annotations

import threading
from typing import Optional

from config.loader import Settings
from src.application import ItemService
from src.storage import SQLiteRepository


class RuntimeServices:
    """Own lazily initialized adapters without import-time filesystem writes."""

    def __init__(
        self,
        settings: Settings,
        *,
        repository: Optional[SQLiteRepository] = None,
    ):
        self.settings = settings
        self._repository = repository
        self._owns_repository = repository is None
        self._item_service: Optional[ItemService] = None
        self._lock = threading.RLock()

    def item_service(self) -> ItemService:
        with self._lock:
            if self._item_service is not None:
                return self._item_service
            if self._repository is None:
                self._repository = SQLiteRepository.from_settings(self.settings)
            service = ItemService(
                self._repository,
                device_id=self.settings.app.instance_name,
            )
            service.ensure_default_collection(
                collection_id=self.settings.app.default_collection_id,
                name=self.settings.app.default_collection_name,
                color=self.settings.app.default_collection_color,
            )
            self._item_service = service
            return service

    def close(self) -> None:
        with self._lock:
            if self._owns_repository and self._repository is not None:
                self._repository.close()
            self._repository = None
            self._item_service = None
