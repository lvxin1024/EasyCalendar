"""Application port adapter for the existing Chinese rule parser."""

from datetime import datetime

from src.application.candidate_service import CandidateParseResult
from src.domain import CandidateItem

from .rule_parser import RuleParser


class RuleParserAdapter:
    parser_id = "rules.zh_cn"

    def extract(
        self, text: str, *, now: datetime, timezone_name: str
    ) -> CandidateParseResult:
        result = RuleParser(now).parse(text)
        candidates = []
        for candidate in result.candidates:
            data = candidate.to_dict()
            data["timezone"] = timezone_name
            candidates.append(CandidateItem.from_dict(data))
        return CandidateParseResult(
            parser_id=self.parser_id,
            candidates=candidates,
            warnings=[],
        )
