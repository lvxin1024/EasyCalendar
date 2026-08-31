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
  }) : _fetchClient = fetchClient ?? SubscriptionFetchClient();

  final ItemRepository repository;
  final LocalIcsService localIcsService;
  final String Function() activeTimezone;
  final MutationRunner runMutation;
  final SubscriptionFetchClient _fetchClient;

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
    return result;
  }

  Future<void> delete(CalendarSubscription current) =>
      runMutation(() => repository.deleteSubscription(current));

  Future<SubscriptionFetchLog> refresh(CalendarSubscription current) async {
    final fetchedAt = DateTime.now();
    try {
      final response = await _fetchClient.fetch(current);
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
      try {
        await runMutation(
          () => repository.recordSubscriptionRefreshFailure(
            current,
            fetchedAt: fetchedAt,
            error: '$error',
            httpStatus: error is SubscriptionFetchException
                ? error.statusCode
                : null,
          ),
          reloadItems: false,
        );
      } catch (_) {
        // Preserve the original fetch or parse error if failure logging races.
      }
      rethrow;
    }
  }

  Future<List<SubscriptionFetchLog>> listLogs(String subscriptionId) =>
      repository.listSubscriptionFetchLogs(subscriptionId);

  void close() => _fetchClient.close();
}
