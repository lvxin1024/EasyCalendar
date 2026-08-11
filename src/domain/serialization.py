"""Strict JSON serialization for dependency-free domain models."""

from __future__ import annotations

import json
import math
from dataclasses import fields, is_dataclass
from datetime import datetime
from enum import Enum
from types import UnionType
from typing import (
    Any,
    ClassVar,
    Dict,
    Mapping,
    TypeVar,
    Union,
    get_args,
    get_origin,
    get_type_hints,
)


DOMAIN_SCHEMA_VERSION = 1

DomainModelT = TypeVar("DomainModelT", bound="SerializableDomainModel")


class SerializableDomainModel:
    """Mixin providing strict dictionaries and versioned JSON envelopes."""

    json_model: ClassVar[str]

    def to_dict(self) -> Dict[str, Any]:
        if not is_dataclass(self):
            raise TypeError("Serializable domain models must be dataclasses")
        return {
            model_field.name: _encode_value(getattr(self, model_field.name))
            for model_field in fields(self)
        }

    @classmethod
    def from_dict(cls: type[DomainModelT], data: Mapping[str, Any]) -> DomainModelT:
        if not isinstance(data, Mapping):
            raise ValueError(f"{cls.json_model} must be a JSON object")
        if not all(isinstance(key, str) for key in data):
            raise ValueError(f"{cls.json_model} field names must be strings")

        model_fields = {model_field.name: model_field for model_field in fields(cls)}
        unknown_fields = sorted(set(data) - set(model_fields))
        if unknown_fields:
            raise ValueError(
                f"Unknown {cls.json_model} fields: {', '.join(unknown_fields)}"
            )

        type_hints = get_type_hints(cls)
        values = {
            name: _decode_value(value, type_hints[name], f"{cls.json_model}.{name}")
            for name, value in data.items()
        }
        try:
            return cls(**values)
        except (TypeError, ValueError) as error:
            raise ValueError(f"Invalid {cls.json_model}: {error}") from error

    def to_json(self) -> str:
        envelope = {
            "schema_version": DOMAIN_SCHEMA_VERSION,
            "model": self.json_model,
            "data": self.to_dict(),
        }
        return json.dumps(envelope, ensure_ascii=False, separators=(",", ":"))

    @classmethod
    def from_json(cls: type[DomainModelT], value: str) -> DomainModelT:
        try:
            envelope = json.loads(value)
        except (TypeError, json.JSONDecodeError) as error:
            raise ValueError(f"Invalid {cls.json_model} JSON") from error

        if not isinstance(envelope, dict):
            raise ValueError(f"{cls.json_model} JSON envelope must be an object")
        unknown_fields = sorted(
            set(envelope) - {"schema_version", "model", "data"}
        )
        if unknown_fields:
            raise ValueError(
                f"Unknown JSON envelope fields: {', '.join(unknown_fields)}"
            )
        schema_version = envelope.get("schema_version")
        if (
            type(schema_version) is not int
            or schema_version != DOMAIN_SCHEMA_VERSION
        ):
            raise ValueError(
                f"Unsupported domain schema version: {schema_version!r}"
            )
        if envelope.get("model") != cls.json_model:
            raise ValueError(
                f"Expected model {cls.json_model!r}, got {envelope.get('model')!r}"
            )
        if "data" not in envelope:
            raise ValueError("JSON envelope is missing data")
        return cls.from_dict(envelope["data"])


def ensure_json_value(value: Any, path: str) -> None:
    """Reject metadata and sync payload values that cannot round-trip as JSON."""
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError(f"{path} cannot contain non-finite numbers")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            ensure_json_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValueError(f"{path} keys must be strings")
            ensure_json_value(item, f"{path}.{key}")
        return
    raise ValueError(f"{path} contains a non-JSON value: {type(value).__name__}")


def _encode_value(value: Any) -> Any:
    if isinstance(value, datetime):
        serialized = value.isoformat()
        if serialized.endswith("+00:00"):
            return serialized.removesuffix("+00:00") + "Z"
        return serialized
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, SerializableDomainModel):
        return value.to_dict()
    if isinstance(value, list):
        return [_encode_value(item) for item in value]
    if isinstance(value, dict):
        ensure_json_value(value, "value")
        return {key: _encode_value(item) for key, item in value.items()}
    ensure_json_value(value, "value")
    return value


def _decode_value(value: Any, annotation: Any, path: str) -> Any:
    if annotation is Any:
        ensure_json_value(value, path)
        return value

    origin = get_origin(annotation)
    arguments = get_args(annotation)

    if origin in (Union, UnionType):
        if value is None and type(None) in arguments:
            return None
        candidates = [argument for argument in arguments if argument is not type(None)]
        if len(candidates) == 1:
            return _decode_value(value, candidates[0], path)
        errors = []
        for candidate in candidates:
            try:
                return _decode_value(value, candidate, path)
            except ValueError as error:
                errors.append(str(error))
        raise ValueError(f"{path} does not match any allowed type: {'; '.join(errors)}")

    if origin is list:
        if not isinstance(value, list):
            raise ValueError(f"{path} must be an array")
        return [
            _decode_value(item, arguments[0], f"{path}[{index}]")
            for index, item in enumerate(value)
        ]

    if origin is dict:
        if not isinstance(value, dict):
            raise ValueError(f"{path} must be an object")
        key_type, value_type = arguments
        if key_type is not str or not all(isinstance(key, str) for key in value):
            raise ValueError(f"{path} keys must be strings")
        return {
            key: _decode_value(item, value_type, f"{path}.{key}")
            for key, item in value.items()
        }

    if annotation is datetime:
        if not isinstance(value, str):
            raise ValueError(f"{path} must be an ISO 8601 string")
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError(f"{path} must be a valid ISO 8601 datetime") from error

    if isinstance(annotation, type) and issubclass(annotation, Enum):
        try:
            return annotation(value)
        except (TypeError, ValueError) as error:
            raise ValueError(f"{path} has an unsupported value: {value!r}") from error

    if isinstance(annotation, type) and issubclass(
        annotation, SerializableDomainModel
    ):
        return annotation.from_dict(value)

    if annotation is bool:
        if type(value) is not bool:
            raise ValueError(f"{path} must be a boolean")
        return value
    if annotation is int:
        if type(value) is not int:
            raise ValueError(f"{path} must be an integer")
        return value
    if annotation is float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{path} must be a number")
        result = float(value)
        if not math.isfinite(result):
            raise ValueError(f"{path} must be finite")
        return result
    if annotation is str:
        if not isinstance(value, str):
            raise ValueError(f"{path} must be a string")
        return value

    raise ValueError(f"{path} uses an unsupported field type: {annotation!r}")
