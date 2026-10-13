import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../state/pending_controller.dart';
import '../widgets/emergency_bar.dart';
import '../widgets/settings_menu.dart';
import 'audit_screen.dart';
import 'home_tab.dart';
import 'pending_screen.dart';
import 'sms_help_screen.dart';

/// Main screen: four tabs and the emergency stop, which is always on screen.
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
    _pending ??= PendingController(
      widget.api,
      onError: AppScope.of(context).onError,
    )..startPolling();
  }

  @override
  void dispose() {
    _pending?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final pending = _pending!;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('app_title')),
        actions: const [SettingsMenu()],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          HomeTab(
            api: widget.api,
            pending: pending,
            pollInterval: widget.pollInterval,
            onOpenPending: () => setState(() => _index = 1),
          ),
          PendingScreen(controller: pending),
          // Audit reloads each time its tab is opened.
          _index == 2 ? AuditScreen(api: widget.api) : const SizedBox.shrink(),
          const SmsHelpScreen(),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmergencyBar(api: widget.api),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                label: s.t('nav_home'),
              ),
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
          ),
        ],
      ),
    );
  }
}
