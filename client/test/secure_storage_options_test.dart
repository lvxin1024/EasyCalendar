import 'package:easy_calendar/platform/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unsigned builds default to the entitlement-free macOS keychain', () {
    final options = easyCalendarSecureStorage.mOptions as MacOsOptions;

    expect(options.usesDataProtectionKeychain, isFalse);
  });
}
