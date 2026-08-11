"""Deterministic expansion of iCalendar recurrence rules."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from hashlib import sha256
from typing import Optional

from dateutil.rrule import rrule, rruleset, rrulestr

from .models import Item


def parse_recurrence_datetime(value: str, fallback_timezone) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        parsed = parsed.replace(tzinfo=fallback_timezone)
    return parsed


def expand_item(
    item: Item,
    *,
    from_at: Optional[datetime],
    to_at: Optional[datetime],
    max_occurrences: int = 1000,
) -> list[Item]:
    """Return stable read-only occurrence views for one recurring Event."""
    if item.recurrence is None or item.start_at is None:
        return [item]
    if from_at is None:
        from_at = item.start_at - timedelta(days=365)
    if to_at is None:
        to_at = from_at + timedelta(days=730)
    if from_at.tzinfo is None or from_at.utcoffset() is None:
        raise ValueError("Recurrence range must include a timezone")
    if to_at.tzinfo is None or to_at.utcoffset() is None:
        raise ValueError("Recurrence range must include a timezone")
    if to_at < from_at:
        raise ValueError("Recurrence range cannot be reversed")

    recurrence = rruleset()
    if item.recurrence.rrule:
        recurrence.rrule(rrulestr(item.recurrence.rrule, dtstart=item.start_at))
    else:
        recurrence.rdate(item.start_at)
    fallback_timezone = item.start_at.tzinfo or timezone.utc
    for value in item.recurrence.exdates:
        recurrence.exdate(parse_recurrence_datetime(value, fallback_timezone))
    for value in item.recurrence.rdates:
        recurrence.rdate(parse_recurrence_datetime(value, fallback_timezone))

    duration = (item.end_at - item.start_at) if item.end_at else None
    occurrences: list[Item] = []
    for start_at in recurrence.between(from_at, to_at, inc=True):
        if len(occurrences) >= max_occurrences:
            break
        occurrence_key = start_at.isoformat()
        occurrence_id = f"{item.id}:occ:{sha256(occurrence_key.encode()).hexdigest()[:16]}"
        occurrence = Item.from_dict(item.to_dict())
        occurrence.id = occurrence_id
        occurrence.start_at = start_at
        occurrence.end_at = start_at + duration if duration else None
        occurrence.recurrence = None
        occurrence.metadata = {
            **item.metadata,
            "recurrence_master_id": item.id,
            "recurrence_occurrence": occurrence_key,
        }
        if occurrence.source_ref is not None:
            occurrence.source_ref.external_id = (
                f"{item.source_ref.external_id}#{occurrence_key}"
                if item.source_ref.external_id
                else occurrence_key
            )
        occurrences.append(occurrence)
    return occurrences
