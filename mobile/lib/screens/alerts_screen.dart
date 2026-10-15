import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../widgets/emergency_bar.dart';

String alertText(S s, AlertEntry a) {
  final key = 'alert_${a.kind}';
  const known = {
    'alert_ac_lost',
    'alert_ac_restored',
    'alert_battery_warn',
    'alert_battery_critical',
    'alert_critical_action',
  };
  final pct = a.batteryPercent == null ? '' : ' (${a.batteryPercent}%)';
  return known.contains(key) ? '${s.t(key)}$pct' : a.message;
}

/// Power-cut / low-battery alerts recorded by the laptop's watcher.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, required this.api});

  final CortexApi api;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<AlertEntry>? _rows;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.api.alerts(limit: 50);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (!mounted) return;
      await AppScope.of(context).onError(e);
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('alerts_title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading && rows == null)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Text(
                s.error(_error!),
                key: const Key('alerts_error'),
                style: TextStyle(color: scheme.error),
              ),
            if (rows != null && rows.isEmpty)
              Text(s.t('alerts_empty'), key: const Key('alerts_empty')),
            for (final a in rows ?? const <AlertEntry>[])
              ListTile(
                key: Key('alert_${a.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  a.isProblem ? Icons.bolt : Icons.power,
                  color: a.isProblem ? Colors.orange : Colors.green,
                ),
                title: Text(alertText(s, a)),
                subtitle: Text(
                  '${_two(a.time.month)}-${_two(a.time.day)} '
                  '${_two(a.time.hour)}:${_two(a.time.minute)}',
                ),
              ),
          ],
        ),
      ),
      // the emergency stop is on every screen, including this pushed one
      bottomNavigationBar: EmergencyBar(api: widget.api),
    );
  }
}
