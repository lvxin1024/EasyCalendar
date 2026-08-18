# Application identity

EasyCalendar uses the following release identity. User-visible names use the
same `EasyCalendar` spelling on every platform.

| Field | Value | Compatibility rule |
|---|---|---|
| Product name | `EasyCalendar` | Used for app labels, windows, executable names, and installers |
| Publisher | `lvxin1024` | Used in Windows and macOS release metadata |
| Version source | `client/pubspec.yaml` | Release tags must be `vX.Y.Z` and match the pubspec build name |
| Android application ID | `io.easycalendar.easy_calendar` | Frozen; changing it would create a separate Android installation |
| macOS bundle ID | `io.easycalendar.easyCalendar` | Frozen; also anchors the existing app container and Keychain access |
| macOS Widget bundle ID | `io.easycalendar.easyCalendar.Widget` | Frozen with App Group `group.io.easycalendar.easyCalendar` |
| Windows installer AppId | `{6A85E13C-36C8-49CE-A95D-ECA4A07C8D55}` | Frozen so Inno Setup performs an in-place upgrade |
| Windows AppUserModelID | `io.easycalendar.EasyCalendar` | Frozen for notification continuity |
| Install directory | `%LOCALAPPDATA%\Programs\EasyCalendar` | Stable across installer upgrades |

Windows builds before the product metadata was finalized stored application
support files under `%APPDATA%\io.easycalendar\easy_calendar`. On first launch,
the current build moves that directory to the canonical directory reported by
Windows. This includes SQLite data, local recovery points, preferences, and the
encrypted secure-storage file. If a non-empty target already exists, only
missing files are copied and the legacy directory is retained as a recovery
source rather than overwriting newer data.

The Dart package name remains `easy_calendar`; it is an internal import name
and is not part of the installed application identity.
