"""Base parser interface."""

from abc import ABC, abstractmethod
from .models import ParsedSchedule


class BaseParser(ABC):
    """Abstract base class for text parsers."""

    @abstractmethod
    def parse(self, text: str) -> ParsedSchedule:
        """Parse text into unconfirmed schedule candidates.

        Args:
            text: Input text containing schedule information

        Returns:
            ParsedSchedule containing extracted candidates
        """
        pass

    @abstractmethod
    def parse_multiple(self, texts: list[str]) -> list[ParsedSchedule]:
        """Parse multiple text segments into schedule candidates.

        Args:
            texts: Input texts

        Returns:
            Parsed results in input order
        """
        pass
