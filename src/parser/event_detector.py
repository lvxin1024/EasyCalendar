"""Event type detection utilities."""

import re
from typing import List, Optional
from .models import EventPriority, RecurrenceType


class EventDetector:
    """Detects event types and attributes from text."""

    EVENT_TYPE_PATTERNS = {
        "meeting": [
            r"开会",
            r"会议",
            r"会面",
            r"meeting",
            r"conference",
        ],
        "appointment": [
            r"预约",
            r"挂号",
            r"看医生",
            r"doctor",
            r"appointment",
        ],
        "reminder": [
            r"提醒",
            r"记得",
            r"别忘了",
            r"remind",
        ],
        "deadline": [
            r"截止",
            r"截止日期",
            r"deadline",
            r"最后期限",
            r"due",
        ],
        "task": [
            r"待办",
            r"任务",
            r"提交",
            r"交上",
            r"完成",
            r"前交",
            r"之前完成",
        ],
        "birthday": [
            r"生日",
            r"birthday",
        ],
        "travel": [
            r"出差",
            r"旅行",
            r"flight",
            r"航班",
            r"trip",
        ],
        "class": [
            r"上课",
            r"课程",
            r"class",
            r"lecture",
            r"seminar",
        ],
    }

    PRIORITY_PATTERNS = {
        EventPriority.HIGH: [
            r"紧急",
            r"重要",
            r"urgent",
            r"important",
            r"critical",
            r"优先级高",
        ],
        EventPriority.LOW: [
            r"次要",
            r"不重要",
            r"low priority",
            r"optional",
        ],
    }

    RECURRENCE_PATTERNS = {
        RecurrenceType.DAILY: [
            r"每天",
            r"每日",
            r"daily",
            r"every day",
        ],
        RecurrenceType.WEEKLY: [
            r"每周",
            r"每周一次",
            r"weekly",
            r"every week",
        ],
        RecurrenceType.MONTHLY: [
            r"每月",
            r"每月一次",
            r"monthly",
            r"every month",
        ],
        RecurrenceType.YEARLY: [
            r"每年",
            r"每年一次",
            r"yearly",
            r"annually",
            r"every year",
        ],
    }

    DURATION_PATTERNS = {
        r"半小时": 30,
        r"一小时": 60,
        r"一个半小时": 90,
        r"两小时": 120,
        r"半天": 240,
        r"一天": 480,
        r"30分钟": 30,
        r"1小时": 60,
        r"2小时": 120,
    }

    def detect_event_type(self, text: str) -> str:
        """Detect the type of event."""
        for event_type, patterns in self.EVENT_TYPE_PATTERNS.items():
            if any(re.search(p, text) for p in patterns):
                return event_type
        return "general"

    def detect_priority(self, text: str) -> EventPriority:
        """Detect event priority."""
        for priority, patterns in self.PRIORITY_PATTERNS.items():
            if any(re.search(p, text) for p in patterns):
                return priority
        return EventPriority.NORMAL

    def detect_recurrence(self, text: str) -> RecurrenceType:
        """Detect recurrence pattern."""
        for recurrence, patterns in self.RECURRENCE_PATTERNS.items():
            if any(re.search(p, text) for p in patterns):
                return recurrence
        return RecurrenceType.NONE

    def detect_duration(self, text: str) -> int:
        """Detect event duration in minutes."""
        for pattern, minutes in self.DURATION_PATTERNS.items():
            if pattern in text:
                return minutes

        duration_match = re.search(r"(\d+)\s*(?:分钟|小时|min|h)", text)
        if duration_match:
            value = int(duration_match.group(1))
            if "小时" in text or "h" in text.lower():
                return value * 60
            return value

        return 60

    def detect_location(self, text: str) -> Optional[str]:
        """Extract location from text."""
        patterns = [
            r"在([^，,，\s]+(?:会议室|办公室|地点|咖啡厅|餐厅|酒店|机场|车站))",
            r"地点[:：]\s*([^\s，,]+)",
            r"地址[:：]\s*([^\s，,]+)",
            r"at\s+([A-Za-z0-9\s]+)",
            r"@([^\s，,]+)",
        ]

        for pattern in patterns:
            match = re.search(pattern, text)
            if match:
                return match.group(1).strip()
        return None

    def detect_attendees(self, text: str) -> List[str]:
        """Extract attendees from text."""
        attendees = []

        patterns = [
            r"(?:和|与|with)\s*([^\s，,，]+(?:先生|女士|老师|经理|总监))",
            r"参加人[:：]\s*([^\s，,]+)",
            r"参会人[:：]\s*([^\s，,]+)",
            r"(?:@|at)\s*([a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)",
        ]

        for pattern in patterns:
            matches = re.finditer(pattern, text)
            for match in matches:
                attendees.append(match.group(1).strip())

        return attendees

    def extract_title(self, text: str) -> str:
        """Extract event title from text."""
        text = re.sub(r"\d{4}[年/-]\d{1,2}[月/-]\d{1,2}[日]?", "", text)
        text = re.sub(r"\d{1,2}[:：]\d{2}", "", text)
        text = re.sub(r"(?:上午|下午|早上|晚上|中午)\d{1,2}(?:点|时)?", "", text)

        keywords = ["开会", "会议", "讨论", "约会", "拜访", "上课", "培训"]
        for keyword in keywords:
            if keyword in text:
                idx = text.find(keyword)
                return text[: idx + len(keyword)].strip()

        lines = text.split("\n")
        if lines:
            return lines[0].strip()[:100]

        return text.strip()[:100] if text.strip() else "Untitled Event"
