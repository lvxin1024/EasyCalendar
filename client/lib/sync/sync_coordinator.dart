import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'connectivity_monitor.dart';
import 'sync_models.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';
import 'token_store.dart';

class SyncCoordinator extends ChangeNotifier {
  SyncCoordinator({
    required this.repository,
    required this.transport,
    required this.tokenStore,
    required this.connectivityMonitor,
    required this.deviceId,
    required this.retryLimit,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : _uuid = uuid ?? Uuid(),
       _clock = clock ?? DateTime.now;

  final SyncRepository repository;
  final SyncTransport transport;
  final SyncTokenStore tokenStore;
  final ConnectivityMonitor connectivityMonitor;
  final String deviceId;
  final int retryLimit;
  final Uuid _uuid;
  final DateTime Function() _clock;

  SyncSnapshot _snapshot = const SyncSnapshot.disabled();
  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _retryTimer;
  Future<void>? _activeSync;
  Uri? _serverUrl;
  bool _enabled = false;
  bool _tokenConfigured = false;

  SyncSnapshot get snapshot => _snapshot;
  bool get tokenConfigured => _tokenConfigured;

  Future<void> start({required bool enabled, required String serverUrl}) async {
    try {
      _tokenConfigured = (await tokenStore.read())?.isNotEmpty ?? false;
    } catch (_) {
      // Secure storage availability must not block local-first startup.
      _tokenConfigured = false;
    }
    configure(enabled: enabled, serverUrl: serverUrl);
    _connectivitySubscription ??= connectivityMonitor.onlineChanges.listen((
      online,
    ) {
      if (!online || !_enabled) return;
      unawaited(_resumeAfterNetworkRecovery());
    });
    if (_enabled) unawaited(synchronize());
  }

  void configure({required bool enabled, required String serverUrl}) {
    _enabled = enabled;
    _serverUrl = Uri.tryParse(serverUrl);
    _retryTimer?.cancel();
    if (!enabled) {
      _setSnapshot(const SyncSnapshot.disabled());
    } else if (!_tokenConfigured) {
      _setSnapshot(const SyncSnapshot(phase: SyncPhase.needsAuthentication));
    } else if (_snapshot.phase == SyncPhase.disabled ||
        _snapshot.phase == SyncPhase.needsAuthentication) {
      _setSnapshot(const SyncSnapshot(phase: SyncPhase.idle));
    }
  }

  Future<void> saveToken(String token) async {
    final normalized = token.trim();
    if (normalized.length < 32) {
      throw const FormatException('同步令牌至少需要 32 个字符。');
    }
    await tokenStore.write(normalized);
    _tokenConfigured = true;
    _setSnapshot(
      _enabled
          ? const SyncSnapshot(phase: SyncPhase.idle)
          : const SyncSnapshot.disabled(),
    );
    if (_enabled) await synchronize();
  }

  Future<void> clearToken() async {
    await tokenStore.clear();
    _tokenConfigured = false;
    _retryTimer?.cancel();
    _setSnapshot(
      _enabled
          ? const SyncSnapshot(phase: SyncPhase.needsAuthentication)
          : const SyncSnapshot.disabled(),
    );
  }

  Future<void> synchronize() {
    if (!_enabled) return Future.value();
    final active = _activeSync;
    if (active != null) return active;
    final future = _runSync();
    _activeSync = future;
    return future.whenComplete(() => _activeSync = null);
  }

  Future<void> _runSync() async {
    final token = await tokenStore.read();
    final serverUrl = _serverUrl;
    if (token == null || token.isEmpty) {
      _tokenConfigured = false;
      _setSnapshot(const SyncSnapshot(phase: SyncPhase.needsAuthentication));
      return;
    }
    if (serverUrl == null || !serverUrl.hasScheme || !serverUrl.hasAuthority) {
      _setSnapshot(
        const SyncSnapshot(phase: SyncPhase.failed, message: '同步服务地址无效。'),
      );
      return;
    }

    _retryTimer?.cancel();
    _setSnapshot(
      SyncSnapshot(
        phase: SyncPhase.syncing,
        lastSyncedAt: _snapshot.lastSyncedAt,
      ),
    );
    var attemptedChangeIds = <String>[];
    try {
      while (true) {
        final pending = await repository.listPendingChanges(
          now: _clock(),
          limit: 200,
        );
        if (pending.isEmpty) break;
        attemptedChangeIds = pending.map((change) => change.changeId).toList();
        final result = await transport.push(
          serverUrl: serverUrl,
          token: token,
          deviceId: deviceId,
          idempotencyKey: 'push_${_uuid.v4()}',
          changes: pending,
        );
        await repository.applyPushConflicts(result.conflicts);
        await repository.removeAcceptedChanges(result.accepted);
        await repository.recordPermanentFailures(result.rejected);
        if (result.accepted.isEmpty && result.rejected.isEmpty) {
          throw const SyncTransportException('同步服务未处理当前批次。');
        }
      }

      var cursor = await repository.loadRemoteCursor();
      while (true) {
        final page = await transport.pull(
          serverUrl: serverUrl,
          token: token,
          cursor: cursor,
        );
        await repository.applyRemoteBatch(page.changes, page.cursor);
        cursor = page.cursor;
        if (!page.hasMore) break;
      }
      _setSnapshot(SyncSnapshot(phase: SyncPhase.idle, lastSyncedAt: _clock()));
    } on SyncAuthenticationException catch (error) {
      _setSnapshot(
        SyncSnapshot(
          phase: SyncPhase.needsAuthentication,
          lastSyncedAt: _snapshot.lastSyncedAt,
          message: error.message,
        ),
      );
    } on SyncTransportException catch (error) {
      if (error.permanent) {
        if (attemptedChangeIds.isNotEmpty) {
          await repository.recordPermanentFailures(
            attemptedChangeIds
                .map(
                  (id) => SyncRejection(
                    changeId: id,
                    code: 'transport_rejected',
                    message: error.message,
                  ),
                )
                .toList(),
          );
        }
        _setSnapshot(
          SyncSnapshot(
            phase: SyncPhase.failed,
            lastSyncedAt: _snapshot.lastSyncedAt,
            message: error.message,
          ),
        );
      } else {
        await _recordBackoff(attemptedChangeIds, error.message);
      }
    } catch (error) {
      await _recordBackoff(attemptedChangeIds, error.toString());
    }
  }

  Future<void> _recordBackoff(List<String> changeIds, String message) async {
    final nextRetryAt = await repository.recordTransientFailure(
      changeIds,
      message,
      now: _clock(),
      retryLimit: retryLimit,
    );
    if (nextRetryAt == null) {
      _setSnapshot(
        SyncSnapshot(
          phase: SyncPhase.failed,
          lastSyncedAt: _snapshot.lastSyncedAt,
          message: message,
        ),
      );
      return;
    }
    _setSnapshot(
      SyncSnapshot(
        phase: SyncPhase.backoff,
        lastSyncedAt: _snapshot.lastSyncedAt,
        nextRetryAt: nextRetryAt,
        message: message,
      ),
    );
    final delay = nextRetryAt.difference(_clock());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (_enabled) unawaited(synchronize());
    });
  }

  Future<void> _resumeAfterNetworkRecovery() async {
    await repository.resetTransientBackoff();
    await synchronize();
  }

  Future<List<SyncConflictRecord>> loadConflictHistory({int limit = 100}) =>
      repository.listSyncConflicts(limit: limit);

  void _setSnapshot(SyncSnapshot value) {
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }
}
