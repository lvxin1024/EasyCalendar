"""Utility functions for date handling."""

from datetime import datetime, timedelta
from typing import Optional, Tuple


def get_weekday_name(weekday: int, lang: str = "zh") -> str:
    """Get weekday name."""
    zh_names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    en_names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    names = zh_names if lang == "zh" else en_names
    return names[weekday % 7]


def parse_time_range(time_str: str) -> Optional[Tuple[int, int]]:
    """Parse time range like '9:00-10:00'."""
    try:
        if "-" in time_str:
            start, end = time_str.split("-")
            start_hour, start_min = map(int, start.strip().split(":"))
            end_hour, end_min = map(int, end.strip().split(":"))
            return (start_hour * 60 + start_min, end_hour * 60 + end_min)
    except Exception:
        return None
    return None


def format_duration(minutes: int, lang: str = "zh") -> str:
    """Format duration in human readable format."""
    if lang == "zh":
        if minutes < 60:
            return f"{minutes}分钟"
        elif minutes % 60 == 0:
            return f"{minutes // 60}小时"
        else:
            return f"{minutes // 60}小时{minutes % 60}分钟"
    else:
        if minutes < 60:
            return f"{minutes} min"
        elif minutes % 60 == 0:
            return f"{minutes // 60} hr"
        else:
            return f"{minutes // 60} hr {minutes % 60} min"


def normalize_datetime(dt: Optional[datetime], timezone: str = "Asia/Shanghai") -> Optional[datetime]:
    """Normalize datetime to specified timezone."""
    if not dt:
        return None

    if dt.tzinfo is None:
        from datetime import timezone as tz
        return dt.replace(tzinfo=tz(timedelta(hours=8)))

    return dt


def get_date_range(days: int = 7) -> Tuple[datetime, datetime]:
    """Get date range from today."""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    end_date = today + timedelta(days=days)
    return today, end_date
