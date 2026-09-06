# EasyCalendar P2P native bridge

This crate is the stable native boundary for group synchronization. It owns the
Iroh endpoint lifecycle, QUIC request/response handles, frame limits, and the
stable error surface consumed by Dart FFI. Dart keeps group authentication and
business change semantics in `IrohSyncGroupPeer`; the crate does not store
calendar data.

## ABI

The `cdylib` and `staticlib` exports are intentionally small:

- `easycalendar_p2p_protocol_version()` returns the wire protocol version.
- `easycalendar_p2p_max_frame_bytes()` returns the hard frame limit.
- `easycalendar_p2p_validate_frame(kind, payload_len)` validates a frame header.
- `easycalendar_p2p_verify_auth(...)` verifies the group-secret HMAC response.
- `easycalendar_p2p_endpoint_bind(...)` creates an endpoint from a 32-byte key.
- `easycalendar_p2p_endpoint_id_*` and `easycalendar_p2p_endpoint_ticket(...)`
  expose the endpoint identity and join ticket.
- `easycalendar_p2p_endpoint_connect_id(...)` and
  `easycalendar_p2p_endpoint_accept(...)` establish QUIC connections.
- `easycalendar_p2p_endpoint_request(...)`,
  `easycalendar_p2p_endpoint_receive_request(...)`, and
  `easycalendar_p2p_endpoint_respond(...)` exchange bounded frames.
- `easycalendar_p2p_endpoint_close(...)` releases the endpoint.

The endpoint lifecycle is represented by the Rust `Endpoint` type. A closed
endpoint is terminal and must be recreated, which gives mobile and desktop
lifecycle code a single deterministic contract. The public relay is a free,
best-effort connection path; it has no project SLA and can be replaced by a
direct or self-hosted relay configuration.

All functions return the stable integer values in `error::ErrorCode`. Dart must
map those values to `SyncTransportException` without exposing Rust types.

The HMAC input is:

```text
"easycalendar.sync.auth.v1\\0" || nonce || endpoint_id || uint16_be(protocol)
```

The group secret is exactly 32 bytes, and the response is a 32-byte
HMAC-SHA256 value. No secret or endpoint private key crosses the bridge in a
serialized configuration object.

## Build status

The crate is not yet included in every published Flutter platform artifact.
Before describing group sync as publicly available, build and package the
library for each target and run:

```text
cargo fmt --check
cargo test
```

The Dart bridge falls back to an explicit unavailable error when the dynamic
library is absent; existing local and Cloudflare modes remain usable.
