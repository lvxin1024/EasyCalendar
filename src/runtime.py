"""Lazy composition root for local application services."""

from __future__ import annotations

import threading
from typing import Optional

from config.loader import Settings
from src.application import (
    CandidateService,
    ImportExportService,
    ItemService,
    NotificationSchedulerPort,
    ReminderService,
    SubscriptionService,
    SubscriptionRefreshService,
)
from src.notification import InMemoryNotificationScheduler
from src.parser.rule_adapter import RuleParserAdapter
from src.storage import SQLiteRepository
from src.widget import FileWidgetSnapshotWriter, WidgetSnapshotService


class RuntimeServices:
    """Own lazily initialized adapters without import-time filesystem writes."""

    def __init__(
        self,
        settings: Settings,
        *,
        repository: Optional[SQLiteRepository] = None,
        notification_scheduler: Optional[NotificationSchedulerPort] = None,
    ):
        self.settings = settings
        self._repository = repository
        self._owns_repository = repository is None
        self._item_service: Optional[ItemService] = None
        self._candidate_service: Optional[CandidateService] = None
        self._import_export_service: Optional[ImportExportService] = None
        self._notification_scheduler = notification_scheduler
        self._reminder_service: Optional[ReminderService] = None
        self._subscription_service: Optional[SubscriptionService] = None
        self._refresh_service: Optional[SubscriptionRefreshService] = None
        self._widget_service: Optional[WidgetSnapshotService] = None
        self._lock = threading.RLock()

    def item_service(self) -> ItemService:
        with self._lock:
            if self._item_service is not None:
                return self._item_service
            repository = self._repository_instance()
            service = ItemService(
                repository,
                device_id=self.settings.app.instance_name,
                reminder_coordinator=self.reminder_service(),
                widget_snapshot_callback=(
                    self._refresh_widget_snapshot
                    if self.settings.widget.enabled
                    else None
                ),
            )
            service.ensure_default_collection(
                collection_id=self.settings.app.default_collection_id,
                name=self.settings.app.default_collection_name,
                color=self.settings.app.default_collection_color,
            )
            self._item_service = service
            if self.settings.widget.enabled:
                self._refresh_widget_snapshot()
            return service

    def widget_snapshot_service(self) -> Optional[WidgetSnapshotService]:
        with self._lock:
            if not self.settings.widget.enabled:
                return None
            if self._widget_service is None:
                self._widget_service = WidgetSnapshotService(
                    self._repository_instance(),
                    FileWidgetSnapshotWriter(self.settings.widget.snapshot_path),
                    timezone_name=self.settings.app.timezone,
                )
            return self._widget_service

    def _refresh_widget_snapshot(self) -> None:
        service = self.widget_snapshot_service()
        if service is not None:
            service.refresh()

    def reminder_service(self) -> ReminderService:
        with self._lock:
            if self._reminder_service is not None:
                return self._reminder_service
            service = ReminderService(
                self._repository_instance(),
                self.notification_scheduler(),
                enabled=self.settings.notifications.enabled,
            )
            if self.settings.notifications.restore_on_start:
                service.restore()
            self._reminder_service = service
            return service

    def notification_scheduler(self) -> NotificationSchedulerPort:
        with self._lock:
            if self._notification_scheduler is None:
                if self.settings.notifications.adapter != "memory":
                    raise ValueError(
                        "Unsupported notification adapter: "
                        f"{self.settings.notifications.adapter}"
                    )
                self._notification_scheduler = InMemoryNotificationScheduler()
            return self._notification_scheduler

    def candidate_service(self) -> CandidateService:
        with self._lock:
            if self._candidate_service is not None:
                return self._candidate_service
            item_service = self.item_service()
            if self._repository is None:
                raise RuntimeError("Repository initialization did not complete")
            self._candidate_service = CandidateService(
                self._repository,
                item_service,
                RuleParserAdapter(),
                max_input_chars=self.settings.assistant.max_input_chars,
            )
            return self._candidate_service

    def import_export_service(self) -> ImportExportService:
        with self._lock:
            if self._import_export_service is not None:
                return self._import_export_service
            self.item_service()
            self._import_export_service = ImportExportService(
                self._repository_instance(),
                device_id=self.settings.app.instance_name,
                timezone_name=self.settings.app.timezone,
                default_collection_id=self.settings.app.default_collection_id,
                max_import_bytes=self.settings.transfer.max_import_bytes,
            )
            return self._import_export_service

    def subscription_service(self) -> SubscriptionService:
        with self._lock:
            if self._subscription_service is None:
                self._subscription_service = SubscriptionService(
                    self._repository_instance(),
                    device_id=self.settings.app.instance_name,
                )
            return self._subscription_service

    def refresh_service(self) -> SubscriptionRefreshService:
        with self._lock:
            if self._refresh_service is None:
                self._refresh_service = SubscriptionRefreshService(
                    self._repository_instance(),
                    device_id=self.settings.app.instance_name,
                    timezone_name=self.settings.app.timezone,
                    timeout_seconds=self.settings.subscriptions.request_timeout_seconds,
                )
            return self._refresh_service

    def close(self) -> None:
        with self._lock:
            if self._owns_repository and self._repository is not None:
                self._repository.close()
            self._repository = None
            self._item_service = None
            self._candidate_service = None
            self._import_export_service = None
            self._subscription_service = None
            self._refresh_service = None
            self._reminder_service = None
            self._widget_service = None
            self._notification_scheduler = None

    def _repository_instance(self) -> SQLiteRepository:
        if self._repository is None:
            self._repository = SQLiteRepository.from_settings(self.settings)
        return self._repository
