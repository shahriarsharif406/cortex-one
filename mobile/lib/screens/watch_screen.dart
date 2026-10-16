import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../widgets/emergency_bar.dart';

/// Coding-agent watch rules (is it running, stalled, did it fail?) and the
/// alerts they raised. View-only: rules are edited in the laptop's config.json.
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.api});

  final CortexApi api;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  WatchSnapshot? _snap;
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
      final snap = await widget.api.watch();
      if (mounted) setState(() => _snap = snap);
    } catch (e) {
      if (!mounted) return;
      await AppScope.of(context).onError(e);
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _when(DateTime t) =>
      '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

  String _kindText(S s, WatchRule r) =>
      s.tf('watch_kind_${r.kind}', {'n': r.minutes});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final scheme = Theme.of(context).colorScheme;
    final snap = _snap;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('watch_title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading && snap == null)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Text(
                s.error(_error!),
                key: const Key('watch_error'),
                style: TextStyle(color: scheme.error),
              ),
            if (snap != null && snap.problems.isNotEmpty)
              Card(
                key: const Key('watch_problems'),
                color: scheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: Text(s.t('watch_problems')),
                ),
              ),
            if (snap != null && snap.rules.isEmpty)
              Text(s.t('watch_empty'), key: const Key('watch_empty')),
            for (final r in snap?.rules ?? const <WatchRule>[])
              ListTile(
                key: Key('watch_rule_${r.name}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  r.isProblem
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  color: r.isProblem ? Colors.orange : Colors.green,
                ),
                title: Text(r.name),
                subtitle: Text(
                  '${_kindText(s, r)} · ${r.target}'
                  '${r.lastAlert == null ? '' : ' · ${_when(r.lastAlert!)}'}',
                ),
                trailing: Text(
                  s.t('watch_state_${r.state}'),
                  key: Key('watch_state_${r.name}'),
                ),
              ),
            if (snap != null) ...[
              const Divider(),
              Text(
                s.t('watch_recent'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (snap.alerts.isEmpty)
                Text(s.t('watch_no_alerts'), key: const Key('watch_no_alerts')),
              for (final a in snap.alerts)
                ListTile(
                  key: Key('watch_alert_${a.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: Text(a.message),
                  subtitle: Text(_when(a.time)),
                ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: EmergencyBar(api: widget.api),
    );
  }
}
