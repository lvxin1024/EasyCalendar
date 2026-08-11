import 'package:timezone/timezone.dart' as tz;

DateTime configuredNow() => tz.TZDateTime.now(tz.local);

DateTime inConfiguredTimezone(DateTime value) =>
    tz.TZDateTime.from(value, tz.local);

DateTime configuredDateTime({
  required int year,
  required int month,
  required int day,
  int hour = 0,
  int minute = 0,
}) => tz.TZDateTime(tz.local, year, month, day, hour, minute);
