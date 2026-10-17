import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';

/// The live-ish view of a supervised GUI session: the latest small picture, a countdown, the list
/// of actions and a big STOP button. STOP is always enabled and needs no confirmation (ending a
/// session is always safe). Unverified on a real screen.
class GuiSessionScreen extends StatefulWidget {
  const GuiSessionScreen({
    super.key,
    required this.api,
    this.pollEvery = const Duration(seconds: 2),
  });

  final CortexApi api;
  final Duration pollEvery;

  @override
  State<GuiSessionScreen> createState() => _GuiSessionScreenState();
}

class _GuiSessionScreenState extends State<GuiSessionScreen> {
  GuiSnapshot? _snap;
  Object? _error;
  Uint8List? _picture;
  String? _pictureName;
  Timer? _poll;
  Timer? _tick;
  int _left = 0;
  bool _stopping = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(widget.pollEvery, (_) => _refresh());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed && _left > 0 && (_snap?.active ?? false)) setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final app = AppScope.read(context);
    try {
      final snap = await widget.api.guiSession();
      if (_disposed) return;
      setState(() {
        _snap = snap;
        _left = snap.remainingSeconds;
        _error = null;
      });
      final shot = snap.lastShot;
      if (shot != null && shot != _pictureName) {
        final bytes = await widget.api.guiShotBytes(shot);
        if (!_disposed) {
          setState(() {
            _picture = bytes;
            _pictureName = shot;
          });
        }
      }
      if (!snap.active) _poll?.cancel(); // nothing more will change
    } catch (e) {
      await app.onError(e);
      if (!_disposed) setState(() => _error = e);
    }
  }

  Future<void> _stop() async {
    final app = AppScope.read(context);
    setState(() => _stopping = true);
    try {
      // stopping needs no confirmation; if the agent cannot be reached the emergency stop is tried
      try {
        await widget.api.runAction('gui_session_stop');
      } catch (_) {
        await widget.api.emergencyStop();
      }
      await _refresh();
    } catch (e) {
      await app.onError(e);
      if (!_disposed) setState(() => _error = e);
    } finally {
      if (!_disposed) setState(() => _stopping = false);
    }
  }

  static String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final scheme = Theme.of(context).colorScheme;
    final snap = _snap;
    final active = snap?.active ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gui_screen_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            height: 72,
            child: FilledButton.icon(
              key: const Key('gui_stop_button'),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: _stopping ? null : _stop,
              icon: const Icon(Icons.stop_circle, size: 32),
              label: Text(s.t('gui_stop'), style: const TextStyle(fontSize: 26)),
            ),
          ),
          const SizedBox(height: 12),
          if (snap == null && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Text(
              s.error(_error!),
              key: const Key('gui_error'),
              style: TextStyle(color: scheme.error),
            ),
          if (snap != null) ...[
            Text(
              active ? s.t('gui_active') : s.t('gui_ended'),
              key: const Key('gui_state'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (active)
              Text(
                s.tf('gui_remaining', {'t': _clock(_left)}),
                key: const Key('gui_countdown'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: _left <= 30 ? scheme.error : null,
                ),
              ),
            Text(
              s.tf('gui_actions_used', {'n': snap.actionsUsed, 'm': snap.maxActions}),
              key: const Key('gui_actions_used'),
            ),
            if (!active && snap.endedReason.isNotEmpty)
              Text(
                s.tf('gui_reason', {'r': snap.endedReason}),
                key: const Key('gui_reason'),
              ),
          ],
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 16 / 10,
            child: _picture == null
                ? Center(child: Text(s.t('gui_no_shot'), key: const Key('gui_no_shot')))
                : InteractiveViewer(
                    maxScale: 5,
                    child: Image.memory(
                      _picture!,
                      key: const Key('gui_picture'),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => Center(child: Text(s.t('err_bad'))),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Text(s.t('gui_actions_title'), style: Theme.of(context).textTheme.labelLarge),
          for (final a in (snap?.actions ?? const <GuiActionRow>[]).reversed)
            ListTile(
              key: Key('gui_action_${a.n}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                a.ok ? Icons.check_circle : Icons.block,
                color: a.ok ? Colors.green : scheme.error,
                size: 18,
              ),
              title: Text('${a.action}  ${a.detail}'),
            ),
          const SizedBox(height: 12),
          Text(s.t('gui_note'), style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
