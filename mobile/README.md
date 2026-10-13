# Cortex One — phone app (Flutter, Android)

Bangla-first (English toggle), light/dark. Talks only to your own laptop's agent
over the Tailscale network. No analytics, no ads, no third-party trackers.

## What it does
- **Pairing**: laptop address + 6-digit code → device token kept only in the Android
  Keystore (`flutter_secure_storage`). Never in plain preferences.
- **Home**: laptop status card (`system_info`), command box (type or speak; the
  recognised text is shown for editing and is never sent automatically), live steps and
  reply, quick actions (lock, status, list Downloads, open approved apps).
- **Emergency stop**: big red button on every tab, one tap, no confirmation.
- **Confirmations**: shutdown / restart / run_script requested by the AI wait here. The
  card shows exactly what will run and an expiry countdown. Nothing runs until you press
  confirm.
- **Log**: read-only audit list.
- **SMS help**: command format and a button that opens the SMS app with the gateway
  number and command prefilled. You type the PIN yourself; the app has no PIN field and
  stores none.

## Privacy notes
- Voice typing uses Android's own speech service (on most phones Google's). The audio is
  handled by the phone's speech engine, not by this app or by your laptop.
- The app allows plain `http` because the agent speaks http on Tailscale (already
  WireGuard-encrypted). Only ever pair with your Tailscale address.
- `android:allowBackup="false"`: the token is not included in Android backups.

## Build (on a PC with Flutter + Android SDK)
```powershell
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release      # build\app\outputs\flutter-apk\app-release.apk
```
`android/gradle.properties` limits Gradle to 1.5 GB so it fits a 4 GB laptop. Close other
programs while building. The first build downloads Gradle and SDK parts and is slow.

## Layout
`lib/api` HTTP client + models · `lib/state` app state, pending controller ·
`lib/screens` UI · `lib/l10n/strings.dart` Bangla + English text ·
`lib/storage` secure store + plain prefs · `lib/voice` speech wrapper ·
`test/` widget tests with a fake API client (`test/support/fakes.dart`).
