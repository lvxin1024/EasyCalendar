"""Rule-based parser for extracting calendar events from text."""

import re
from datetime import datetime, timedelta
from typing import List, Optional
from .base import BaseParser
from .models import ParsedSchedule, EventPriority, RecurrenceType
from ..domain.models import CandidateItem, ItemType, RecurrenceRule, SourceTextSpan
from .date_extractor import DateExtractor
from .event_detector import EventDetector


class RuleParser(BaseParser):
    """Rule-based parser for extracting calendar events."""

    EVENT_SEPARATOR_PATTERNS = [
        r"[,，;；]\s*(?:然后|接着|之后|also|and then)",
        r"\n+",
        r"[,，]\s*(?=\d{1,2}[点时:：])",
    ]

    def __init__(self, reference_date: Optional[datetime] = None):
        self.date_extractor = DateExtractor(reference_date)
        self.event_detector = EventDetector()

    def parse(self, text: str) -> ParsedSchedule:
        """Parse text into calendar events."""
        segments = self._split_into_segments(text)
        candidates = []

        search_from = 0
        for index, segment in enumerate(segments, start=1):
            span_start = text.find(segment, search_from)
            if span_start < 0:
                span_start = search_from
            span = SourceTextSpan(span_start, span_start + len(segment))
            candidate = self._parse_segment(segment, index, span)
            if candidate:
                candidates.append(candidate)
            search_from = span.end

        return ParsedSchedule(
            original_text=text,
            candidates=candidates,
            confidence=len(candidates) / max(len(segments), 1) if segments else 0.0,
        )

    def parse_multiple(self, texts: List[str]) -> List[ParsedSchedule]:
        """Parse multiple text segments."""
        return [self.parse(text) for text in texts]

    def _split_into_segments(self, text: str) -> List[str]:
        """Split text into individual event segments."""
        segments = [text]

        for pattern in self.EVENT_SEPARATOR_PATTERNS:
            new_segments = []
            for segment in segments:
                parts = re.split(pattern, segment)
                new_segments.extend([p.strip() for p in parts if p.strip()])
            segments = new_segments

        return segments

    def _parse_segment(
        self, segment: str, index: int, source_span: SourceTextSpan
    ) -> Optional[CandidateItem]:
        """Parse a single text segment into an unconfirmed candidate."""
        date = self.date_extractor.extract_date(segment)
        time_tuple = self.date_extractor.extract_time(segment)

        start_time = self.date_extractor.combine_date_time(date, time_tuple)
        if not start_time:
            start_time = self.date_extractor.extract_date(segment)

        if not start_time:
            start_time = datetime.now().replace(hour=9, minute=0, second=0, microsecond=0)

        duration = self.event_detector.detect_duration(segment)
        end_time = start_time + timedelta(minutes=duration)

        title = self.event_detector.extract_title(segment)
        event_type = self.event_detector.detect_event_type(segment)
        priority = self.event_detector.detect_priority(segment)
        recurrence = self.event_detector.detect_recurrence(segment)
        location = self.event_detector.detect_location(segment)
        attendees = self.event_detector.detect_attendees(segment)

        description = self._extract_description(segment, title)

        is_task = event_type in {"deadline", "reminder", "task"}
        item_type = ItemType.TASK if is_task else ItemType.EVENT

        return CandidateItem(
            temp_id=f"cand_{index:03d}",
            type=item_type,
            title=title,
            body=description,
            start_at=None if is_task else start_time,
            end_at=None if is_task else end_time,
            due_at=start_time if is_task else None,
            location=location,
            attendees=attendees,
            timezone="Asia/Shanghai",
            confidence=0.8 if is_task else 0.9,
            reasoning=f"rule_parser:event_type={event_type}",
            source_text_span=source_span,
            priority=priority.value,
            recurrence=(
                RecurrenceRule(rrule=f"FREQ={recurrence.value.upper()}")
                if recurrence != RecurrenceType.NONE
                else None
            ),
        )

    def _extract_description(self, text: str, title: str) -> Optional[str]:
        """Extract description from text."""
        description = text.replace(title, "").strip()
        description = re.sub(r"^\d{4}[年/-]\d{1,2}[月/-]\d{1,2}[日]?\s*", "", description)
        description = re.sub(r"^\d{1,2}[:：]\d{2}\s*", "", description)

        return description if description else None
