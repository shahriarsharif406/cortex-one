import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../state/computer.dart';

/// Coding sessions (start / stop / list) and the RustDesk helper (status / start / open the
/// phone app). Starting or stopping anything shows what will happen, needs the phone's biometric
/// or PIN, and then goes through the agent's two-step confirmation.
class ToolsCard extends StatefulWidget {
  const ToolsCard({super.key, required this.computer, required this.api});

  final Computer computer;
  final CortexApi api;

  @override
  State<ToolsCard> createState() => _ToolsCardState();
}

class _ToolsCardState extends State<ToolsCard> {
  List<Map<String, dynamic>>? _projects;
  bool _busy = false;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _guard(Future<void> Function() job) async {
    final app = AppScope.read(context);
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      await app.onError(e);
      _snack(app.s.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _list() => _guard(() async {
    final out = await widget.api.runAction('coding_session_list');
    final rows = out.data['projects'];
    if (mounted) {
      setState(() => _projects = [
        if (rows is List)
          for (final r in rows)
            if (r is Map) Map<String, dynamic>.from(r),
      ]);
    }
  });

  /// dialog -> biometric -> request -> confirm. Nothing is sent before the owner agrees.
  Future<void> _risky(String action, Map<String, String> params, String title, String body,
      {String keyPrefix = 'tools'}) async {
    final app = AppScope.read(context);
    final s = app.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: Key('${keyPrefix}_dialog_$action'),
        title: Text(title),
        content: Text(body, key: const Key('tools_dialog_text')),
        actions: [
          TextButton(
            key: const Key('tools_dialog_cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            key: const Key('tools_dialog_confirm'),
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
      final first = await widget.api.requestAction(action, params);
      final out = first.ticket != null
          ? await widget.api.confirmAction(action, first.ticket!.token, params)
          : first.outcome!;
      _snack(out.message);
      if (action.startsWith('coding_')) {
        final again = await widget.api.runAction('coding_session_list');
        final rows = again.data['projects'];
        if (mounted && rows is List) {
          setState(() => _projects = [
            for (final r in rows)
              if (r is Map) Map<String, dynamic>.from(r),
          ]);
        }
      }
    });
  }

  Future<void> _rdStatus() => _guard(() async {
    final out = await widget.api.runAction('remote_desktop_status');
    _snack(out.message);
  });

  Future<void> _rdOpen() async {
    final app = AppScope.read(context);
    final s = app.s;
    final id = widget.computer.rustdeskId;
    if (id == null || id.isEmpty) {
      _snack(s.t('rd_need_id'));
      return;
    }
    // RustDesk's own deep link; it opens the app (if installed) with this ID ready.
    final ok = await app.launchUri(Uri.parse('rustdesk://connect/$id'));
    if (!ok) _snack(s.t('rd_open_failed'));
  }

  String _stateText(Map<String, dynamic> p) {
    final s = AppScope.read(context).s;
    final state = '${p['state']}';
    if (state == 'exited') return s.tf('coding_state_exited', {'c': '${p['exit_code']}'});
    return s.t('coding_state_$state');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    return Card(
      key: const Key('tools_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('tools_title'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text(s.t('coding_title'), style: Theme.of(context).textTheme.labelLarge)),
                TextButton(
                  key: const Key('coding_refresh'),
                  onPressed: _busy ? null : _list,
                  child: Text(s.t('coding_refresh')),
                ),
              ],
            ),
            if (_projects != null && _projects!.isEmpty)
              Text(s.t('coding_none'), key: const Key('coding_none')),
            for (final p in _projects ?? const <Map<String, dynamic>>[])
              ListTile(
                key: Key('coding_row_${p['project']}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${p['project']}'),
                subtitle: Text(_stateText(p)),
                trailing: p['state'] == 'running'
                    ? OutlinedButton(
                        key: Key('coding_stop_${p['project']}'),
                        onPressed: _busy
                            ? null
                            : () => _risky(
                                'coding_session_stop',
                                {'name': '${p['project']}'},
                                '${s.t('coding_stop')} — ${p['project']}',
                                s.tf('will_coding_stop', {'name': '${p['project']}'}),
                              ),
                        child: Text(s.t('coding_stop')),
                      )
                    : OutlinedButton(
                        key: Key('coding_start_${p['project']}'),
                        onPressed: _busy
                            ? null
                            : () => _risky(
                                'coding_session_start',
                                {'name': '${p['project']}'},
                                '${s.t('coding_start')} — ${p['project']}',
                                s.tf('will_coding_start', {'name': '${p['project']}'}),
                              ),
                        child: Text(s.t('coding_start')),
                      ),
              ),
            const Divider(),
            Text(s.t('rd_title'), style: Theme.of(context).textTheme.labelLarge),
            Text(s.t('rd_note'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('rd_open'),
                  onPressed: _rdOpen,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(s.t('rd_open')),
                ),
                OutlinedButton(
                  key: const Key('rd_status'),
                  onPressed: _busy ? null : _rdStatus,
                  child: Text(s.t('rd_status')),
                ),
                OutlinedButton(
                  key: const Key('rd_start'),
                  onPressed: _busy
                      ? null
                      : () => _risky(
                          'remote_desktop_start',
                          const {},
                          s.t('p_remote_start'),
                          s.t('will_remote_start'),
                        ),
                  child: Text(s.t('rd_start')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
