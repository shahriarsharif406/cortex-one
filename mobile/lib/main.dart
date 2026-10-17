import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'app.dart';
import 'state/app_state.dart';
import 'state/device_services.dart';
import 'storage/stores.dart';
import 'voice/voice_input.dart';
// ignore: unused_import
import 'wake/gateway_runtime.dart' show gatewayMain; // keeps the gateway service entry point in the build

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(
    secrets: KeystoreSecretStore(),
    prefs: SharedPrefsStore(await SharedPreferences.getInstance()),
    apiFactory: (baseUrl, token) => HttpCortexApi(baseUrl, token),
    voice: SpeechVoiceInput(),
    links: ConnectivityLinkMonitor(),
  );
  await state.load();
  runApp(CortexApp(state: state));
}
