import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../state/pending_controller.dart';
import '../widgets/emergency_bar.dart';
import '../widgets/settings_menu.dart';
import 'audit_screen.dart';
import 'computers_screen.dart';
import 'home_tab.dart';
import 'pending_screen.dart';
import 'screen_view.dart';
import 'sms_help_screen.dart';

/// Main screen: five tabs and the emergency stop, which is always on screen.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.api,
    this.pollInterval = const Duration(milliseconds: 1500),
  });

  final CortexApi api;
  final Duration pollInterval;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  PendingController? _pending;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    _pending ??= PendingController(widget.api, onError: app.onError);
    // a viewer phone has no confirmations to wait for (and the agent would refuse the request)
    if (!(app.current?.isViewer ?? false)) _pending!.startPolling();
  }

  @override
  void dispose() {
    _pending?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final pending = _pending!;
    final viewer = app.current?.isViewer ?? false;
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          key: const Key('computer_switcher'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ComputersScreen()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  app.current?.name ?? s.t('app_title'),
                  key: const Key('appbar_title'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
        actions: const [SettingsMenu()],
      ),
      body: IndexedStack(
        index: viewer ? (_index == 4 ? 1 : 0) : _index,
        children: [
          HomeTab(
            api: widget.api,
            pending: pending,
            pollInterval: widget.pollInterval,
            onOpenPending: () => setState(() => _index = 1),
          ),
          if (!viewer) ...[
            PendingScreen(controller: pending),
            // Audit reloads each time its tab is opened.
            _index == 2 ? AuditScreen(api: widget.api) : const SizedBox.shrink(),
            const SmsHelpScreen(),
          ],
          // The viewer keeps its picture and timer only while its tab is open.
          _index == 4 ? ScreenView(api: widget.api) : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmergencyBar(api: widget.api),
          NavigationBar(
            selectedIndex: viewer ? (_index == 4 ? 1 : 0) : _index,
            onDestinationSelected: (i) => setState(() => _index = viewer ? (i == 1 ? 4 : 0) : i),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                label: s.t('nav_home'),
              ),
              if (!viewer) ...[
                NavigationDestination(
                  icon: PendingBadge(
                    controller: pending,
                    child: const Icon(Icons.verified_user_outlined),
                  ),
                  label: s.t('nav_pending'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.history),
                  label: s.t('nav_audit'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.sms_outlined),
                  label: s.t('nav_sms'),
                ),
              ],
              NavigationDestination(
                icon: const Icon(Icons.monitor_outlined),
                label: s.t('nav_screen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
