import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

enum ApiErrorKind {
  network, // laptop not reachable
  timeout,
  unauthorized, // token missing / revoked
  forbidden, // wrong or expired code / confirmation
  notFound,
  invalid,
  rateLimited,
  unavailable, // e.g. AI not set up, budget used up, another task running
  server,
  badResponse,
}

/// A failure that is safe to show. [detail] is the agent's own English message.
class ApiException implements Exception {
  const ApiException(this.kind, {this.detail = '', this.statusCode});

  final ApiErrorKind kind;
  final String detail;
  final int? statusCode;

  @override
  String toString() => 'ApiException($kind, $statusCode)';
}

/// What the screens use. Tests plug in a fake; the app uses [HttpCortexApi].
abstract class CortexApi {
  /// Exchanges a 6-digit pairing code for a device token (stored by the caller).
  Future<String> pair(String code, String deviceName);
  Future<ActionOutcome> runAction(
    String name, [
    Map<String, String> params = const {},
  ]);
  Future<ActionOutcome> emergencyStop();
  Future<String> startTask(String instruction);
  Future<TaskStatus> getTask(String id);
  Future<List<PendingItem>> pending();
  Future<ActionOutcome> confirm(String confirmToken);
  Future<void> cancel(String confirmToken);
  Future<List<AuditEntry>> audit({int limit = 50});
  Future<Capabilities> capabilities();
  Future<List<AlertEntry>> alerts({int limit = 20});

  /// Newest-first names of the agent's screenshots.
  Future<List<ScreenshotInfo>> screenshots();

  /// The image bytes; [width] asks the agent to downscale (smaller download).
  Future<Uint8List> screenshotBytes(String name, {int? width});
}

typedef ApiFactory = CortexApi Function(String baseUrl, String? token);

/// Plain http is only acceptable on the owner's own network: loopback, private
/// LAN ranges, Tailscale (100.64.0.0/10, *.ts.net) and the Android emulator.
/// Android's network security config cannot express IP ranges, so this is the
/// place where "no cleartext to the public internet" is enforced.
bool isPrivateOrTailscaleHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.ts.net')) return true;
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
  if (m == null) return false;
  final o = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
  if (o.any((n) => n > 255)) return false;
  return o[0] == 10 ||
      o[0] == 127 ||
      (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
      (o[0] == 192 && o[1] == 168) ||
      (o[0] == 100 && o[1] >= 64 && o[1] <= 127);
}

/// "100.64.1.2" -> "http://100.64.1.2:8765"; keeps an explicit scheme/port.
/// Returns null when the text is not a usable address.
String? normalizeServerAddress(String raw) {
  var text = raw.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return null;
  }
  if (uri.userInfo.isNotEmpty || (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  if (uri.scheme == 'http' && !isPrivateOrTailscaleHost(uri.host)) return null;
  final port = uri.hasPort ? uri.port : 8765;
  return '${uri.scheme}://${uri.host.contains(':') ? '[${uri.host}]' : uri.host}:$port';
}

class HttpCortexApi implements CortexApi {
  HttpCortexApi(
    this.baseUrl,
    this.token, {
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final Duration timeout;
  final http.Client _client;

  Future<http.Response> _request(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Map<String, String> extraHeaders = const {},
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      if (method != 'GET') 'Content-Type': 'application/json; charset=utf-8',
      if (auth && token != null) 'Authorization': 'Bearer $token',
      ...extraHeaders,
    };
    http.Response response;
    try {
      final call = method == 'GET'
          ? _client.get(uri, headers: headers)
          : _client.post(
              uri,
              headers: headers,
              body: jsonEncode(body ?? const {}),
            );
      response = await call.timeout(timeout);
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.timeout);
    } on SocketException {
      throw const ApiException(ApiErrorKind.network);
    } on http.ClientException {
      throw const ApiException(ApiErrorKind.network);
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    dynamic decoded;
    try {
      final text = utf8.decode(response.bodyBytes);
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    final detail = decoded is Map && decoded['detail'] is String
        ? decoded['detail'] as String
        : '';
    final kind = switch (response.statusCode) {
      401 => ApiErrorKind.unauthorized,
      403 => ApiErrorKind.forbidden,
      404 => ApiErrorKind.notFound,
      422 => ApiErrorKind.invalid,
      429 => ApiErrorKind.rateLimited,
      503 => ApiErrorKind.unavailable,
      _ => ApiErrorKind.server,
    };
    throw ApiException(kind, detail: detail, statusCode: response.statusCode);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final response = await _request(method, path, body: body, auth: auth);
    dynamic decoded;
    try {
      final text = utf8.decode(response.bodyBytes);
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (decoded == null) {
      throw ApiException(
        ApiErrorKind.badResponse,
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _obj(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    throw const ApiException(ApiErrorKind.badResponse);
  }

  List<dynamic> _list(dynamic v) {
    if (v is List) return v;
    throw const ApiException(ApiErrorKind.badResponse);
  }

  @override
  Future<String> pair(String code, String deviceName) async {
    final j = _obj(
      await _send(
        'POST',
        '/pair',
        body: {'code': code, 'device_name': deviceName},
        auth: false,
      ),
    );
    final t = j['token'];
    if (t is! String || t.isEmpty) {
      throw const ApiException(ApiErrorKind.badResponse);
    }
    return t;
  }

  @override
  Future<ActionOutcome> runAction(
    String name, [
    Map<String, String> params = const {},
  ]) async => ActionOutcome.fromJson(
    _obj(await _send('POST', '/actions/$name', body: {'params': params})),
  );

  @override
  Future<ActionOutcome> emergencyStop() async =>
      ActionOutcome.fromJson(_obj(await _send('POST', '/emergency-stop')));

  @override
  Future<String> startTask(String instruction) async {
    final j = _obj(
      await _send(
        'POST',
        '/ai/tasks',
        body: {'instruction': instruction, 'wait': false},
      ),
    );
    final id = j['id'];
    if (id is! String || id.isEmpty) {
      throw const ApiException(ApiErrorKind.badResponse);
    }
    return id;
  }

  @override
  Future<TaskStatus> getTask(String id) async => TaskStatus.fromJson(
    _obj(await _send('GET', '/ai/tasks/${Uri.encodeComponent(id)}')),
  );

  @override
  Future<List<PendingItem>> pending() async => [
    for (final p in _list(await _send('GET', '/ai/pending')))
      if (p is Map) PendingItem.fromJson(Map<String, dynamic>.from(p)),
  ];

  @override
  Future<ActionOutcome> confirm(String confirmToken) async =>
      ActionOutcome.fromJson(
        _obj(
          await _send(
            'POST',
            '/ai/confirm',
            body: {'confirm_token': confirmToken},
          ),
        ),
      );

  @override
  Future<void> cancel(String confirmToken) async {
    await _send('POST', '/ai/cancel', body: {'confirm_token': confirmToken});
  }

  @override
  Future<List<AuditEntry>> audit({int limit = 50}) async => [
    for (final e in _list(await _send('GET', '/audit?limit=$limit')))
      if (e is Map) AuditEntry.fromJson(Map<String, dynamic>.from(e)),
  ];

  @override
  Future<Capabilities> capabilities() async =>
      Capabilities.fromJson(_obj(await _send('GET', '/capabilities')));

  @override
  Future<List<AlertEntry>> alerts({int limit = 20}) async => [
    for (final e in _list(await _send('GET', '/alerts?limit=$limit')))
      if (e is Map) AlertEntry.fromJson(Map<String, dynamic>.from(e)),
  ];

  @override
  Future<List<ScreenshotInfo>> screenshots() async {
    final j = _obj(await _send('GET', '/screenshots'));
    return [
      for (final e in (j['files'] as List? ?? const []))
        if (e is Map) ScreenshotInfo.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  @override
  Future<Uint8List> screenshotBytes(String name, {int? width}) async {
    final q = width == null ? '' : '?width=$width';
    final response = await _request(
      'GET',
      '/screenshots/${Uri.encodeComponent(name)}$q',
      extraHeaders: const {'Accept': 'image/*'},
    );
    if (response.bodyBytes.isEmpty) {
      throw const ApiException(ApiErrorKind.badResponse);
    }
    return response.bodyBytes;
  }
}
