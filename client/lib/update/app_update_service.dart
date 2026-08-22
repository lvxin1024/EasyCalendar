import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppBuildInfo {
  const AppBuildInfo({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.schemaVersion,
  });

  final String version;
  final String buildNumber;
  final String platform;
  final int schemaVersion;
}

class ReleaseUpdate {
  const ReleaseUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseName,
    required this.notes,
    required this.releaseUri,
    required this.assetUri,
    required this.assetName,
  });

  final String currentVersion;
  final String latestVersion;
  final String releaseName;
  final String notes;
  final Uri releaseUri;
  final Uri? assetUri;
  final String? assetName;

  bool get updateAvailable =>
      AppUpdateService.compareVersions(latestVersion, currentVersion) > 0;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.repository = const String.fromEnvironment(
      'EASYCALENDAR_GITHUB_REPOSITORY',
      defaultValue: 'lvxin1024/EasyCalendar',
    ),
    String? platform,
  }) : _client = client ?? http.Client(),
       platform = platform ?? Platform.operatingSystem;

  final http.Client _client;
  final String repository;
  final String platform;

  Future<AppBuildInfo> loadBuildInfo({required int schemaVersion}) async {
    final package = await PackageInfo.fromPlatform();
    return AppBuildInfo(
      version: package.version,
      buildNumber: package.buildNumber,
      platform: platform,
      schemaVersion: schemaVersion,
    );
  }

  Future<ReleaseUpdate> checkForUpdate(String currentVersion) async {
    final repositoryParts = repository.split('/');
    if (repositoryParts.length != 2 ||
        repositoryParts.any(
          (part) => !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part),
        )) {
      throw const AppUpdateException('更新仓库配置无效');
    }
    late http.Response response;
    try {
      response = await _client
          .get(
            Uri.https('api.github.com', '/repos/$repository/releases/latest'),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'EasyCalendar-Update-Checker',
            },
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const AppUpdateException('检查更新超时，请稍后重试');
    } on http.ClientException {
      throw const AppUpdateException('无法连接 GitHub，请检查网络');
    }
    if (response.statusCode == 404) {
      throw const AppUpdateException('尚未发布可用的 GitHub Release');
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const AppUpdateException('GitHub 请求频率受限，请稍后重试');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppUpdateException('GitHub 返回 HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.length > 1000000) {
      throw const AppUpdateException('Release 元数据响应过大');
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('root');
      }
      final tag = _requiredString(decoded['tag_name'], 'tag_name');
      final releaseUri = _trustedReleaseUri(
        _requiredString(decoded['html_url'], 'html_url'),
      );
      final latestVersion = _normalizeVersion(tag);
      compareVersions(latestVersion, currentVersion);
      Uri? assetUri;
      String? assetName;
      final assets = decoded['assets'];
      if (assets is List) {
        for (final rawAsset in assets.whereType<Map>()) {
          final name = rawAsset['name'];
          final url = rawAsset['browser_download_url'];
          if (name is! String || url is! String || !_matchesPlatform(name)) {
            continue;
          }
          final candidate = _trustedReleaseUri(url);
          assetUri = candidate;
          assetName = name;
          break;
        }
      }
      return ReleaseUpdate(
        currentVersion: _normalizeVersion(currentVersion),
        latestVersion: latestVersion,
        releaseName:
            decoded['name'] is String &&
                (decoded['name'] as String).trim().isNotEmpty
            ? (decoded['name'] as String).trim()
            : tag,
        notes: decoded['body'] is String ? decoded['body'] as String : '',
        releaseUri: releaseUri,
        assetUri: assetUri,
        assetName: assetName,
      );
    } on AppUpdateException {
      rethrow;
    } catch (_) {
      throw const AppUpdateException('GitHub Release 元数据格式无效');
    }
  }

  Future<bool> openRelease(ReleaseUpdate update) => _open(update.releaseUri);

  Future<bool> openPlatformAsset(ReleaseUpdate update) {
    final asset = update.assetUri;
    return asset == null ? Future.value(false) : _open(asset);
  }

  Future<bool> _open(Uri uri) async {
    _trustedReleaseUri(uri.toString());
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  bool _matchesPlatform(String name) {
    final lower = name.toLowerCase();
    return switch (platform) {
      'macos' => lower.endsWith('-macos.dmg'),
      'windows' => lower.endsWith('-windows-x64-setup.exe'),
      'android' => lower.endsWith('-android.apk'),
      _ => false,
    };
  }

  Uri _trustedReleaseUri(String value) {
    final uri = Uri.tryParse(value);
    final prefix = '/$repository/releases/';
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(prefix) ||
        uri.userInfo.isNotEmpty) {
      throw const AppUpdateException('Release 链接不受信任');
    }
    return uri;
  }

  static int compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    for (var index = 0; index < 3; index++) {
      final difference = leftParts[index].compareTo(rightParts[index]);
      if (difference != 0) return difference;
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final normalized = _normalizeVersion(value);
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(normalized);
    if (match == null) throw const FormatException('invalid semantic version');
    return [
      for (var index = 1; index <= 3; index++) int.parse(match.group(index)!),
    ];
  }

  static String _normalizeVersion(String value) =>
      value.trim().replaceFirst(RegExp(r'^v'), '').split('+').first;

  static String _requiredString(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field is required');
    }
    return value.trim();
  }

  void close() => _client.close();
}
