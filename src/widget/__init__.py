"""Widget snapshot adapters for local, read-only consumers."""

from .snapshot import (
    FileWidgetSnapshotWriter,
    WidgetItem,
    WidgetSnapshot,
    WidgetSnapshotService,
    WidgetSnapshotWriter,
)

__all__ = [
    "FileWidgetSnapshotWriter",
    "WidgetItem",
    "WidgetSnapshot",
    "WidgetSnapshotService",
    "WidgetSnapshotWriter",
]
