import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';

/// Read-only list of what the agent did (and refused to do).
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key, required this.api});

  final CortexApi api;

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  List<AuditEntry>? _entries;
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
      final rows = await widget.api.audit(limit: 100);
      if (mounted) setState(() => _entries = rows);
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
    final entries = _entries;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            s.t('audit_title'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (_loading && entries == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Text(
              s.error(_error!),
              key: const Key('audit_error'),
              style: TextStyle(color: scheme.error),
            ),
          if (entries != null && entries.isEmpty)
            Text(s.t('audit_empty'), key: const Key('audit_empty')),
          for (final e in entries ?? const <AuditEntry>[])
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                switch (e.status) {
                  'ok' => Icons.check_circle_outline,
                  'pending' => Icons.hourglass_top,
                  'failed' || 'error' => Icons.error_outline,
                  _ => Icons.block,
                },
                color: switch (e.status) {
                  'ok' => Colors.green,
                  'pending' => Colors.orange,
                  _ => scheme.error,
                },
              ),
              title: Text('${e.action}  ·  ${e.status}'),
              subtitle: Text(
                '${_two(e.time.month)}-${_two(e.time.day)} ${_two(e.time.hour)}:${_two(e.time.minute)}'
                '  ${e.via}  ${e.actor}\n${e.detail}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: e.detail.isNotEmpty,
            ),
        ],
      ),
    );
  }
}
