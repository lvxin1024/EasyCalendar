# EasyCalendar Flutter client

The client is local-first and uses SQLite on Android, macOS, and Windows. Its
runtime defaults come from `config/client.json`; no user-specific endpoint,
timezone, collection, or feature toggle is stored in Dart source.

```bash
cp config/client.example.json config/client.json
./scripts/setup-client.sh
./scripts/run-client.sh
```

`setup-client.sh` requires Flutter `3.35.7` (also declared in `.fvmrc`) and
generates the standard Android, macOS, and Windows runner projects before
resolving packages. `run-client.sh` passes the selected config file through
`--dart-define-from-file`. Set `EASYCALENDAR_CLIENT_DEVICE` when more than one
device is available.

This repository was prepared on a machine without Flutter/Dart, so the checked
in Dart code has static contract tests but the generated platform runners,
`pubspec.lock`, analyzer, widget tests, and platform builds must be produced by
the setup command on a Flutter-capable machine.
