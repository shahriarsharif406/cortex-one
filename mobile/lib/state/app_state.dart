import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../l10n/strings.dart';
import '../storage/stores.dart';
import '../voice/voice_input.dart';

Future<bool> _defaultLaunch(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Thrown by [AppState.pair] when the typed address is not usable.
class InvalidServerAddress implements Exception {
  const InvalidServerAddress([this.messageKey = 'server_invalid']);

  /// Which string explains it: not an address at all, or not a private one.
  final String messageKey;
}

class AppState extends ChangeNotifier {
  AppState({
    required this.secrets,
    required this.prefs,
    required this.apiFactory,
    required this.voice,
    Future<bool> Function(Uri uri)? launchUri,
  }) : launchUri = launchUri ?? _defaultLaunch;

  static const _kToken = 'device_token';
  static const _kServer = 'server_address';

  final SecretStore secrets;
  final PrefsStore prefs;
  final ApiFactory apiFactory;
  final VoiceInput voice;
  final Future<bool> Function(Uri uri) launchUri;

  String lang = 'bn';
  ThemeMode themeMode = ThemeMode.system;
  CortexApi? api;
  bool loaded = false;

  /// A message key shown on the pairing screen (e.g. after the token was revoked).
  String? notice;

  S get s => S(lang);
  bool get paired => api != null;

  Future<void> load() async {
    lang = (await prefs.get('lang')) == 'en' ? 'en' : 'bn';
    themeMode = switch (await prefs.get('theme')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final token = await secrets.read(_kToken);
    final server = await secrets.read(_kServer);
    if (token != null &&
        token.isNotEmpty &&
        server != null &&
        server.isNotEmpty) {
      api = apiFactory(server, token);
    }
    loaded = true;
    notifyListeners();
  }

  /// Exchanges the pairing code for a token and stores it in the secure store.
  Future<void> pair(String serverText, String code) async {
    final base = normalizeServerAddress(serverText);
    if (base == null) {
      final looksPublicHttp = RegExp(r'^http://', caseSensitive: false)
              .hasMatch(serverText.trim()) ||
          !serverText.contains('://');
      final plain = serverText.trim().replaceFirst(
        RegExp(r'^[a-zA-Z]+://'),
        '',
      );
      final host = plain.split(RegExp(r'[:/]')).first;
      throw InvalidServerAddress(
        looksPublicHttp &&
                RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host) &&
                host.contains('.') &&
                !isPrivateOrTailscaleHost(host)
            ? 'server_not_private'
            : 'server_invalid',
      );
    }
    final token = await apiFactory(base, null).pair(code, 'phone');
    await secrets.write(_kToken, token);
    await secrets.write(_kServer, base);
    notice = null;
    api = apiFactory(base, token);
    notifyListeners();
  }

  Future<void> unpair({String? noticeKey}) async {
    await secrets.delete(_kToken);
    await secrets.delete(_kServer);
    api = null;
    notice = noticeKey;
    notifyListeners();
  }

  /// Call from screens for every caught error. A revoked token sends the user
  /// back to pairing; everything else is just shown.
  Future<void> onError(Object error) async {
    if (error is ApiException &&
        error.kind == ApiErrorKind.unauthorized &&
        api != null) {
      await unpair(noticeKey: 'err_unauthorized');
    }
  }

  Future<void> setLang(String value) async {
    lang = value == 'en' ? 'en' : 'bn';
    await prefs.set('lang', lang);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    await prefs.set('theme', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
    notifyListeners();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  /// Like [of], but does not subscribe the widget to changes. Safe in initState
  /// and in async callbacks.
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this widget');
    return scope!.notifier!;
  }

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this widget');
    return scope!.notifier!;
  }
}
