import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/pending_controller.dart';

/// High-risk requests (shutdown, restart, run_script) that the AI asked for.
/// Nothing runs until the owner presses the confirm button on a card.
class PendingScreen extends StatelessWidget {
  const PendingScreen({super.key, required this.controller});

  final PendingController controller;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.items;
        return RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                s.t('pending_title'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                s.t('pending_note'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (controller.error != null && items.isEmpty)
                Text(
                  s.error(controller.error!),
                  key: const Key('pending_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (items.isEmpty && controller.error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      s.t('pending_empty'),
                      key: const Key('pending_empty'),
                    ),
                  ),
                ),
              for (final item in items)
                PendingCard(
                  key: ValueKey(item.confirmToken),
                  item: item,
                  controller: controller,
                ),
            ],
          ),
        );
      },
    );
  }
}

class PendingCard extends StatefulWidget {
  const PendingCard({super.key, required this.item, required this.controller});

  final PendingItem item;
  final PendingController controller;

  @override
  State<PendingCard> createState() => _PendingCardState();
}

class _PendingCardState extends State<PendingCard> {
  late int _left = widget.item.expiresIn;
  Timer? _timer;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    // Count down locally; the agent re-syncs the value on every refresh and
    // decides for real whether the token is still valid.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_left > 0 && mounted) setState(() => _left--);
    });
  }

  @override
  void didUpdateWidget(PendingCard old) {
    super.didUpdateWidget(old);
    if (old.item.expiresIn != widget.item.expiresIn) {
      _left = widget.item.expiresIn;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _expired => _left <= 0;

  Future<void> _run(Future<void> Function() job, String okKey) async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await job();
      messenger.showSnackBar(SnackBar(content: Text(app.s.t(okKey))));
    } catch (e) {
      final text = app.s.error(e);
      messenger.showSnackBar(SnackBar(content: Text(text)));
      if (mounted) {
        setState(() {
          _message = text;
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final item = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final title = switch (item.action) {
      'shutdown' => s.t('act_shutdown'),
      'restart' => s.t('act_restart'),
      'run_script' => s.t('act_run_script'),
      _ => s.t('act_other'),
    };
    final confirmLabel = switch (item.action) {
      'shutdown' => s.t('confirm_shutdown'),
      'restart' => s.t('confirm_restart'),
      'run_script' => s.t('confirm_run_script'),
      _ => s.t('confirm_default'),
    };
    final scriptName = item.params['name'];
    return Card(
      key: Key('pending_card_${item.confirmToken}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (item.summary.isNotEmpty)
              Text(item.summary, key: const Key('pending_summary')),
            if (item.action == 'run_script') ...[
              const SizedBox(height: 8),
              if (scriptName != null)
                Text('${s.t('script_label')}: $scriptName'),
              Text(
                s.t('will_run'),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Container(
                key: const Key('pending_command'),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  item.command.isEmpty ? '—' : item.command.join(' '),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ] else ...[
              const SizedBox(height: 4),
              Text(
                s.t('save_work_note'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              _expired ? s.t('expired') : s.tf('expires_in', {'n': _left}),
              key: const Key('pending_countdown'),
              style: TextStyle(
                color: _left <= 10 ? scheme.error : null,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _message!,
                  key: const Key('pending_message'),
                  style: TextStyle(
                    color: _messageIsError ? scheme.error : null,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('pending_cancel'),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => widget.controller.cancel(item),
                            'cancelled_msg',
                          ),
                    child: Text(s.t('cancel')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('pending_confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    ),
                    onPressed: (_busy || _expired)
                        ? null
                        : () => _run(() async {
                            final out = await widget.controller.confirm(item);
                            if (!out.ok) {
                              throw ApiException(
                                ApiErrorKind.unavailable,
                                detail: out.message,
                              );
                            }
                          }, 'confirmed_msg'),
                    child: Text(confirmLabel, textAlign: TextAlign.center),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small red badge for the navigation bar.
class PendingBadge extends StatelessWidget {
  const PendingBadge({
    super.key,
    required this.controller,
    required this.child,
  });

  final PendingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, __) => Badge(
      isLabelVisible: controller.items.isNotEmpty,
      label: Text('${controller.items.length}'),
      child: child,
    ),
  );
}
