import 'dart:typed_data';

import 'package:easy_calendar/sync/p2p_bridge.dart';
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

  test('automatic join creates and reuses a local endpoint identity', () async {
    final source = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
    );
    final profileStore = _MemoryGroupStore();
    final endpointStore = _MemoryEndpointIdentityStore();
    final setup = SyncGroupSetupController(
      profileStore,
      endpointIdentityStore: endpointStore,
    );

    final first = await setup.joinAutomatically(
      code: source.encode(),
      fallbackDeviceId: 'device-phone',
    );
    final second = await setup.joinAutomatically(
      code: source.encode(),
      fallbackDeviceId: 'device-phone-renamed',
    );

    expect(first.role, SyncGroupRole.replica);
    expect(second.groupId, first.groupId);
    expect(second.groupSecret, first.groupSecret);
    expect(second.primaryEndpointId, first.primaryEndpointId);
    expect(await endpointStore.read(), 'device-phone');
  });

  test('endpoint key is generated once and survives device renaming', () async {
    final keyStore = _MemoryEndpointKeyStore();
    final setup = SyncGroupSetupController(
      _MemoryGroupStore(),
      endpointKeyStore: keyStore,
    );

    final first = await setup.ensureLocalEndpointKey();
    final second = await setup.ensureLocalEndpointKey();

    expect(first, second);
    expect(first.length, greaterThan(40));
    expect(await keyStore.read(), first);
  });

  test('invalid stored endpoint key is replaced', () async {
    final keyStore = _MemoryEndpointKeyStore()..value = 'invalid';
    final setup = SyncGroupSetupController(
      _MemoryGroupStore(),
      endpointKeyStore: keyStore,
    );

    final key = await setup.ensureLocalEndpointKey();

    expect(key, isNot('invalid'));
    expect(keyStore.value, key);
  });

  test('automatic primary setup uses the native endpoint identity and ticket', () async {
    final bridge = _MemoryP2pBridge();
    final setup = SyncGroupSetupController(
      _MemoryGroupStore(),
      endpointIdentityStore: _MemoryEndpointIdentityStore(),
      endpointKeyStore: _MemoryEndpointKeyStore(),
    );

    final profile = await setup.createPrimaryAutomatically(
      bridge: bridge,
      fallbackDeviceId: 'device-desktop',
    );

    expect(profile.role, SyncGroupRole.primary);
    expect(profile.primaryEndpointId, 'endpoint-native');
    expect(profile.endpointTicket, 'ticket-native');
    expect(bridge.secretLength, 32);
  });

  test('automatic join starts the endpoint before storing the replica profile', () async {
    final source = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
    );
    final bridge = _MemoryP2pBridge();
    final setup = SyncGroupSetupController(
      _MemoryGroupStore(),
      endpointIdentityStore: _MemoryEndpointIdentityStore(),
      endpointKeyStore: _MemoryEndpointKeyStore(),
    );

    final profile = await setup.joinAutomaticallyWithBridge(
      code: source.encode(),
      fallbackDeviceId: 'device-phone',
      bridge: bridge,
    );

    expect(profile.role, SyncGroupRole.replica);
    expect(profile.groupId, source.groupId);
    expect(bridge.startedGroupId, source.groupId);
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

class _MemoryEndpointIdentityStore implements SyncEndpointIdentityStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String endpointId) async => value = endpointId;

  @override
  Future<void> clear() async => value = null;
}

class _MemoryEndpointKeyStore implements SyncEndpointKeyStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String encodedKey) async => value = encodedKey;

  @override
  Future<void> clear() async => value = null;
}

class _MemoryP2pBridge implements P2pBridge {
  int? secretLength;
  String? startedGroupId;

  @override
  int get protocolVersion => 1;

  @override
  int get maxFrameBytes => 1024 * 1024;

  @override
  Future<void> start({
    required String endpointId,
    required String groupId,
    String? endpointSecret,
  }) async {
    startedGroupId = groupId;
    secretLength = endpointSecret == null ? null : 32;
  }

  @override
  Future<String> endpointId() async => 'endpoint-native';

  @override
  Future<String> exportTicket() async => 'ticket-native';

  @override
  Future<int> connect(String ticket) async => 1;

  @override
  Future<int?> accept({Duration timeout = const Duration(milliseconds: 250)}) async => null;

  @override
  Future<Uint8List> request({
    required int connectionId,
    required Uint8List frame,
  }) async => Uint8List(0);

  @override
  Future<Uint8List> receiveRequest({required int connectionId}) async =>
      Uint8List(0);

  @override
  Future<void> respond({
    required int connectionId,
    required Uint8List frame,
  }) async {}

  @override
  Future<void> close() async {}
}
