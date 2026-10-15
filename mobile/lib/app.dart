import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_shell.dart';
import 'screens/pairing_screen.dart';
import 'state/app_state.dart';

class CortexApp extends StatelessWidget {
  const CortexApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          // A new key per API object drops any pushed screens (e.g. alerts) when
          // the phone is unpaired, so a revoked token never leaves one open.
          key: ValueKey(state.api),
          title: 'Cortex One',
          debugShowCheckedModeBanner: false,
          locale: Locale(state.lang),
          supportedLocales: const [Locale('bn'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          themeMode: state.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
          ),
          home: !state.loaded
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : state.api == null
              ? const PairingScreen()
              : HomeShell(key: ValueKey(state.api), api: state.api!),
        ),
      ),
    );
  }
}
