"""Rule parser result types."""

from dataclasses import dataclass, field
from enum import Enum

from ..domain.models import CandidateItem


class EventPriority(Enum):
    LOW = 1
    NORMAL = 2
    HIGH = 3


class RecurrenceType(Enum):
    NONE = "none"
    DAILY = "daily"
    WEEKLY = "weekly"
    MONTHLY = "monthly"
    YEARLY = "yearly"


@dataclass
class ParsedSchedule:
    """Candidate-only output from the local rule parser."""

    original_text: str
    candidates: list[CandidateItem] = field(default_factory=list)
    confidence: float = 1.0
