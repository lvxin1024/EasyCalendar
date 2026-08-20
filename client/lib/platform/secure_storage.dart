import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const easyCalendarSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(
    usesDataProtectionKeychain: bool.fromEnvironment(
      'EASYCALENDAR_USE_DATA_PROTECTION_KEYCHAIN',
    ),
  ),
);
