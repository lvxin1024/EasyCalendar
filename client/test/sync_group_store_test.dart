import 'package:easy_calendar/sync/sync_group.dart';
import 'package:easy_calendar/sync/sync_group_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('setup controller creates and persists a primary profile', () async {
    final store = _MemoryGroupStore();
    final setup = SyncGroupSetupController(store);
    final profile = await setup.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
    );

    expect(profile.role, SyncGroupRole.primary);
    expect(await setup.load(), profile);
    expect(await setup.exportCode(), profile.encode());
  });

  test(
    'joining an ECG1 code stores a replica without changing its secret',
    () async {
      final source = SyncGroupProfile.createPrimary(
        primaryEndpointId: 'endpoint-primary',
        endpointTicket: 'ticket-primary',
      );
      final store = _MemoryGroupStore();
      final setup = SyncGroupSetupController(store);
      final joined = await setup.join(
        code: source.encode(),
        localEndpointId: 'endpoint-phone',
      );

      expect(joined.role, SyncGroupRole.replica);
      expect(joined.groupId, source.groupId);
      expect(joined.groupSecret, source.groupSecret);
      expect(joined.primaryEndpointId, source.primaryEndpointId);
    },
  );

  test('setup rejects using the primary endpoint as a replica', () async {
    final source = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
    );
    final setup = SyncGroupSetupController(_MemoryGroupStore());

    expect(
      () => setup.join(
        code: source.encode(),
        localEndpointId: 'endpoint-primary',
      ),
      throwsFormatException,
    );
  });
}

class _MemoryGroupStore implements SyncGroupProfileStore {
  SyncGroupProfile? value;

  @override
  Future<SyncGroupProfile?> read() async => value;

  @override
  Future<void> write(SyncGroupProfile profile) async => value = profile;

  @override
  Future<void> clear() async => value = null;
}
