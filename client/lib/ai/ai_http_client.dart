import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createAiHttpClient(String? proxyUrl) {
  final value = proxyUrl?.trim() ?? '';
  if (value.isEmpty) return http.Client();
  final proxy = Uri.parse(value);
  if (proxy.scheme != 'http' ||
      !proxy.hasAuthority ||
      proxy.host.isEmpty ||
      proxy.userInfo.isNotEmpty) {
    throw const FormatException('代理地址必须是无凭据的 HTTP URL');
  }
  final port = proxy.hasPort ? proxy.port : 80;
  final ioClient = HttpClient()..findProxy = (_) => 'PROXY ${proxy.host}:$port';
  return IOClient(ioClient);
}
