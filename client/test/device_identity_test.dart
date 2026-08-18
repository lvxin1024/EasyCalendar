import 'package:easy_calendar/device/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blank and legacy defaults receive generated device IDs', () {
    final generated = <String>[
      'device-11111111-1111-4111-8111-111111111111',
      'device-22222222-2222-4222-8222-222222222222',
    ];
    final identity = DeviceIdentity(
      idGenerator: () => generated.removeAt(0),
      platformLabel: 'Test',
    );

    expect(
      identity.resolveInitialId(''),
      'device-11111111-1111-4111-8111-111111111111',
    );
    expect(
      identity.resolveInitialId(DeviceIdentity.legacyDefaultId),
      'device-22222222-2222-4222-8222-222222222222',
    );
  });

  test('valid configured and persisted IDs remain stable', () {
    final identity = DeviceIdentity(
      idGenerator: () => 'device-unused',
      platformLabel: 'Test',
    );

    expect(identity.resolveInitialId('custom-device'), 'custom-device');
    expect(
      identity.ensurePersistedId(
        'persisted-device',
        fallbackId: 'fallback-device',
      ),
      'persisted-device',
    );
  });

  test('legacy persisted ID migrates to the startup fallback', () {
    final identity = DeviceIdentity(
      idGenerator: () => 'device-unused',
      platformLabel: 'Test',
    );

    expect(
      identity.ensurePersistedId(
        DeviceIdentity.legacyDefaultId,
        fallbackId: 'device-new-install',
      ),
      'device-new-install',
    );
    expect(
      identity.ensureDeviceName('', deviceId: 'device-new-install'),
      'Test-nstall',
    );
  });

  test('invalid generated IDs fail instead of entering sync state', () {
    final identity = DeviceIdentity(
      idGenerator: () => 'invalid device id',
      platformLabel: 'Test',
    );

    expect(identity.generateId, throwsStateError);
  });

  test('explicit regeneration never returns the current ID', () {
    final generated = <String>['same-device', 'same-device', 'new-device'];
    final identity = DeviceIdentity(
      idGenerator: () => generated.removeAt(0),
      platformLabel: 'Test',
    );

    expect(identity.generateDistinctId('same-device'), 'new-device');
  });
}
