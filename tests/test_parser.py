"""Unit tests for the parser module."""

import pytest
from datetime import datetime, timedelta
from src.parser.rule_parser import RuleParser
from src.parser.date_extractor import DateExtractor
from src.parser.event_detector import EventDetector
from src.parser.models import EventPriority


class TestDateExtractor:
    """Test cases for DateExtractor."""

    def setup_method(self):
        """Setup test fixtures."""
        self.reference_date = datetime(2024, 3, 15, 10, 0, 0)
        self.extractor = DateExtractor(self.reference_date)

    def test_extract_today(self):
        """Test extracting 'today'."""
        date = self.extractor.extract_date("今天开会")
        assert date is not None
        assert date.date() == self.reference_date.date()

    def test_extract_tomorrow(self):
        """Test extracting 'tomorrow'."""
        date = self.extractor.extract_date("明天上午9点")
        assert date is not None
        expected_date = self.reference_date.date() + timedelta(days=1)
        assert date.date() == expected_date

    def test_extract_explicit_date(self):
        """Test extracting explicit date."""
        date = self.extractor.extract_date("2024年3月20日开会")
        assert date is not None
        assert date.year == 2024
        assert date.month == 3
        assert date.day == 20

    def test_extract_time(self):
        """Test extracting time."""
        time_tuple = self.extractor.extract_time("上午9:30开会")
        assert time_tuple is not None
        assert time_tuple[0] == 9
        assert time_tuple[1] == 30

    def test_extract_time_pm(self):
        """Test extracting PM time."""
        time_tuple = self.extractor.extract_time("下午3点")
        assert time_tuple is not None
        assert time_tuple[0] == 15

    def test_extract_no_time(self):
        """Test extracting when no time present."""
        time_tuple = self.extractor.extract_time("今天开会讨论")
        assert time_tuple is None


class TestEventDetector:
    """Test cases for EventDetector."""

    def setup_method(self):
        """Setup test fixtures."""
        self.detector = EventDetector()

    def test_detect_meeting(self):
        """Test detecting meeting event."""
        event_type = self.detector.detect_event_type("明天上午9点开会讨论项目")
        assert event_type == "meeting"

    def test_detect_reminder(self):
        """Test detecting reminder."""
        event_type = self.detector.detect_event_type("记得明天给客户打电话")
        assert event_type == "reminder"

    def test_detect_deadline(self):
        """Test detecting deadline."""
        event_type = self.detector.detect_event_type("项目截止日期是周五")
        assert event_type == "deadline"

    def test_detect_priority_high(self):
        """Test detecting high priority."""
        priority = self.detector.detect_priority("紧急会议")
        assert priority == EventPriority.HIGH

    def test_detect_duration_explicit(self):
        """Test detecting explicit duration."""
        duration = self.detector.detect_duration("会议持续2小时")
        assert duration == 120

    def test_extract_location(self):
        """Test extracting location."""
        location = self.detector.detect_location("在A栋会议室开会")
        assert location is not None

    def test_extract_title(self):
        """Test extracting title."""
        title = self.detector.extract_title("明天上午9点在会议室开会讨论")
        assert "开会" in title or "会议" in title


class TestRuleParser:
    """Test cases for RuleParser."""

    def setup_method(self):
        """Setup test fixtures."""
        self.reference_date = datetime(2024, 3, 15, 10, 0, 0)
        self.parser = RuleParser(self.reference_date)

    def test_parse_simple_event(self):
        """Test parsing simple event."""
        text = "明天上午9点开会"
        result = self.parser.parse(text)

        assert len(result.candidates) >= 1
        assert not hasattr(result, "events")
        candidate = result.candidates[0]
        assert "开会" in candidate.title or "会议" in candidate.title
        assert candidate.start_at is not None

    def test_parse_event_with_date(self):
        """Test parsing event with explicit date."""
        text = "2024年3月20日下午2点在会议室开会"
        result = self.parser.parse(text)

        assert len(result.candidates) >= 1
        candidate = result.candidates[0]
        assert candidate.start_at.year == 2024
        assert candidate.start_at.month == 3
        assert candidate.start_at.day == 20

    def test_parse_multiple_events(self):
        """Test parsing multiple events."""
        text = "明天上午9点开会, 然后下午3点讨论项目"
        result = self.parser.parse(text)

        assert len(result.candidates) >= 2

    def test_parse_empty_text(self):
        """Test parsing empty text."""
        result = self.parser.parse("")
        assert len(result.candidates) == 0

    def test_parse_event_duration(self):
        """Test that parsed events have proper duration."""
        text = "今天下午2点到4点开会"
        result = self.parser.parse(text)

        assert len(result.candidates) >= 1
        candidate = result.candidates[0]
        assert candidate.end_at > candidate.start_at

    def test_parse_multiple_texts(self):
        """Test parsing multiple texts."""
        texts = [
            "明天上午9点开会",
            "下周三下午2点讨论项目"
        ]
        results = self.parser.parse_multiple(texts)

        assert len(results) == 2
        assert all(len(r.candidates) >= 1 for r in results)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
