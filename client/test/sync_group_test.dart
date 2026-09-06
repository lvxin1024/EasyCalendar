import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:easy_calendar/sync/sync_group.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates a primary profile with a random 32-byte group secret', () {
    final profile = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
      random: _FixedRandom(),
    );

    expect(profile.protocolVersion, 1);
    expect(profile.groupSecret, isNotEmpty);
    expect(profile.groupSecret, isNot(contains('=')));
    expect(profile.groupId, hasLength(64));
    expect(profile.role, SyncGroupRole.primary);
  });

  test('sync group code round-trips a profile through canonical JSON', () {
    final original = SyncGroupProfile.fromSecret(
      groupSecret: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      role: SyncGroupRole.replica,
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
      relayMode: SyncRelayMode.custom,
      relayUrls: ['https://relay.example.com'],
      topologyEpoch: 3,
    );

    final decoded = SyncGroupCode.decode(original.encode());

    expect(decoded.toJson(), original.toJson());
    expect(decoded.encode(), original.encode());
  });

  test('sync group code rejects tampering, unknown fields and invalid secrets', () {
    final profile = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
      random: _FixedRandom(),
    );
    final valid = profile.encode();
    final unknownFieldPayload = profile.toJson()..['unexpected'] = true;
    final unknownFieldJson = jsonEncode(unknownFieldPayload);
    final unknownFieldCode =
        '${SyncGroupCode.prefix}${base64Url.encode(utf8.encode(unknownFieldJson)).replaceAll('=', '')}'
        '.${base64Url.encode(sha256.convert(utf8.encode(unknownFieldJson)).bytes).replaceAll('=', '')}';

    expect(() => SyncGroupCode.decode('${valid}x'), throwsFormatException);
    expect(() => SyncGroupCode.decode(unknownFieldCode), throwsFormatException);
    expect(
      () => SyncGroupProfile.fromSecret(
        groupSecret: 'short',
        role: SyncGroupRole.primary,
        primaryEndpointId: 'endpoint-primary',
        endpointTicket: 'ticket-primary',
      ),
      throwsFormatException,
    );
  });

  test('relay mode and endpoint validation stay strict', () {
    expect(
      () => SyncGroupProfile.createPrimary(
        primaryEndpointId: 'endpoint-primary',
        endpointTicket: 'ticket-primary',
        relayMode: SyncRelayMode.custom,
      ),
      throwsFormatException,
    );
    expect(
      () => SyncGroupProfile.createPrimary(
        primaryEndpointId: 'endpoint-primary',
        endpointTicket: 'ticket-primary',
        relayMode: SyncRelayMode.directOnly,
        relayUrls: ['https://relay.example.com'],
      ),
      throwsFormatException,
    );
    expect(
      () => SyncGroupProfile.createPrimary(
        primaryEndpointId: 'bad id',
        endpointTicket: 'ticket-primary',
      ),
      throwsFormatException,
    );
  });
}

class _FixedRandom implements Random {
  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => max == 0 ? 0 : 0;
}
