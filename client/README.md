# EasyCalendar Flutter client

The client is local-first and uses SQLite on Android, macOS, and Windows. Its
runtime defaults come from `config/client.json`; no user-specific endpoint,
timezone, collection, or feature toggle is stored in Dart source.

```bash
cp config/client.example.json config/client.json
./scripts/setup-client.sh
./scripts/run-client.sh
```

`setup-client.sh` requires Flutter `3.44.9` (also declared in `.fvmrc`) and
generates the standard Android, macOS, and Windows runner projects before
resolving packages. `run-client.sh` passes the selected config file through
`--dart-define-from-file`. It defaults to the host desktop target; set
`EASYCALENDAR_CLIENT_DEVICE` to an Android device ID when needed. Web is not a
supported target because the local SQLite/path-provider stack is native-only.

`EASYCALENDAR_DEVICE_ID` is blank by default. Each installation generates and
persists a unique ID before creating local sync changes. Users can edit the
friendly device name in Settings; the technical ID is available only under
advanced connection settings for copying or confirmed regeneration.

The client stores separate runtime endpoints for sync and feature APIs.
`EASYCALENDAR_API_URL` initializes the Cloudflare sync endpoint, while
`EASYCALENDAR_FEATURE_API_URL` initializes the Python Core endpoint used by URL
subscriptions and other optional remote features. Both endpoints can be changed
in Settings. ICS file import and export run entirely in the Flutter client and
do not require either service.

The generated platform runners and `pubspec.lock` are version controlled.
Analyzer and unit tests run on any Flutter-capable development machine; native
build acceptance additionally requires that platform's SDK and toolchain.
