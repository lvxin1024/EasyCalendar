import 'dart:convert';

import 'package:easy_calendar/update/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AppUpdateService.compareVersions', () {
    test('compares semantic version components numerically', () {
      expect(AppUpdateService.compareVersions('1.10.0', '1.9.9'), 1);
      expect(AppUpdateService.compareVersions('v2.0.0', '2.0.0+42'), 0);
      expect(AppUpdateService.compareVersions('0.9.9', '1.0.0'), -1);
    });

    test('rejects versions without three numeric components', () {
      expect(
        () => AppUpdateService.compareVersions('1.0', '1.0.0'),
        throwsFormatException,
      );
    });
  });

  for (final platformAsset in <String, String>{
    'macos': 'EasyCalendar-1.2.0-macos.dmg',
    'windows': 'EasyCalendar-1.2.0-windows-x64-setup.exe',
    'android': 'EasyCalendar-1.2.0-android.apk',
  }.entries) {
    test('selects the ${platformAsset.key} release asset', () async {
      final service = AppUpdateService(
        platform: platformAsset.key,
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.github.com/repos/lvxin1024/EasyCalendar/releases/latest',
          );
          return http.Response(
            jsonEncode(_releaseJson(assets: [platformAsset.value])),
            200,
          );
        }),
      );

      final update = await service.checkForUpdate('1.1.0');

      expect(update.latestVersion, '1.2.0');
      expect(update.updateAvailable, isTrue);
      expect(update.releaseName, 'EasyCalendar 1.2.0');
      expect(update.notes, 'Release notes');
      expect(update.assetName, platformAsset.value);
      expect(
        update.assetUri.toString(),
        'https://github.com/lvxin1024/EasyCalendar/releases/download/v1.2.0/${platformAsset.value}',
      );
      service.close();
    });
  }

  for (final platformAsset in <String, String>{
    'macos': 'EasyCalendar-1.2.0-unsigned-macos.dmg',
    'windows': 'EasyCalendar-1.2.0-unsigned-windows-x64-setup.exe',
  }.entries) {
    test('selects the unsigned ${platformAsset.key} release asset', () async {
      final service = AppUpdateService(
        platform: platformAsset.key,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(_releaseJson(assets: [platformAsset.value])),
            200,
          ),
        ),
      );

      final update = await service.checkForUpdate('1.1.0');

      expect(update.assetName, platformAsset.value);
      expect(
        update.assetUri.toString(),
        'https://github.com/lvxin1024/EasyCalendar/releases/download/v1.2.0/${platformAsset.value}',
      );
      service.close();
    });
  }

  test('ignores assets for other platforms', () async {
    final service = AppUpdateService(
      platform: 'macos',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(
            _releaseJson(assets: ['EasyCalendar-1.2.0-windows-x64-setup.exe']),
          ),
          200,
        ),
      ),
    );

    final update = await service.checkForUpdate('1.2.0');

    expect(update.updateAvailable, isFalse);
    expect(update.assetUri, isNull);
    service.close();
  });

  test('rejects a matching asset hosted outside the repository', () async {
    final payload = _releaseJson(assets: ['EasyCalendar-1.2.0-macos.dmg']);
    final assets = payload['assets']! as List<Map<String, Object>>;
    assets.single['browser_download_url'] =
        'https://example.com/EasyCalendar-1.2.0-macos.dmg';
    final service = AppUpdateService(
      platform: 'macos',
      client: MockClient((_) async => http.Response(jsonEncode(payload), 200)),
    );

    await expectLater(
      service.checkForUpdate('1.0.0'),
      throwsA(
        isA<AppUpdateException>().having(
          (error) => error.message,
          'message',
          'Release 链接不受信任',
        ),
      ),
    );
    service.close();
  });

  test('reports a missing release', () async {
    final service = AppUpdateService(
      client: MockClient((_) async => http.Response('{}', 404)),
    );

    await expectLater(
      service.checkForUpdate('1.0.0'),
      throwsA(
        isA<AppUpdateException>().having(
          (error) => error.message,
          'message',
          '尚未发布可用的 GitHub Release',
        ),
      ),
    );
    service.close();
  });

  test('reports GitHub rate limiting', () async {
    final service = AppUpdateService(
      client: MockClient((_) async => http.Response('{}', 429)),
    );

    await expectLater(
      service.checkForUpdate('1.0.0'),
      throwsA(
        isA<AppUpdateException>().having(
          (error) => error.message,
          'message',
          'GitHub 请求频率受限，请稍后重试',
        ),
      ),
    );
    service.close();
  });
}

Map<String, Object> _releaseJson({required List<String> assets}) => {
  'tag_name': 'v1.2.0',
  'name': 'EasyCalendar 1.2.0',
  'body': 'Release notes',
  'html_url': 'https://github.com/lvxin1024/EasyCalendar/releases/tag/v1.2.0',
  'assets': [
    for (final name in assets)
      <String, Object>{
        'name': name,
        'browser_download_url':
            'https://github.com/lvxin1024/EasyCalendar/releases/download/v1.2.0/$name',
      },
  ],
};
