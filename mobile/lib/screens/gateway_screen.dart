import 'dart:convert';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../wake/gateway_config.dart';
import '../wake/gateway_http.dart';
import '../wake/gateway_runtime.dart' show gatewayEventsKey;
import '../wake/sms_command.dart';

/// Gateway mode: this phone (with a SIM) turns an SMS or an authenticated request into a press of
/// the laptop's power button through the ESP32. Everything is OFF until the owner reads the
/// explanation, grants the permissions and starts it here.
class GatewaySetupScreen extends StatefulWidget {
  const GatewaySetupScreen({super.key});

  @override
  State<GatewaySetupScreen> createState() => _GatewaySetupScreenState();
}

class _GatewaySetupScreenState extends State<GatewaySetupScreen> {
  GatewayConfig _cfg = const GatewayConfig();
  final _numbers = TextEditingController();
  final _bind = TextEditingController();
  bool _perm = false;
  bool _running = false;
  bool _loaded = false;
  String? _error;
  List<Map<String, dynamic>> _events = const [];

  late final GatewayConfigStore _store = GatewayConfigStore(AppScope.read(context).secrets);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _numbers.dispose();
    _bind.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final cfg = await _store.load();
    final perm = await app.gatewayPlatform.hasPermissions();
    final running = await app.gatewayPlatform.isRunning();
    var events = <Map<String, dynamic>>[];
    try {
      final raw = await app.prefs.get(gatewayEventsKey);
      if (raw != null) {
        events = [
          for (final e in jsonDecode(raw) as List)
            if (e is Map) Map<String, dynamic>.from(e),
        ];
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _numbers.text = cfg.allowedNumbers.join('\n');
      _bind.text = cfg.httpBind;
      _perm = perm;
      _running = running;
      _events = events;
      _loaded = true;
    });
  }

  Future<void> _requestPermissions() async {
    final app = AppScope.read(context);
    final ok = await app.gatewayPlatform.requestPermissions();
    if (!mounted) return;
    setState(() {
      _perm = ok;
      _error = ok ? null : app.s.t('gw_perm_denied');
    });
  }

  /// Validates and stores the numbers and the listener address. Returns false (with a message)
  /// when something is not acceptable; nothing is saved then.
  Future<bool> _saveFields() async {
    final s = AppScope.read(context).s;
    final nums = <String>[];
    for (final line in _numbers.text.split(RegExp(r'[\n,;]'))) {
      if (line.trim().isEmpty) continue;
      final n = normalizePhone(line);
      if (n == null) {
        setState(() => _error = s.t('gw_numbers_invalid'));
        return false;
      }
      if (!nums.contains(n)) nums.add(n);
    }
    var bind = _bind.text.trim();
    if (bind.isNotEmpty) {
      final ok = checkGatewayBind(bind);
      if (ok == null) {
        setState(() => _error = s.t('gw_bind_invalid'));
        return false;
      }
      bind = ok;
    }
    _cfg = _cfg.copyWith(allowedNumbers: nums, httpBind: bind);
    await _store.save(_cfg);
    if (mounted) setState(() => _error = null);
    return true;
  }

  Future<void> _create() async {
    final s = AppScope.read(context).s;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('gw_create_warn')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('no'))),
          TextButton(
            key: const Key('gw_create_yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('yes')),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final fresh = NewGatewaySecrets.generate();
    _cfg = _cfg.copyWith(
      wakeSecretB32: fresh.wakeSecretB32,
      bleKeyHex: fresh.bleKeyHex,
      deviceIdHex: fresh.deviceIdHex,
      httpToken: fresh.httpToken,
    );
    await _store.save(_cfg);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const Key('gw_secrets_dialog'),
        title: Text(s.t('gw_secrets_title')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('gw_secrets_once')),
              const SizedBox(height: 12),
              Text(s.t('gw_secret_wake'), style: Theme.of(ctx).textTheme.labelMedium),
              SelectableText(fresh.wakeSecretB32, key: const Key('gw_show_wake')),
              const SizedBox(height: 8),
              Text(s.t('gw_secret_fw'), style: Theme.of(ctx).textTheme.labelMedium),
              SelectableText(
                fresh.firmwareText(),
                key: const Key('gw_show_fw'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              const SizedBox(height: 8),
              Text(s.t('gw_secret_token'), style: Theme.of(ctx).textTheme.labelMedium),
              SelectableText(fresh.httpToken, key: const Key('gw_show_token')),
            ],
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('gw_secrets_done'),
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('gw_done')),
          ),
        ],
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    final app = AppScope.read(context);
    final s = app.s;
    if (_running) {
      await app.gatewayPlatform.stopService();
      _cfg = _cfg.copyWith(enabled: false);
      await _store.save(_cfg);
      if (mounted) setState(() => _running = false);
      return;
    }
    if (!await _saveFields()) return;
    if (!_cfg.hasSecrets || _cfg.allowedNumbers.isEmpty) {
      setState(() => _error = s.t('gw_need_setup'));
      return;
    }
    if (!_perm && !await app.gatewayPlatform.requestPermissions()) {
      if (mounted) setState(() => _error = s.t('gw_perm_denied'));
      return;
    }
    _cfg = _cfg.copyWith(enabled: true);
    await _store.save(_cfg);
    await app.gatewayPlatform.startService();
    if (mounted) {
      setState(() {
        _perm = true;
        _running = true;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gw_title'))),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(s.t('gw_why'), key: const Key('gw_why')),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      _perm ? Icons.check_circle : Icons.warning_amber,
                      color: _perm ? Colors.green : scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _perm ? s.t('gw_perm_ok') : s.t('gw_perm_missing'),
                        key: const Key('gw_perm_state'),
                      ),
                    ),
                    if (!_perm)
                      FilledButton(
                        key: const Key('gw_perm_button'),
                        onPressed: _requestPermissions,
                        child: Text(s.t('gw_perm_btn')),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('gw_numbers'),
                  controller: _numbers,
                  minLines: 2,
                  maxLines: 4,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: s.t('gw_numbers_label'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('gw_bind'),
                  controller: _bind,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: s.t('gw_bind_label'),
                    hintText: '100.x.y.z',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      key: const Key('gw_save'),
                      onPressed: () async {
                        if (await _saveFields() && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(s.t('gw_saved'))),
                          );
                        }
                      },
                      child: Text(s.t('gw_save')),
                    ),
                    OutlinedButton(
                      key: const Key('gw_create'),
                      onPressed: _create,
                      child: Text(s.t('gw_create')),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      key: const Key('gw_error'),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                const Divider(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _running ? s.t('gw_running') : s.t('gw_stopped'),
                        key: const Key('gw_state'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    FilledButton(
                      key: const Key('gw_toggle'),
                      onPressed: _toggle,
                      child: Text(_running ? s.t('gw_stop') : s.t('gw_start')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(s.t('gw_log_title'), style: Theme.of(context).textTheme.labelLarge),
                if (_events.isEmpty)
                  Text(s.t('gw_log_empty'), key: const Key('gw_log_empty'))
                else
                  for (final e in _events)
                    Text(
                      '${DateTime.fromMillisecondsSinceEpoch((e['t'] as num?)?.toInt() ?? 0).toString().substring(0, 19)}  ${e['k']} ${e['n'] ?? ''}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
              ],
            ),
    );
  }
}
