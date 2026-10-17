import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../screens/sms_help_screen.dart' show smsUri;
import '../state/app_state.dart';
import '../state/computer.dart';
import '../state/computer_monitor.dart';
import '../state/power_state.dart';

/// Wake / Sleep / Hibernate / Shut down / Restart / Lock for one computer.
///
/// The four risky ones show exactly what will happen, then need the phone's biometric or
/// PIN, and only then use the agent's own two-step confirmation (request, then confirm).
class PowerCard extends StatefulWidget {
  const PowerCard({
    super.key,
    required this.computer,
    required this.api,
    required this.monitor,
  });

  final Computer computer;
  final CortexApi api;
  final ComputerMonitor monitor;

  @override
  State<PowerCard> createState() => _PowerCardState();
}

class _PowerCardState extends State<PowerCard> {
  bool _busy = false;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _guard<T>(Future<T> Function() job) async {
    final app = AppScope.read(context);
    setState(() => _busy = true);
    try {
      return await job();
    } catch (e) {
      await app.onError(e);
      _snack(app.s.error(e));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- risky
  Future<void> _risky(String action) async {
    final app = AppScope.read(context);
    final s = app.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: Key('power_dialog_$action'),
        title: Text('${s.t('p_$action')} — ${widget.computer.name}'),
        content: Text(s.t('will_$action'), key: const Key('power_dialog_text')),
        actions: [
          TextButton(
            key: const Key('power_dialog_cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            key: const Key('power_dialog_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('power_confirm_btn')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await app.authorize('auth_reason_power')) {
      _snack(s.t('auth_failed'));
      return;
    }
    await _guard(() async {
      final first = await widget.api.requestAction(action);
      final out = first.ticket != null
          ? await widget.api.confirmAction(action, first.ticket!.token)
          : first.outcome!;
      if (out.ok) widget.monitor.notePhoneRequested(action);
      _snack(out.ok ? '${s.t('power_done')}: ${out.message}' : out.message);
    });
  }

  Future<void> _lock() => _guard(() async {
    final out = await widget.api.runAction('lock');
    _snack(out.message);
  });

  // ----------------------------------------------------------------- wake
  Future<void> _wake() async {
    final app = AppScope.read(context);
    final s = app.s;
    if (widget.monitor.status.state == PowerState.online) {
      _snack(s.t('wake_online_already'));
      return;
    }
    final c = widget.computer;
    final helper = app.computerNamed(c.wakeVia);
    final gateway = c.wakeGateway;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          key: const Key('wake_sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Text(s.t('wake_title'), style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(s.t('wake_intro'), style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (helper != null)
              ListTile(
                key: const Key('wake_method_via'),
                leading: const Icon(Icons.lan_outlined),
                title: Text(s.tf('wake_via', {'name': helper.name})),
                subtitle: Text(s.tf('wake_via_needs', {'name': helper.name})),
                onTap: () {
                  Navigator.pop(ctx);
                  _wakeViaHelper(helper);
                },
              ),
            if (gateway != null)
              ListTile(
                key: const Key('wake_method_gateway'),
                leading: const Icon(Icons.smart_button_outlined),
                title: Text(s.t('wake_gateway')),
                subtitle: Text(s.t('wake_gateway_needs')),
                onTap: () {
                  Navigator.pop(ctx);
                  _wakeViaGateway(gateway);
                },
              ),
            ListTile(
              key: const Key('wake_method_sms'),
              leading: const Icon(Icons.sms_outlined),
              title: Text(s.t('wake_sms')),
              subtitle: Text(s.t('wake_sms_needs')),
              onTap: () {
                Navigator.pop(ctx);
                _wakeViaSms();
              },
            ),
            if (helper == null && gateway == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s.t('wake_none'), key: const Key('wake_none')),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _wakeViaHelper(Computer helper) async {
    final app = AppScope.read(context);
    final s = app.s;
    await _guard(() async {
      final out = await app.apiFor(helper).runAction('wake_computer', {
        'name': widget.computer.name.toLowerCase(),
      });
      _snack(out.ok ? s.t('wake_sent') : '${s.t('wake_failed')}: ${out.message}');
    });
  }

  Future<void> _wakeViaGateway(WakeGateway gateway) async {
    final app = AppScope.read(context);
    final s = app.s;
    if (!await app.authorize('auth_reason_power')) {
      _snack(s.t('auth_failed'));
      return;
    }
    await _guard(() async {
      final st = await app.gateway.status(gateway);
      var force = false;
      if (st.ok && st.laptopState == 'on') {
        _snack(s.t('wake_laptop_on'));
        return;
      }
      if (!st.ok || st.laptopState == 'unknown') {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            key: const Key('wake_force_dialog'),
            content: Text(s.t('wake_force_q')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(s.t('no')),
              ),
              TextButton(
                key: const Key('wake_force_yes'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(s.t('yes')),
              ),
            ],
          ),
        );
        if (go != true) return;
        force = true;
      }
      final out = await app.gateway.press(gateway, force: force);
      _snack(out.ok ? s.t('wake_sent') : '${s.t('wake_failed')}: ${out.message}');
    });
  }

  Future<void> _wakeViaSms() async {
    final app = AppScope.read(context);
    final s = app.s;
    final number = await app.prefs.get('sms_number');
    if (number == null || number.trim().isEmpty) {
      _snack(s.t('wake_no_sms'));
      return;
    }
    // Only "ON " is prefilled: the one-time code is typed by the owner, never by the app.
    final ok = await app.launchUri(smsUri(number.trim(), 'ON'));
    if (!ok) _snack(s.t('sms_cannot_open'));
  }

  // ----------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final scheme = Theme.of(context).colorScheme;
    Widget button(String key, IconData icon, String label, VoidCallback? on,
        {bool danger = false}) {
      final style = danger
          ? OutlinedButton.styleFrom(foregroundColor: scheme.error)
          : null;
      return OutlinedButton.icon(
        key: Key(key),
        style: style,
        onPressed: _busy ? null : on,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
    }

    return Card(
      key: const Key('power_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('power_title'), style: Theme.of(context).textTheme.titleMedium),
            Text(s.t('power_note'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                button('power_wake', Icons.power_settings_new, s.t('p_wake'), _wake),
                button('power_sleep', Icons.bedtime_outlined, s.t('p_sleep'),
                    () => _risky('sleep')),
                button('power_hibernate', Icons.ac_unit, s.t('p_hibernate'),
                    () => _risky('hibernate'), danger: true),
                button('power_shutdown', Icons.stop_circle_outlined, s.t('p_shutdown'),
                    () => _risky('shutdown'), danger: true),
                button('power_restart', Icons.restart_alt, s.t('p_restart'),
                    () => _risky('restart'), danger: true),
                button('power_lock', Icons.lock_outline, s.t('p_lock'), _lock),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
