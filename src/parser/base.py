"""Base parser interface."""

from abc import ABC, abstractmethod
from typing import List
from .models import ParsedSchedule


class BaseParser(ABC):
    """Abstract base class for text parsers."""

    @abstractmethod
    def parse(self, text: str) -> ParsedSchedule:
        """Parse text into calendar events.

        Args:
            text: Input text containing event information

        Returns:
            ParsedSchedule containing extracted events
        """
        pass

    @abstractmethod
    def parse_multiple(self, texts: List[str]) -> List[ParsedSchedule]:
        """Parse multiple text segments into calendar events.

        Args:
            texts: List of input texts

        Returns:
            List of ParsedSchedule objects
        """
        pass
