import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/failover_api.dart';
import '../l10n/strings.dart';
import '../storage/stores.dart';
import '../voice/voice_input.dart';
import 'computer.dart';
import 'computer_monitor.dart';
import 'device_services.dart';

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
    BiometricGate? biometrics,
    LinkMonitor? links,
    this.attemptTimeout = const Duration(seconds: 5),
    this.monitorEverySeconds = 20,
  }) : launchUri = launchUri ?? _defaultLaunch,
       biometrics = biometrics ?? LocalAuthGate(),
       links = links ?? NoLinkMonitor();

  static const _kComputers = 'computers';
  // Older single-computer builds stored these two. They are migrated, then deleted.
  static const _kToken = 'device_token';
  static const _kServer = 'server_address';

  final SecretStore secrets;
  final PrefsStore prefs;
  final ApiFactory apiFactory;
  final VoiceInput voice;
  final Future<bool> Function(Uri uri) launchUri;
  final BiometricGate biometrics;
  final LinkMonitor links;
  final Duration attemptTimeout;
  final int monitorEverySeconds;

  String lang = 'bn';
  ThemeMode themeMode = ThemeMode.system;
  bool loaded = false;

  List<Computer> computers = const [];
  int _current = 0;
  final Map<String, FailoverApi> _apis = {};
  final Map<String, ComputerMonitor> _monitors = {};
  StreamSubscription<bool>? _linkSub;

  /// 'auto' (on while the phone is on mobile data), 'on', or 'off'.
  String dataSaverMode = 'auto';
  bool onMobile = false;

  /// A message key shown on the pairing screen (e.g. after the token was revoked).
  String? notice;

  S get s => S(lang);
  bool get paired => computers.isNotEmpty;
  Computer? get current => computers.isEmpty
      ? null
      : computers[_current.clamp(0, computers.length - 1)];

  /// The API of the computer being shown (tries its addresses in order).
  CortexApi? get api => current == null ? null : apiFor(current!);

  bool get dataSaver =>
      dataSaverMode == 'on' || (dataSaverMode == 'auto' && onMobile);

  // ----------------------------------------------------------- per computer
  FailoverApi apiFor(Computer c) => _apis.putIfAbsent(
    c.id,
    () => FailoverApi(
      endpoints: c.endpoints,
      token: c.token,
      factory: apiFactory,
      attemptTimeout: attemptTimeout,
      onWorked: (e) => unawaited(secrets.write('last_ep_${c.id}', e)),
    ),
  );

  /// The background health check of [c] (created on first use, shared afterwards).
  ComputerMonitor monitorFor(Computer c) => _monitors.putIfAbsent(c.id, () {
    final m = ComputerMonitor(
      computer: c,
      api: apiFor(c),
      prefs: prefs,
      everySeconds: monitorEverySeconds,
      autoRefresh: !dataSaver,
      onError: onError,
    );
    unawaited(m.start());
    return m;
  });

  Computer? computerNamed(String? name) {
    if (name == null) return null;
    for (final c in computers) {
      if (c.name.toLowerCase() == name.toLowerCase()) return c;
    }
    return null;
  }

  void selectComputer(int index) {
    if (index < 0 || index >= computers.length || index == _current) return;
    _current = index;
    prefs.set('current_computer', computers[index].id);
    notifyListeners();
  }

  // -------------------------------------------------------------- lifecycle
  Future<void> load() async {
    lang = (await prefs.get('lang')) == 'en' ? 'en' : 'bn';
    themeMode = switch (await prefs.get('theme')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    dataSaverMode = switch (await prefs.get('data_saver')) {
      'on' => 'on',
      'off' => 'off',
      _ => 'auto',
    };
    computers = decodeComputers(await secrets.read(_kComputers));
    if (computers.isEmpty) {
      final token = await secrets.read(_kToken);
      final server = await secrets.read(_kServer);
      if (token != null &&
          token.isNotEmpty &&
          server != null &&
          server.isNotEmpty) {
        computers = [
          Computer(
            id: _newId(),
            name: 'Laptop',
            endpoints: [server],
            token: token,
            allowLanHttp: isPrivateLanHost(Uri.tryParse(server)?.host ?? ''),
          ),
        ];
        await _save();
      }
      await secrets.delete(_kToken);
      await secrets.delete(_kServer);
    }
    final wanted = await prefs.get('current_computer');
    final i = computers.indexWhere((c) => c.id == wanted);
    _current = i < 0 ? 0 : i;
    for (final c in computers) {
      // remember which address worked last time, so it is tried first
      final last = await secrets.read('last_ep_${c.id}');
      if (last != null && c.endpoints.contains(last)) {
        _apis[c.id] = FailoverApi(
          endpoints: c.endpoints,
          token: c.token,
          factory: apiFactory,
          lastWorking: last,
          attemptTimeout: attemptTimeout,
          onWorked: (e) => unawaited(secrets.write('last_ep_${c.id}', e)),
        );
      }
    }
    onMobile = await links.isOnMobile();
    _linkSub ??= links.onMobileChanges.listen((mobile) {
      onMobile = mobile;
      _applyDataSaver();
      notifyListeners();
    });
    loaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    for (final m in _monitors.values) {
      m.dispose();
    }
    super.dispose();
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(
      8,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _save() => secrets.write(_kComputers, encodeComputers(computers));

  // ---------------------------------------------------------------- pairing
  /// Exchanges the pairing code for a token and stores the new computer in the secure store.
  /// [lanText] is an optional second address; plain http to a home-LAN address needs
  /// [allowLan] (the owner says it is their own network: the token travels unencrypted there).
  Future<void> pair(
    String serverText,
    String code, {
    String? name,
    String? lanText,
    bool allowLan = false,
  }) async {
    final base = _normalizeOrThrow(serverText, allowLan);
    final endpoints = [base];
    if (lanText != null && lanText.trim().isNotEmpty) {
      final lan = _normalizeOrThrow(lanText, allowLan);
      if (!endpoints.contains(lan)) endpoints.add(lan);
    }
    final token = await apiFactory(base, null).pair(code, 'phone');
    var title = (name ?? '').trim();
    if (title.isEmpty) {
      try {
        title = (await apiFactory(base, token).health()).computerName.trim();
      } catch (_) {
        title = '';
      }
    }
    if (title.isEmpty) title = 'Computer ${computers.length + 1}';
    final computer = Computer(
      id: _newId(),
      name: title,
      endpoints: endpoints,
      token: token,
      allowLanHttp: allowLan,
    );
    // pairing the same address again replaces the old record instead of duplicating it
    final old = computers.indexWhere(
      (c) => c.endpoints.any(endpoints.contains),
    );
    if (old >= 0) await _forget(computers[old], notify: false);
    computers = [...computers, computer];
    await _save();
    _current = computers.length - 1;
    await prefs.set('current_computer', computer.id);
    notice = null;
    notifyListeners();
  }

  String _normalizeOrThrow(String text, bool allowLan) {
    final base = normalizeServerAddress(text, allowLan: allowLan);
    if (base != null) return base;
    final looksPublicHttp =
        RegExp(r'^http://', caseSensitive: false).hasMatch(text.trim()) ||
        !text.contains('://');
    final plain = text.trim().replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    final host = plain.split(RegExp(r'[:/]')).first;
    throw InvalidServerAddress(
      looksPublicHttp &&
              RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host) &&
              host.contains('.') &&
              !isPrivateOrTailscaleHost(host)
          ? (isPrivateLanHost(host) ? 'server_lan_needs_ok' : 'server_not_private')
          : 'server_invalid',
    );
  }

  /// Changes the addresses / wake settings of one computer. Addresses are validated again.
  Future<void> updateComputer(Computer updated) async {
    final i = computers.indexWhere((c) => c.id == updated.id);
    if (i < 0) return;
    for (final e in updated.endpoints) {
      if (normalizeServerAddress(e, allowLan: updated.allowLanHttp) != e) {
        throw const InvalidServerAddress();
      }
    }
    computers = [...computers]..[i] = updated;
    _apis.remove(updated.id);
    _monitors.remove(updated.id)?.dispose();
    await _save();
    notifyListeners();
  }

  Future<void> _forget(Computer c, {bool notify = true}) async {
    computers = [
      for (final x in computers)
        if (x.id != c.id) x,
    ];
    _apis.remove(c.id);
    _monitors.remove(c.id)?.dispose();
    await secrets.delete('last_ep_${c.id}');
    await prefs.set('seen_${c.id}', '{}');
    await _save();
    if (_current >= computers.length) _current = 0;
    if (notify) notifyListeners();
  }

  /// Removes the computer that is on screen (and its token from this phone).
  Future<void> unpair({String? noticeKey}) async {
    final c = current;
    if (c != null) await _forget(c, notify: false);
    notice = noticeKey;
    notifyListeners();
  }

  /// Removes any one computer from this phone.
  Future<void> removeComputer(Computer c) => _forget(c);

  /// Call from screens for every caught error. A revoked token sends the user
  /// back to pairing; everything else is just shown.
  Future<void> onError(Object error) async {
    if (error is ApiException &&
        error.kind == ApiErrorKind.unauthorized &&
        current != null) {
      await unpair(noticeKey: 'err_unauthorized');
    }
  }

  // ------------------------------------------------------------ preferences
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

  Future<void> setDataSaverMode(String mode) async {
    dataSaverMode = mode == 'on' || mode == 'off' ? mode : 'auto';
    await prefs.set('data_saver', dataSaverMode);
    _applyDataSaver();
    notifyListeners();
  }

  void _applyDataSaver() {
    for (final m in _monitors.values) {
      m.setAutoRefresh(!dataSaver);
    }
  }

  // ------------------------------------------------------------ confirmation
  /// Every confirmation of a risky action passes through the phone's own biometric /
  /// screen-lock prompt. Returns true only when the owner proved it is them.
  Future<bool> authorize(String reasonKey) =>
      biometrics.authenticate(s.t(reasonKey));

  /// "Tailscale" / "home Wi-Fi (LAN)" / "SIM (data-saver)" for the link now in use.
  String? linkLabelKey(Computer c) {
    final a = apiFor(c);
    if (a.activeEndpoint == null) return null;
    final kind = a.activeKind;
    if (kind == 'lan') return 'link_lan';
    return onMobile ? 'link_sim' : 'link_tailscale';
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
