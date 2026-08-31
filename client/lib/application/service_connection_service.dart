import '../data/service_probe_client.dart';
import '../sync/sync_coordinator.dart';
import '../sync/token_store.dart';

class ServiceConnectionService {
  ServiceConnectionService({
    required this.syncCoordinator,
    SyncTokenStore? featureTokenStore,
    ServiceProbeClient? probeClient,
  }) : _featureTokenStore = featureTokenStore ?? SecureFeatureTokenStore(),
       _probeClient = probeClient ?? ServiceProbeClient();

  final SyncCoordinator? syncCoordinator;
  final SyncTokenStore _featureTokenStore;
  final ServiceProbeClient _probeClient;

  Future<bool> hasFeatureToken() async {
    try {
      return (await _featureTokenStore.read())?.isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveSyncToken(String token) async {
    await syncCoordinator?.saveToken(token);
  }

  Future<void> clearSyncToken() async {
    await syncCoordinator?.clearToken();
  }

  Future<bool> saveFeatureToken(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) return false;
    await _featureTokenStore.write(normalized);
    return true;
  }

  Future<void> clearFeatureToken() => _featureTokenStore.clear();

  Future<ServiceProbeResult> probe({
    required ServiceKind kind,
    required String serverUrl,
    String pendingToken = '',
  }) async {
    var token = pendingToken.trim();
    if (token.isEmpty) {
      final store = kind == ServiceKind.sync
          ? syncCoordinator?.tokenStore
          : _featureTokenStore;
      try {
        token = (await store?.read())?.trim() ?? '';
      } catch (_) {
        token = '';
      }
    }
    return _probeClient.probe(
      serverUrl: Uri.parse(serverUrl.trim()),
      kind: kind,
      token: token,
    );
  }

  void close() => _probeClient.close();
}
