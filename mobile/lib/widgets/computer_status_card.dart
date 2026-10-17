import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../state/computer.dart';
import '../state/computer_monitor.dart';
import '../state/power_state.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// "14:05" today, "10-16 14:05" on another day.
String formatWhen(DateTime t, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  return (t.year == n.year && t.month == n.month && t.day == n.day)
      ? hm
      : '${_two(t.month)}-${_two(t.day)} $hm';
}

String powerReasonText(S s, PowerStatus st) {
  final when = st.requestedAt == null ? '' : formatWhen(st.requestedAt!);
  return switch (st.reason) {
    PowerReason.none => '',
    PowerReason.sleepRequested => s.tf('reason_sleep', {'t': when}),
    PowerReason.hibernateRequested => s.tf('reason_hibernate', {'t': when}),
    PowerReason.shutdownRequested => s.tf('reason_shutdown', {'t': when}),
    PowerReason.restartRequested => s.tf('reason_restart', {'t': when}),
    PowerReason.batteryLow => s.t('reason_battery'),
    PowerReason.noAnswer => s.t('reason_noanswer'),
    PowerReason.neverSeen => s.t('reason_never'),
  };
}

/// Name, online / sleeping / offline / unknown badge, last seen, battery, the link in use
/// and the data-saver switch for the computer on screen.
class ComputerStatusCard extends StatelessWidget {
  const ComputerStatusCard({
    super.key,
    required this.computer,
    required this.monitor,
  });

  final Computer computer;
  final ComputerMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final st = monitor.status;
        final (label, color) = switch (st.state) {
          PowerState.online => (s.t('state_online'), Colors.green),
          PowerState.sleeping => (s.t('state_sleeping'), Colors.amber.shade800),
          PowerState.offline => (s.t('state_offline'), scheme.error),
          PowerState.unknown => (s.t('state_unknown'), scheme.outline),
        };
        final h = monitor.lastHealth;
        final seen = monitor.lastSeen;
        final linkKey = app.linkLabelKey(computer);
        return Card(
          key: const Key('computer_status_card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        computer.name,
                        key: const Key('computer_name'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Flexible(
                      child: Chip(
                        key: const Key('state_badge'),
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(Icons.circle, size: 12, color: color),
                        label: Text(label, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    if (monitor.checking)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        key: const Key('state_refresh'),
                        tooltip: s.t('status_refresh'),
                        icon: const Icon(Icons.refresh),
                        onPressed: monitor.refresh,
                      ),
                  ],
                ),
                if (st.state != PowerState.online)
                  Text(
                    powerReasonText(s, st),
                    key: const Key('state_reason'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  seen == null
                      ? s.t('seen_never')
                      : s.tf('last_seen', {'t': formatWhen(seen)}),
                  key: const Key('last_seen'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (h?.batteryPercent != null)
                  Text(
                    s.tf('battery_line', {
                      'p': h!.batteryPercent!,
                      'c': h.plugged == true
                          ? s.t('plugged')
                          : s.t('on_battery'),
                    }),
                    key: const Key('battery_line'),
                  ),
                Text(
                  s.t(linkKey ?? 'link_none'),
                  key: const Key('link_label'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${s.t('ds_title')}: '),
                    Expanded(
                      child: SegmentedButton<String>(
                        key: const Key('data_saver_mode'),
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: 'auto',
                            label: Text(s.t('ds_auto')),
                          ),
                          ButtonSegment(
                            value: 'on',
                            label: Text(s.t('ds_on')),
                          ),
                          ButtonSegment(
                            value: 'off',
                            label: Text(s.t('ds_off')),
                          ),
                        ],
                        selected: {app.dataSaverMode},
                        onSelectionChanged: (v) =>
                            app.setDataSaverMode(v.first),
                      ),
                    ),
                  ],
                ),
                if (app.dataSaver)
                  Text(
                    s.t('ds_active'),
                    key: const Key('data_saver_active'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
