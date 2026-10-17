import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../images/image_prep.dart';
import '../state/app_state.dart';
import '../state/pending_controller.dart';
import '../widgets/computer_status_card.dart';
import '../widgets/power_card.dart';
import '../widgets/tools_card.dart';
import 'alerts_screen.dart';
import 'watch_screen.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({
    super.key,
    required this.api,
    required this.pending,
    required this.onOpenPending,
    this.pollInterval = const Duration(milliseconds: 1500),
    this.maxPolls = 60,
  });

  final CortexApi api;
  final PendingController pending;
  final VoidCallback onOpenPending;
  final Duration pollInterval;
  final int maxPolls;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final _text = TextEditingController();
  Map<String, dynamic>? _info;
  Object? _infoError;
  bool _infoLoading = false;
  AlertEntry? _alert; // newest power alert; a banner while it is a problem

  TaskStatus? _task;
  bool _running = false;
  String? _taskError;
  bool _timedOut = false;
  bool _disposed = false;

  final List<TaskImage> _pictures = [];
  String? _pictureError;
  bool _listening = false;
  bool _voiceFailed = false;
  String? _voiceLocale; // bn_BD | en_US

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  /// Best effort: an older agent without /alerts must not break the home tab.
  Future<void> _loadAlert() async {
    try {
      final rows = await widget.api.alerts(limit: 1);
      if (!_disposed) setState(() => _alert = rows.isEmpty ? null : rows.first);
    } catch (_) {
      if (!_disposed) setState(() => _alert = null);
    }
  }

  void _openAlerts() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AlertsScreen(api: widget.api)),
  );

  void _openWatch() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => WatchScreen(api: widget.api)),
  );

  @override
  void dispose() {
    _disposed = true;
    _text.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ status
  Future<void> _loadStatus() async {
    _loadAlert();
    final app = AppScope.read(context);
    setState(() {
      _infoLoading = true;
      _infoError = null;
    });
    try {
      final out = await widget.api.runAction('system_info');
      if (!_disposed) setState(() => _info = out.data);
    } catch (e) {
      if (_disposed) return;
      await app.onError(e);
      if (!_disposed) setState(() => _infoError = e);
    } finally {
      if (!_disposed) setState(() => _infoLoading = false);
    }
  }

  // ------------------------------------------------------------------- task
  Future<void> _send() async {
    final app = AppScope.of(context);
    final instruction = _text.text.trim();
    if (instruction.isEmpty || _running) return;
    if (_listening) await _stopVoice();
    setState(() {
      _running = true;
      _task = null;
      _taskError = null;
      _timedOut = false;
    });
    try {
      final id = await widget.api.startTask(instruction, images: List.of(_pictures));
      var polls = 0;
      while (!_disposed) {
        await Future<void>.delayed(widget.pollInterval);
        final status = await widget.api.getTask(id);
        if (_disposed) return;
        setState(() => _task = status);
        if (!status.running) break;
        if (++polls >= widget.maxPolls) {
          setState(() => _timedOut = true);
          break;
        }
      }
      widget.pending.refresh();
      if (!_disposed) setState(_pictures.clear);
    } catch (e) {
      await app.onError(e);
      if (!_disposed) setState(() => _taskError = app.s.error(e));
    } finally {
      if (!_disposed) setState(() => _running = false);
    }
  }

  // --------------------------------------------------------------- pictures
  Future<void> _attach(bool camera) async {
    final app = AppScope.read(context);
    if (_pictures.length >= 3) return;
    final raw = await (camera ? app.pictures.pickCamera() : app.pictures.pickGallery());
    if (raw == null || !mounted) return;
    try {
      // shrink, fix rotation, drop EXIF/GPS: smaller still on the SIM link (data-saver)
      final prepared = prepareImage(raw, maxSide: app.dataSaver ? 800 : 1280);
      setState(() {
        _pictures.add(prepared);
        _pictureError = null;
      });
    } on ImagePrepError catch (e) {
      setState(() => _pictureError = app.s.t(e.messageKey));
    }
  }

  // ------------------------------------------------------------------ voice
  Future<void> _toggleMic() async {
    final app = AppScope.of(context);
    if (_listening) return _stopVoice();
    final ok = await app.voice.init();
    if (!mounted) return;
    if (!ok) {
      setState(() => _voiceFailed = true);
      return;
    }
    final prefix = _text.text.trim();
    setState(() {
      _voiceFailed = false;
      _listening = true;
    });
    try {
      await app.voice.listen(
        _voiceLocale ?? (app.lang == 'en' ? 'en_US' : 'bn_BD'),
        (words, finished) {
          if (!mounted) return;
          // Recognised text only fills the box; the owner edits and presses Send.
          final value = prefix.isEmpty ? words : '$prefix $words';
          _text.value = TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
          );
          if (finished) setState(() => _listening = false);
        },
        onDevice: app.voiceOnDevice,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _listening = false;
          _voiceFailed = true;
        });
      }
    }
  }

  Future<void> _stopVoice() async {
    await AppScope.of(context).voice.stop();
    if (mounted) setState(() => _listening = false);
  }

  // --------------------------------------------------------- quick actions
  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _guard(Future<void> Function() job) async {
    final app = AppScope.of(context);
    try {
      await job();
    } catch (e) {
      await app.onError(e);
      _snack(app.s.error(e));
    }
  }

  Future<void> _lock() => _guard(() async {
    final out = await widget.api.runAction('lock');
    _snack(out.message);
  });

  Future<void> _downloads() => _guard(() async {
    final s = AppScope.of(context).s;
    final caps = await widget.api.capabilities();
    final root = caps.allowedRoots.cast<String?>().firstWhere(
      (r) =>
          r!
              .split(RegExp(r'[\\/]'))
              .where((p) => p.isNotEmpty)
              .last
              .toLowerCase() ==
          'downloads',
      orElse: () => null,
    );
    if (root == null) return _snack(s.t('no_downloads'));
    final out = await widget.api.runAction('list_files', {'path': root});
    if (!mounted) return;
    final entries = [
      for (final e in (out.data['entries'] as List? ?? const []))
        if (e is Map) Map<String, dynamic>.from(e),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Downloads — ${s.tf('items_count', {'n': entries.length})}',
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in entries.take(100))
                ListTile(
                  dense: true,
                  leading: Icon(
                    e['dir'] == true
                        ? Icons.folder
                        : Icons.insert_drive_file_outlined,
                  ),
                  title: Text('${e['name']}'),
                  subtitle: Text(
                    e['dir'] == true ? s.t('folder_label') : _size(e['size']),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('ok')),
          ),
        ],
      ),
    );
  });

  Future<void> _apps() => _guard(() async {
    final s = AppScope.of(context).s;
    final caps = await widget.api.capabilities();
    if (!mounted) return;
    if (caps.allowedApps.isEmpty) return _snack(s.t('no_apps'));
    final name = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final app in caps.allowedApps)
              ListTile(
                key: Key('app_$app'),
                leading: const Icon(Icons.open_in_new),
                title: Text(app),
                onTap: () => Navigator.pop(ctx, app),
              ),
          ],
        ),
      ),
    );
    if (name == null) return;
    final out = await widget.api.runAction('open_app', {'name': name});
    _snack(out.message);
  });

  static String _size(Object? bytes) {
    final n = (bytes as num?)?.toInt();
    if (n == null) return '';
    if (n < 1024) return '$n B';
    if (n < 1048576) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1048576).toStringAsFixed(1)} MB';
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _loadStatus,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_alert != null &&
              _alert!.isProblem &&
              DateTime.now().difference(_alert!.time) < const Duration(hours: 12))
            Card(
              key: const Key('power_banner'),
              color: scheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.bolt),
                title: Text(alertText(s, _alert!)),
                subtitle: Text(s.t('alert_banner_hint')),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openAlerts,
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                key: const Key('watch_open'),
                onPressed: _openWatch,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(s.t('watch_open')),
              ),
              TextButton.icon(
                key: const Key('alerts_open'),
                onPressed: _openAlerts,
                icon: const Icon(Icons.bolt_outlined),
                label: Text(s.t('alerts_open')),
              ),
            ],
          ),
          if (app.current != null) ...[
            ComputerStatusCard(
              computer: app.current!,
              monitor: app.monitorFor(app.current!),
            ),
            if (app.current!.isViewer)
              Card(
                key: const Key('viewer_note'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(s.t('viewer_note')),
                ),
              )
            else
              PowerCard(
                computer: app.current!,
                api: widget.api,
                monitor: app.monitorFor(app.current!),
              ),
          ],
          _statusCard(context),
          if (!(app.current?.isViewer ?? false)) ...[
          const SizedBox(height: 16),
          Text(
            s.t('command_title'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('command_field'),
            controller: _text,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            decoration: InputDecoration(
              hintText: s.t('command_hint'),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                key: const Key('mic_button'),
                tooltip: _listening ? s.t('mic_stop') : s.t('mic_start'),
                icon: Icon(
                  _listening ? Icons.stop_circle : Icons.mic,
                  color: _listening ? scheme.error : null,
                ),
                onPressed: _toggleMic,
              ),
            ),
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text('${s.t('voice_lang')}: '),
              SegmentedButton<String>(
                key: const Key('voice_locale'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'bn_BD', label: Text('বাংলা')),
                  ButtonSegment(value: 'en_US', label: Text('English')),
                ],
                selected: {
                  _voiceLocale ?? (app.lang == 'en' ? 'en_US' : 'bn_BD'),
                },
                onSelectionChanged: (v) =>
                    setState(() => _voiceLocale = v.first),
              ),
            ],
          ),
          if (_listening)
            Text(s.t('listening'), key: const Key('listening_label')),
          if (_voiceFailed)
            Text(
              s.t('voice_unavailable'),
              key: const Key('voice_error'),
              style: TextStyle(color: scheme.error),
            ),
          Text(s.t('voice_hint'), style: Theme.of(context).textTheme.bodySmall),
          SwitchListTile(
            key: const Key('voice_offline_switch'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(s.t('voice_offline_pref')),
            subtitle: app.phoneOffline
                ? Text(s.t('voice_offline_title'))
                : null,
            value: app.voiceOnDevice,
            onChanged: app.phoneOffline ? null : app.setVoiceOffline,
          ),
          TextButton.icon(
            key: const Key('voice_offline_help'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(s.t('voice_offline_title')),
                content: SingleChildScrollView(
                  child: Text(
                    s.t('voice_offline_body'),
                    key: const Key('voice_offline_text'),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(s.t('ok')),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.help_outline, size: 18),
            label: Text(s.t('voice_offline_help')),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('attach_gallery'),
                onPressed: _pictures.length >= 3 || _running ? null : () => _attach(false),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(s.t('attach_gallery')),
              ),
              OutlinedButton.icon(
                key: const Key('attach_camera'),
                onPressed: _pictures.length >= 3 || _running ? null : () => _attach(true),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: Text(s.t('attach_camera')),
              ),
              Text(
                s.tf('attach_count', {'n': _pictures.length}),
                key: const Key('attach_count'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (_pictures.isNotEmpty)
            SizedBox(
              height: 92,
              child: ListView(
                key: const Key('picture_previews'),
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < _pictures.length; i++)
                    Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: Image.memory(
                            _pictures[i].bytes,
                            key: Key('picture_$i'),
                            width: 84,
                            height: 84,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox(width: 84, height: 84),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: InkWell(
                            key: Key('picture_remove_$i'),
                            onTap: _running ? null : () => setState(() => _pictures.removeAt(i)),
                            child: const CircleAvatar(
                              radius: 11,
                              child: Icon(Icons.close, size: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (_pictureError != null)
            Text(
              _pictureError!,
              key: const Key('picture_error'),
              style: TextStyle(color: scheme.error),
            ),
          Text(s.t('attach_note'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('send_button'),
            onPressed: _running ? null : _send,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(_running ? s.t('task_running') : s.t('send')),
          ),
          if (_taskError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _taskError!,
                key: const Key('task_error'),
                style: TextStyle(color: scheme.error),
              ),
            ),
          if (_task != null) _taskCard(context, _task!),
          if (_timedOut)
            Text(s.t('task_timeout'), key: const Key('task_timeout')),
          const SizedBox(height: 20),
          Text(
            s.t('quick_title'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                key: const Key('quick_lock'),
                avatar: const Icon(Icons.lock_outline, size: 18),
                label: Text(s.t('q_lock')),
                onPressed: _lock,
              ),
              ActionChip(
                key: const Key('quick_status'),
                avatar: const Icon(Icons.monitor_heart_outlined, size: 18),
                label: Text(s.t('q_status')),
                onPressed: _loadStatus,
              ),
              ActionChip(
                key: const Key('quick_downloads'),
                avatar: const Icon(Icons.folder_open, size: 18),
                label: Text(s.t('q_downloads')),
                onPressed: _downloads,
              ),
              ActionChip(
                key: const Key('quick_apps'),
                avatar: const Icon(Icons.apps, size: 18),
                label: Text(s.t('q_apps')),
                onPressed: _apps,
              ),
            ],
          ),
          if (app.current != null)
            ExpansionTile(
              key: const Key('tools_expansion'),
              tilePadding: EdgeInsets.zero,
              title: Text(s.t('tools_title')),
              children: [ToolsCard(computer: app.current!, api: widget.api)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context) {
    final s = AppScope.of(context).s;
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    Widget body;
    if (info == null) {
      body = _infoError != null
          ? Text(
              s.error(_infoError!),
              key: const Key('status_error'),
              style: TextStyle(color: scheme.error),
            )
          : Text(s.t('status_loading'));
    } else {
      final uptime = (info['uptime_minutes'] as num?)?.toInt();
      body = Wrap(
        spacing: 20,
        runSpacing: 8,
        children: [
          if (info['cpu_percent'] != null)
            _stat(s.t('cpu'), '${info['cpu_percent']}%'),
          if (info['ram_used_percent'] != null)
            _stat(s.t('ram'), '${info['ram_used_percent']}%'),
          if (info['disk_free_gb'] != null)
            _stat(s.t('disk'), '${info['disk_free_gb']} GB ${s.t('free')}'),
          if (info['battery_percent'] != null)
            _stat(
              s.t('battery'),
              '${info['battery_percent']}% (${info['plugged_in'] == true ? s.t('plugged') : s.t('on_battery')})',
            ),
          if (uptime != null)
            _stat(
              s.t('uptime'),
              '${uptime ~/ 60} ${s.t('hours_short')} ${uptime % 60} ${s.t('minutes_short')}',
            ),
        ],
      );
    }
    return Card(
      key: const Key('status_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.t('status_title'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_infoLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    key: const Key('status_refresh'),
                    tooltip: s.t('status_refresh'),
                    icon: const Icon(Icons.refresh),
                    onPressed: _loadStatus,
                  ),
              ],
            ),
            body,
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );

  Widget _taskCard(BuildContext context, TaskStatus task) {
    final s = AppScope.of(context).s;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('task_card'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (task.steps.isNotEmpty)
              Text(s.t('steps'), style: Theme.of(context).textTheme.labelLarge),
            for (final step in task.steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      step.ok ? Icons.check_circle : Icons.error,
                      size: 16,
                      color: step.ok ? Colors.green : scheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${step.tool}: ${step.message}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            if (task.pending.isNotEmpty)
              Container(
                key: const Key('task_pending_banner'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(s.t('waiting_confirm'))),
                    TextButton(
                      key: const Key('task_open_pending'),
                      onPressed: widget.onOpenPending,
                      child: Text(s.t('go_pending')),
                    ),
                  ],
                ),
              ),
            if (!task.running && task.reply.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(s.t('reply'), style: Theme.of(context).textTheme.labelLarge),
              SelectableText(task.reply, key: const Key('task_reply')),
              if (task.model.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    s.tf(task.fallback ? 'answered_local' : 'answered_by', {'m': task.model}),
                    key: const Key('task_model'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
