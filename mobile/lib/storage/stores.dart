import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device token and server address. Secrets live ONLY here
/// (Android Keystore through flutter_secure_storage), never in plain prefs.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeystoreSecretStore implements SecretStore {
  KeystoreSecretStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Harmless preferences (language, theme, gateway number). NEVER put a PIN or token here.
abstract class PrefsStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
}

class SharedPrefsStore implements PrefsStore {
  SharedPrefsStore(this._p);

  final SharedPreferences _p;

  @override
  Future<String?> get(String key) async => _p.getString(key);

  @override
  Future<void> set(String key, String value) async {
    await _p.setString(key, value);
  }
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class MemoryPrefsStore implements PrefsStore {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async => values[key] = value;
}
