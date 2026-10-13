import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';

/// Big red button, shown on every tab. One tap stops everything: there is
/// deliberately no confirmation step, because it only ever makes things safer.
class EmergencyBar extends StatefulWidget {
  const EmergencyBar({super.key, required this.api});

  final CortexApi api;

  @override
  State<EmergencyBar> createState() => _EmergencyBarState();
}

class _EmergencyBarState extends State<EmergencyBar> {
  bool _busy = false;

  Future<void> _stop() async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final out = await widget.api.emergencyStop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('${app.s.t('emergency_done')}: ${out.message}'),
          backgroundColor: Colors.red.shade900,
        ),
      );
    } catch (e) {
      await app.onError(e);
      messenger.showSnackBar(SnackBar(content: Text(app.s.error(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        width: double.infinity,
        height: 64,
        child: FilledButton(
          key: const Key('emergency_stop_button'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red.shade700,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: _busy ? null : _stop,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                s.t('emergency_stop'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              Text(s.t('emergency_sub'), style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
