import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';

/// View-only picture of the laptop screen. "Refresh" asks the agent for a new
/// screenshot (the named `take_screenshot` action) and downloads a downscaled
/// copy. No touch events are ever sent back.
class ScreenView extends StatefulWidget {
  const ScreenView({
    super.key,
    required this.api,
    this.intervals = const [10, 30, 60],
  });

  final CortexApi api;
  final List<int> intervals;

  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  Uint8List? _image;
  String? _name;
  DateTime? _at;
  String? _error;
  bool _busy = false;
  bool _auto = false;
  late int _seconds = widget.intervals.first;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return; // never queue up requests on a slow link
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final out = await widget.api.runAction(
        'take_screenshot',
        app.dataSaver ? const {'quality': 'low'} : const {},
      );
      final file = out.data['file'];
      if (!out.ok || file is! String) {
        throw ApiException(ApiErrorKind.unavailable, detail: out.message);
      }
      // data-saver (on the SIM link, or switched on): small low-quality JPEG
      final saver = app.dataSaver;
      final bytes = await widget.api.screenshotBytes(
        file,
        width: saver ? 640 : 1000,
        lowData: saver,
      );
      if (!mounted) return;
      setState(() {
        _image = bytes;
        _name = file;
        _at = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      await app.onError(e);
      // a failing auto-refresh must not keep hammering the laptop
      _setAuto(false);
      if (mounted) setState(() => _error = app.s.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setAuto(bool on) {
    // data-saver: no automatic refresh, only the Refresh button
    if (on && AppScope.read(context).dataSaver) on = false;
    _timer?.cancel();
    _timer = null;
    if (on) {
      _timer = Timer.periodic(Duration(seconds: _seconds), (_) => _refresh());
    }
    if (mounted) setState(() => _auto = on);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final scheme = Theme.of(context).colorScheme;
    final at = _at;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          s.t('screen_title'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          s.t('screen_view_only'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              key: const Key('screen_refresh'),
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: Text(
                _busy ? s.t('screen_taking') : s.t('screen_refresh'),
              ),
            ),
          ],
        ),
        SwitchListTile(
          key: const Key('screen_auto_switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(s.t('screen_auto')),
          subtitle: Row(
            children: [
              Text('${s.t('screen_auto_every')} '),
              DropdownButton<int>(
                key: const Key('screen_interval'),
                value: _seconds,
                isDense: true,
                items: [
                  for (final n in widget.intervals)
                    DropdownMenuItem(value: n, child: Text('$n')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _seconds = v);
                  if (_auto) _setAuto(true);
                },
              ),
              Text(' ${s.t('screen_seconds')}'),
            ],
          ),
          value: _auto,
          onChanged: _setAuto,
        ),
        Text(
          s.t('screen_data_note'),
          key: const Key('screen_data_note'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('screen_error'),
            style: TextStyle(color: scheme.error),
          ),
        ],
        const SizedBox(height: 12),
        if (_image == null)
          Text(s.t('screen_empty'), key: const Key('screen_empty'))
        else ...[
          ClipRect(
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: InteractiveViewer(
                key: const Key('screen_viewer'),
                minScale: 1,
                maxScale: 6,
                child: Image.memory(
                  _image!,
                  key: const Key('screen_image'),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      Center(child: Text(s.t('err_bad'))),
                ),
              ),
            ),
          ),
          if (at != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${s.t('screen_taken_at')} ${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}'
                '${_name == null ? '' : '  ·  $_name'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}
