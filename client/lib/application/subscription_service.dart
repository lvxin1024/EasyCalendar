import 'dart:async';

import '../data/item_repository.dart';
import '../data/local_ics_service.dart';
import '../data/subscription_fetch_client.dart';
import '../domain/subscription.dart';

typedef MutationRunner =
    Future<void> Function(
      Future<void> Function() operation, {
      bool reloadItems,
    });

class SubscriptionService {
  SubscriptionService({
    required this.repository,
    required this.localIcsService,
    required this.activeTimezone,
    required this.runMutation,
    SubscriptionFetchClient? fetchClient,
    DateTime Function()? clock,
  }) : _fetchClient = fetchClient ?? SubscriptionFetchClient(),
       _clock = clock ?? DateTime.now;

  final ItemRepository repository;
  final LocalIcsService localIcsService;
  final String Function() activeTimezone;
  final MutationRunner runMutation;
  final SubscriptionFetchClient _fetchClient;
  final DateTime Function() _clock;
  final Map<String, Future<SubscriptionFetchLog>> _refreshes = {};
  Timer? _refreshTimer;
  bool _checkingDue = false;
  bool _closed = false;
  int _refreshGeneration = 0;

  void startAutoRefresh() {
    if (_closed) return;
    _refreshTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(refreshDue());
    });
    unawaited(refreshDue());
  }

  void stopAutoRefresh() {
    _refreshGeneration++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> refreshDue() async {
    if (_closed || _checkingDue) return;
    _checkingDue = true;
    final generation = _refreshGeneration;
    try {
      for (final subscription in await list()) {
        if (_closed || generation != _refreshGeneration) return;
        final lastFetched = subscription.lastFetchedAt;
        if (!subscription.enabled ||
            (lastFetched != null &&
                _clock().difference(lastFetched) <
                    Duration(minutes: subscription.refreshIntervalMinutes))) {
          continue;
        }
        try {
          await refresh(subscription);
        } catch (_) {
          // Each source records its own error; keep refreshing the others.
        }
      }
    } catch (_) {
      // A temporary database failure can be retried on the next tick.
    } finally {
      _checkingDue = false;
    }
  }

  Future<List<CalendarSubscription>> list() => repository.listSubscriptions();

  Future<CalendarSubscription> create({
    required String title,
    required String url,
    required int refreshIntervalMinutes,
    required List<String> tags,
  }) async {
    late CalendarSubscription result;
    await runMutation(() async {
      result = await repository.createSubscription(
        title: title,
        url: url,
        refreshIntervalMinutes: refreshIntervalMinutes,
        tags: tags,
      );
    });
    return result;
  }

  Future<CalendarSubscription> update(
    CalendarSubscription current, {
    required String title,
    required String url,
    required bool enabled,
    required int refreshIntervalMinutes,
    required List<String> tags,
  }) async {
    late CalendarSubscription result;
    await runMutation(() async {
      result = await repository.updateSubscription(
        current,
        title: title,
        url: url,
        enabled: enabled,
        refreshIntervalMinutes: refreshIntervalMinutes,
        tags: tags,
      );
    });
    if (result.enabled && (!current.enabled || result.url != current.url)) {
      await refresh(result);
      result = (await list()).firstWhere((value) => value.id == result.id);
    }
    return result;
  }

  Future<void> delete(CalendarSubscription current) =>
      runMutation(() => repository.deleteSubscription(current));

  Future<SubscriptionFetchLog> refresh(CalendarSubscription current) async {
    if (_closed) throw StateError('订阅服务已关闭。');
    final latest = (await list())
        .where((value) => value.id == current.id)
        .firstOrNull;
    if (_closed) throw StateError('订阅服务已关闭。');
    if (latest == null || !latest.enabled) {
      throw const RepositoryConflict('订阅已停用或删除，请重新开启后刷新。');
    }
    final key = '${latest.id}:${latest.version}';
    final pending = _refreshes[key];
    if (pending != null) return pending;
    final refresh = _refresh(latest);
    _refreshes[key] = refresh;
    try {
      return await refresh;
    } finally {
      _refreshes.remove(key);
    }
  }

  Future<SubscriptionFetchLog> _refresh(CalendarSubscription current) async {
    final fetchedAt = _clock();
    try {
      final response = await _fetchClient.fetch(current);
      if (_closed) throw StateError('订阅服务已关闭。');
      var events = const <LocalIcsEvent>[];
      if (!response.notModified) {
        final plan = localIcsService.planImport(
          response.content,
          defaultTimezone: activeTimezone(),
          deduplicate: false,
        );
        if (!plan.result.accepted) {
          throw FormatException('订阅文件包含 ${plan.result.issues.length} 个无效日程。');
        }
        events = plan.events;
      }
      late SubscriptionFetchLog result;
      await runMutation(() async {
        if (_closed) throw StateError('订阅服务已关闭。');
        result = await repository.applySubscriptionRefresh(
          current,
          events: events,
          notModified: response.notModified,
          httpStatus: response.statusCode,
          fetchedAt: fetchedAt,
          etag: response.etag,
          lastModified: response.lastModified,
          sourceHash: response.sourceHash,
        );
      });
      return result;
    } catch (error) {
      if (_closed) rethrow;
      try {
        await runMutation(() async {
          if (_closed) return;
          await repository.recordSubscriptionRefreshFailure(
            current,
            fetchedAt: fetchedAt,
            error: '$error',
            httpStatus: error is SubscriptionFetchException
                ? error.statusCode
                : null,
          );
        }, reloadItems: false);
      } catch (_) {
        // Preserve the original fetch or parse error if failure logging races.
      }
      rethrow;
    }
  }

  Future<List<SubscriptionFetchLog>> listLogs(String subscriptionId) =>
      repository.listSubscriptionFetchLogs(subscriptionId);

  void close() {
    _closed = true;
    stopAutoRefresh();
    _fetchClient.close();
  }
}
