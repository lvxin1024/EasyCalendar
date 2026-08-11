"""Replaceable AI providers with bounded transport and strict candidate output."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Mapping, Optional, Protocol
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from config.loader import Settings
from src.domain import CandidateItem
from src.parser.rule_adapter import RuleParserAdapter

from .candidate_service import CandidateParseResult


class ProviderError(RuntimeError):
    """A safe, structured provider failure that never includes credentials."""

    def __init__(self, code: str, message: str, *, retryable: bool = False, details: Optional[Mapping[str, Any]] = None):
        self.code = code
        self.retryable = retryable
        self.details = dict(details or {})
        super().__init__(message)


class CandidateProviderPort(Protocol):
    provider_id: str

    def extract(self, text: str, *, now: datetime, timezone_name: str) -> CandidateParseResult: ...


def _candidate_prompt(text: str, timezone_name: str, now: datetime) -> str:
    return (
        "Return JSON only with this shape: {\"candidates\":[candidate objects],\"warnings\":[string]}. "
        "Each candidate must contain temp_id, type (event|task|note), title, confidence (0..1), "
        "and timezone. Event uses start_at/end_at, task uses due_at. Include source_text_span with "
        "character start/end when possible. Do not create or modify persisted items.\n"
        f"Timezone: {timezone_name}\nReference time: {now.isoformat()}\nInput: {text}"
    )


def decode_candidate_response(payload: Any, *, timezone_name: str) -> CandidateParseResult:
    """Validate the complete provider response before it reaches CandidateService."""
    if isinstance(payload, list):
        raw_candidates, warnings = payload, []
    elif isinstance(payload, dict):
        raw_candidates = payload.get("candidates")
        warnings = payload.get("warnings", [])
        if not isinstance(raw_candidates, list):
            raise ProviderError("invalid_provider_response", "Provider JSON must contain a candidates array")
        if not isinstance(warnings, list) or not all(isinstance(value, str) for value in warnings):
            raise ProviderError("invalid_provider_response", "Provider warnings must be an array of strings")
    else:
        raise ProviderError("invalid_provider_response", "Provider JSON root must be an object or array")

    candidates: list[CandidateItem] = []
    errors: list[dict[str, Any]] = []
    for index, raw in enumerate(raw_candidates):
        if not isinstance(raw, dict):
            errors.append({"index": index, "message": "candidate must be an object"})
            continue
        candidate_data = dict(raw)
        candidate_data.setdefault("timezone", timezone_name)
        try:
            candidate = CandidateItem.from_dict(candidate_data)
            if candidate.type.value == "event" and candidate.start_at is None:
                raise ValueError("Event candidate requires start_at")
            if candidate.type.value == "task" and candidate.due_at is None:
                raise ValueError("Task candidate requires due_at")
            candidates.append(candidate)
        except (TypeError, ValueError) as error:
            errors.append({"index": index, "message": str(error)[:240]})
    if errors:
        raise ProviderError("invalid_provider_response", "Provider returned invalid candidate objects", details={"candidates": errors})
    return CandidateParseResult(parser_id="ai.structured", candidates=candidates, warnings=list(warnings))


@dataclass
class _JsonHttpProvider:
    base_url: str
    model: str
    api_key: Optional[str]
    timeout_seconds: int = 45
    max_response_bytes: int = 2_000_000
    retry_limit: int = 2
    requester: Optional[Callable[..., Any]] = None

    def _post(self, endpoint: str, payload: Mapping[str, Any]) -> Any:
        url = self.base_url.rstrip("/") + endpoint
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        request = Request(url, data=body, headers=headers, method="POST")
        request_fn = self.requester or urlopen
        last_error: Optional[Exception] = None
        for attempt in range(self.retry_limit + 1):
            try:
                with request_fn(request, timeout=self.timeout_seconds) as response:
                    raw = response.read(self.max_response_bytes + 1)
                    status = getattr(response, "status", 200)
                if len(raw) > self.max_response_bytes:
                    raise ProviderError("provider_response_too_large", "Provider response exceeds the configured size limit")
                if status < 200 or status >= 300:
                    raise ProviderError("provider_http_error", f"Provider returned HTTP {status}", retryable=status in {408, 429} or status >= 500)
                try:
                    return json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise ProviderError("invalid_provider_response", "Provider response is not valid JSON") from error
            except ProviderError as error:
                if not error.retryable or attempt >= self.retry_limit:
                    raise
                last_error = error
            except (TimeoutError, URLError, HTTPError, OSError) as error:
                if attempt >= self.retry_limit:
                    raise ProviderError("provider_unavailable", "Provider request failed after bounded retries", retryable=True) from error
                last_error = error
            time.sleep(min(0.25 * (2**attempt), 2.0))
        raise ProviderError("provider_unavailable", "Provider request failed", retryable=True) from last_error


class OpenAICompatibleProvider(_JsonHttpProvider):
    provider_id = "openai_compatible"

    def extract(self, text: str, *, now: datetime, timezone_name: str) -> CandidateParseResult:
        payload = self._post(
            "/chat/completions",
            {
                "model": self.model,
                "temperature": 0,
                "response_format": {"type": "json_object"},
                "messages": [{"role": "user", "content": _candidate_prompt(text, timezone_name, now)}],
            },
        )
        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as error:
            raise ProviderError("invalid_provider_response", "OpenAI-compatible response is missing message content") from error
        if not isinstance(content, str):
            raise ProviderError("invalid_provider_response", "OpenAI-compatible message content must be a string")
        return decode_candidate_response(_decode_json_content(content), timezone_name=timezone_name)


class OllamaProvider(_JsonHttpProvider):
    provider_id = "ollama"

    def extract(self, text: str, *, now: datetime, timezone_name: str) -> CandidateParseResult:
        payload = self._post(
            "/api/chat",
            {
                "model": self.model,
                "stream": False,
                "format": "json",
                "messages": [{"role": "user", "content": _candidate_prompt(text, timezone_name, now)}],
            },
        )
        try:
            content = payload["message"]["content"]
        except (KeyError, TypeError) as error:
            raise ProviderError("invalid_provider_response", "Ollama response is missing message content") from error
        if not isinstance(content, str):
            raise ProviderError("invalid_provider_response", "Ollama message content must be a string")
        return decode_candidate_response(_decode_json_content(content), timezone_name=timezone_name)


def _decode_json_content(content: str) -> Any:
    normalized = content.strip()
    if normalized.startswith("```"):
        normalized = normalized.removeprefix("```").removeprefix("json").removesuffix("```").strip()
    try:
        return json.loads(normalized)
    except json.JSONDecodeError as error:
        raise ProviderError("invalid_provider_response", "Provider message content is not valid JSON") from error


class ProviderRegistry:
    """Select one provider without allowing provider code to touch storage."""

    def __init__(self, settings: Settings, *, requester: Optional[Callable[..., Any]] = None):
        self.settings = settings
        self._requester = requester

    def active(self, parser_id: str) -> CandidateProviderPort:
        selected = self.settings.assistant.provider if parser_id == "auto" else parser_id
        if selected in {"rules", "rules.zh_cn"}:
            return RuleParserAdapter()
        if not self.settings.assistant.enabled:
            raise ProviderError("provider_disabled", "AI assistant is disabled")
        base_url = self.settings.assistant.base_url
        model = self.settings.assistant.model
        if not base_url or not model:
            raise ProviderError("provider_not_configured", "AI Provider base_url and model are required")
        if selected == "openai_compatible":
            return OpenAICompatibleProvider(
                base_url=base_url,
                model=model,
                api_key=self.settings.secrets.ai_api_key.get_secret_value() if self.settings.secrets.ai_api_key else None,
                timeout_seconds=self.settings.assistant.timeout_seconds,
                max_response_bytes=self.settings.assistant.max_response_bytes,
                retry_limit=self.settings.assistant.retry_limit,
                requester=self._requester,
            )
        if selected == "ollama":
            return OllamaProvider(
                base_url=base_url,
                model=model,
                api_key=None,
                timeout_seconds=self.settings.assistant.timeout_seconds,
                max_response_bytes=self.settings.assistant.max_response_bytes,
                retry_limit=self.settings.assistant.retry_limit,
                requester=self._requester,
            )
        raise ProviderError("provider_not_supported", f"Unsupported AI Provider: {selected}")

    def extract(self, text: str, *, now: datetime, timezone_name: str, parser_id: str = "auto") -> CandidateParseResult:
        provider = self.active(parser_id)
        result = provider.extract(text, now=now, timezone_name=timezone_name)
        return CandidateParseResult(parser_id=getattr(provider, "provider_id", "rules.zh_cn"), candidates=result.candidates, warnings=result.warnings)
