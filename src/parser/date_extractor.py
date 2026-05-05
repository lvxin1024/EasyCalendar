"""Date and time extraction utilities."""

import re
from datetime import datetime, timedelta
from typing import Optional, Tuple, Dict


class DateExtractor:
    """Extracts and normalizes dates and times from text."""

    TODAY_PATTERNS = [
        r"今天",
        r"今日",
        r"本日",
    ]

    TOMORROW_PATTERNS = [
        r"明天",
        r"明日",
        r"次日",
    ]

    WEEKDAY_PATTERNS = {
        r"周一|星期一|礼拜一": 0,
        r"周二|星期二|礼拜二": 1,
        r"周三|星期三|礼拜三": 2,
        r"周四|星期四|礼拜四": 3,
        r"周五|星期五|礼拜五": 4,
        r"周六|星期六|礼拜六": 5,
        r"周日|星期日|礼拜天|礼拜日|星期天": 6,
    }

    TIME_PATTERNS = [
        r"(\d{1,2})[:：](\d{2})(?:\s*点|时)?",
        r"(\d{1,2})(?:\s*)(?:点|时)(?:\s*)(\d{1,2})?(?:\s*分)?",
        r"上午(\d{1,2})(?::(\d{2}))?(?:点|时)?",
        r"下午(\d{1,2})(?::(\d{2}))?(?:点|时)?",
        r"早上(\d{1,2})(?::(\d{2}))?(?:点|时)?",
        r"晚上(\d{1,2})(?::(\d{2}))?(?:点|时)?",
        r"中午(\d{1,2})(?::(\d{2}))?(?:点|时)?",
    ]

    DURATION_PATTERNS = [
        r"(\d+)\s*小时",
        r"(\d+)\s*分钟",
        r"(\d+)\s*min",
        r"(\d+)\s*h",
    ]

    def __init__(self, reference_date: Optional[datetime] = None):
        self.reference_date = reference_date or datetime.now()

    def extract_date(self, text: str) -> Optional[datetime]:
        """Extract date from text."""
        date = self._extract_relative_date(text)
        if date:
            return date

        date = self._extract_weekday_date(text)
        if date:
            return date

        date = self._extract_explicit_date(text)
        return date

    def _extract_relative_date(self, text: str) -> Optional[datetime]:
        """Extract relative dates like 'today', 'tomorrow'."""
        if any(re.search(p, text) for p in self.TODAY_PATTERNS):
            return self.reference_date.replace(hour=0, minute=0, second=0, microsecond=0)

        if any(re.search(p, text) for p in self.TOMORROW_PATTERNS):
            return (self.reference_date + timedelta(days=1)).replace(
                hour=0, minute=0, second=0, microsecond=0
            )

        match = re.search(r"(\d+)\s*天后?", text)
        if match:
            days = int(match.group(1))
            return (self.reference_date + timedelta(days=days)).replace(
                hour=0, minute=0, second=0, microsecond=0
            )

        return None

    def _extract_weekday_date(self, text: str) -> Optional[datetime]:
        """Extract weekday-based dates."""
        for pattern, weekday in self.WEEKDAY_PATTERNS.items():
            if re.search(pattern, text):
                current_weekday = self.reference_date.weekday()
                days_ahead = (weekday - current_weekday) % 7
                if days_ahead == 0:
                    days_ahead = 7
                return (self.reference_date + timedelta(days=days_ahead)).replace(
                    hour=0, minute=0, second=0, microsecond=0
                )
        return None

    def _extract_explicit_date(self, text: str) -> Optional[datetime]:
        """Extract explicit date patterns."""
        patterns = [
            r"(\d{4})[年/-](\d{1,2})[月/-](\d{1,2})日?",
            r"(\d{4})[年/-](\d{1,2})[月/-](\d{1,2})",
            r"(\d{2})[年/-](\d{1,2})[月/-](\d{1,2})日?",
        ]

        for pattern in patterns:
            match = re.search(pattern, text)
            if match:
                groups = match.groups()
                if len(groups[0]) == 4:
                    year, month, day = int(groups[0]), int(groups[1]), int(groups[2])
                else:
                    year = self.reference_date.year
                    month, day = int(groups[1]), int(groups[2])

                return self.reference_date.replace(
                    year=year, month=month, day=day, hour=0, minute=0, second=0, microsecond=0
                )
        return None

    def extract_time(self, text: str) -> Optional[Tuple[int, int]]:
        """Extract time from text."""
        for pattern in self.TIME_PATTERNS:
            match = re.search(pattern, text)
            if match:
                groups = match.groups()
                if "上午" in text or "早上" in text or "中午" in text:
                    if "下午" not in text and "晚上" not in text:
                        hour = int(groups[0])
                        minute = int(groups[1]) if groups[1] else 0
                        if hour == 12:
                            hour = 0
                elif "下午" in text or "晚上" in text:
                    hour = int(groups[0])
                    minute = int(groups[1]) if groups[1] else 0
                    if hour != 12:
                        hour += 12
                elif "中午" in text:
                    hour = int(groups[0]) if groups[0] else 12
                    minute = int(groups[1]) if groups[1] else 0
                    if hour < 12:
                        hour += 12
                else:
                    if len(groups) >= 2 and groups[1]:
                        hour, minute = int(groups[0]), int(groups[1])
                    else:
                        hour, minute = int(groups[0]), int(groups[2]) if len(groups) > 2 and groups[2] else 0

                return (hour, minute)

        return None

    def extract_duration(self, text: str) -> Optional[int]:
        """Extract duration in minutes."""
        for pattern in self.DURATION_PATTERNS:
            match = re.search(pattern, text)
            if match:
                value = int(match.group(1))
                if "小时" in pattern or pattern.startswith(r"(\d+)\s*h"):
                    return value * 60
                return value
        return None

    def combine_date_time(
        self, date: Optional[datetime], time: Optional[Tuple[int, int]]
    ) -> Optional[datetime]:
        """Combine extracted date and time."""
        if not date and not time:
            return None

        result = (date or self.reference_date).replace(hour=0, minute=0, second=0, microsecond=0)

        if time:
            result = result.replace(hour=time[0], minute=time[1])

        return result
