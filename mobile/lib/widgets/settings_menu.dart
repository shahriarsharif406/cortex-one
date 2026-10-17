import 'package:flutter/material.dart';

import '../screens/gateway_screen.dart';
import '../state/app_state.dart';

/// Language toggle, theme choice and "remove this phone".
class SettingsMenu extends StatelessWidget {
  const SettingsMenu({super.key, this.showUnpair = true});

  final bool showUnpair;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          key: const Key('language_toggle'),
          onPressed: () => app.setLang(app.lang == 'bn' ? 'en' : 'bn'),
          child: Text(app.lang == 'bn' ? 'EN' : 'বাং'),
        ),
        PopupMenuButton<String>(
          key: const Key('settings_menu'),
          tooltip: s.t('theme'),
          onSelected: (v) async {
            switch (v) {
              case 'system':
                app.setThemeMode(ThemeMode.system);
              case 'light':
                app.setThemeMode(ThemeMode.light);
              case 'dark':
                app.setThemeMode(ThemeMode.dark);
              case 'gateway':
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const GatewaySetupScreen()),
                );
              case 'unpair':
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: Text(s.t('unpair_confirm')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(s.t('no')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(s.t('yes')),
                      ),
                    ],
                  ),
                );
                if (ok == true) await app.unpair();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'system',
              child: Text('${s.t('theme')}: ${s.t('theme_system')}'),
            ),
            PopupMenuItem(
              value: 'light',
              child: Text('${s.t('theme')}: ${s.t('theme_light')}'),
            ),
            PopupMenuItem(
              value: 'dark',
              child: Text('${s.t('theme')}: ${s.t('theme_dark')}'),
            ),
            if (showUnpair)
              PopupMenuItem(value: 'gateway', child: Text(s.t('gw_menu'))),
            if (showUnpair)
              PopupMenuItem(value: 'unpair', child: Text(s.t('unpair'))),
          ],
        ),
      ],
    );
  }
}
