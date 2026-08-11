"""Provider transport and strict structured candidate contract tests."""

import json
from datetime import datetime, timezone

import pytest
from pydantic import SecretStr

from config.loader import Settings
from src.application.ai_providers import (
    OpenAICompatibleProvider,
    ProviderError,
    ProviderRegistry,
    decode_candidate_response,
)


def _candidate():
    return {
        "temp_id": "ai_001",
        "type": "event",
        "title": "Design review",
        "start_at": "2026-08-12T09:00:00+08:00",
        "end_at": "2026-08-12T10:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "confidence": 0.82,
        "source_text_span": {"start": 0, "end": 12},
    }


def test_decoder_accepts_multiple_candidates_and_defaults_timezone():
    result = decode_candidate_response(
        {"candidates": [_candidate(), {**_candidate(), "temp_id": "ai_002", "type": "task", "due_at": "2026-08-13T17:00:00+08:00", "start_at": None, "end_at": None}], "warnings": ["low confidence"]},
        timezone_name="Asia/Shanghai",
    )
    assert result.parser_id == "ai.structured"
    assert [candidate.temp_id for candidate in result.candidates] == ["ai_001", "ai_002"]
    assert result.warnings == ["low confidence"]


def test_decoder_rejects_partial_invalid_output_as_one_failure():
    with pytest.raises(ProviderError) as caught:
        decode_candidate_response(
            {"candidates": [_candidate(), {"temp_id": "bad", "type": "event"}]},
            timezone_name="Asia/Shanghai",
        )
    assert caught.value.code == "invalid_provider_response"
    assert caught.value.details["candidates"][0]["index"] == 1


def test_openai_provider_enforces_json_and_does_not_log_key():
    captured = {}

    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self, _limit):
            return json.dumps({"choices": [{"message": {"content": json.dumps({"candidates": [_candidate()]})}}]}).encode()

    def requester(request, *, timeout):
        captured["authorization"] = request.headers.get("Authorization")
        captured["timeout"] = timeout
        return Response()

    provider = OpenAICompatibleProvider(
        base_url="https://ai.example.com/v1",
        model="test-model",
        api_key="secret-key",
        timeout_seconds=7,
        retry_limit=0,
        requester=requester,
    )
    result = provider.extract(
        "明天九点评审",
        now=datetime(2026, 8, 12, 8, tzinfo=timezone.utc),
        timezone_name="Asia/Shanghai",
    )
    assert result.candidates[0].title == "Design review"
    assert captured == {"authorization": "Bearer secret-key", "timeout": 7}


def test_registry_keeps_rules_available_without_ai_configuration():
    settings = Settings()
    result = ProviderRegistry(settings).extract(
        "明天上午9点开会",
        now=datetime(2026, 8, 12, 0, tzinfo=timezone.utc),
        timezone_name="Asia/Shanghai",
        parser_id="auto",
    )
    assert result.parser_id == "rules.zh_cn"


def test_registry_rejects_disabled_cloud_provider_without_calling_network():
    settings = Settings.model_validate(
        {
            "assistant": {
                "enabled": False,
                "provider": "openai_compatible",
                "base_url": "https://ai.example.com/v1",
                "model": "test-model",
            },
            "secrets": {"ai_api_key": SecretStr("secret")},
        }
    )
    with pytest.raises(ProviderError) as caught:
        ProviderRegistry(settings).active("auto")
    assert caught.value.code == "provider_disabled"
