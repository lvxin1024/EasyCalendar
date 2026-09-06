# EasyCalendar P2P native bridge

This crate is the stable native boundary for group synchronization. It is
transport-neutral by design: frame validation, authentication, error codes, and
endpoint lifecycle live here, while the next milestone adds the Iroh-backed
transport provider behind the same API.

## ABI

The `cdylib` and `staticlib` exports are intentionally small:

- `easycalendar_p2p_protocol_version()` returns the wire protocol version.
- `easycalendar_p2p_max_frame_bytes()` returns the hard frame limit.
- `easycalendar_p2p_validate_frame(kind, payload_len)` validates a frame header.
- `easycalendar_p2p_verify_auth(...)` verifies the group-secret HMAC response.

The endpoint lifecycle is represented by the Rust `Endpoint` type and remains
behind the same bridge until the Iroh provider is enabled. A closed endpoint is
terminal and must be recreated, which gives mobile and desktop lifecycle code a
single deterministic contract.

All functions return the stable integer values in `error::ErrorCode`. Dart must
map those values to `SyncTransportException` without exposing Rust types.

The HMAC input is:

```text
"easycalendar.sync.auth.v1\\0" || nonce || endpoint_id || uint16_be(protocol)
```

The group secret is exactly 32 bytes, and the response is a 32-byte
HMAC-SHA256 value. No secret or endpoint private key crosses the bridge in a
serialized configuration object.
