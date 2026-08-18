import 'package:easy_calendar/data/calendar_connection_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calendar connection code round-trips user-facing metadata', () {
    const original = CalendarConnectionCode(
      collectionId: 'collection_1234-abcd',
      name: '家庭日历',
      color: 0xFF0F766E,
    );

    final decoded = CalendarConnectionCode.decode(original.encode());

    expect(decoded.collectionId, original.collectionId);
    expect(decoded.name, original.name);
    expect(decoded.color, original.color);
  });

  test('calendar connection code rejects malformed and corrupted input', () {
    expect(
      () => CalendarConnectionCode.decode('collection_internal_id'),
      throwsFormatException,
    );
    final valid = const CalendarConnectionCode(
      collectionId: 'collection_shared',
      name: 'Shared',
    ).encode();
    final corrupted = '${valid.substring(0, valid.length - 1)}A';
    expect(
      () => CalendarConnectionCode.decode(corrupted),
      throwsFormatException,
    );
  });
}
