# Changelog

## 1.1.0-rc1

Session 2: "reach and control my computers in any situation". Everything below is covered by automated tests that use fakes (fake sockets, fake processes, fake BLE/SMS, fake GUI backend, a fake local-model server). **Not verified** (see `NEEDS_ME.md`): any real shutdown/sleep/wake, a real phone or APK build, real SMS, the ESP32 firmware (never compiled) and servo hardware, the Kotlin gateway service (never compiled), the GUI mouse/keyboard code on a real screen, a real Anthropic call (also with pictures), a real local model, the admin scripts (parsed and `-WhatIf` only).

### Added
- **Network resilience:** `hosts` (several bind addresses: loopback, Tailscale, private LAN; never `0.0.0.0`/public; one bad entry stops `serve`), `BindManager` (waits with backoff up to 10 min for an address that is not up yet, rebinds when it appears, never falls back), richer `/health`, `GET /network`, a report-only network watchdog, `quality=low|normal` data-saver for screenshots, `doctor` wake/adapter/Tailscale/backup checks.
- **Admin scripts** (all `-WhatIf`): `setup-network-priority.ps1`, `set-power-plan.ps1`, `network-failover.ps1` + `install-network-failover.ps1` (a separate SYSTEM task, script folder writable only by administrators).
- **Power layer:** `wake_computer` (Wake-on-LAN, allowlisted targets, rate limited), `sleep` (high-risk), `power_capabilities`, a "last power request" hint so the phone can say "probably asleep".
- **Phone app:** many computers with Tailscale -> LAN failover (changes are never retried on another address), state badge, Power card, wake sheet (helper computer / Cortex Wake / SMS), biometric or PIN before every confirmation, data-saver (automatic on SIM), on-device voice option with a Bangla offline-pack hint, viewer mode.
- **Cortex Wake:** ESP32 + servo power-button robot. BLE protocol with HMAC-SHA256 and a strictly increasing counter, shared test vectors (Python reference, Dart, C++ header run through WebAssembly), firmware sources (never compiled), SMS/HTTP gateway mode (Dart logic, Kotlin `SmsReceiver`/`GatewayService`), Bangla build guide.
- **Pictures in AI tasks** (up to 3 JPEG/PNG, metadata refused not stripped, app shrinks and cleans first, token-cap aware).
- **Coding sessions** (`coding_projects`, start/stop high-risk, own processes only) and the **RustDesk helper** (`remote_desktop_status/start`, "Open RustDesk" button).
- **Supervised GUI-agent mode** (off by default): approved, time-limited, visible session; foreground allowlist, blocklists, fixed key list, no typing into password boxes, audited with picture references, STOP button, session screen in the app.
- **Optional local-AI fallback** (loopback only, read-only tools, off by default) and `ai_provider = "local"`.
- **Roles:** `viewer` (look only) and `owner`; `pair --role viewer`; `GET /me`; `token_ttl_days`; `devices` shows role, last seen, link, expiry.
- Docs: `docs/SETUP_ORDER_BN.md`, `docs/REMOTE_DESKTOP_BN.md`, `docs/cortex-wake/*`, threat model sections 4.9-4.15, troubleshooting items 17-27, user guide sections 9-16, an honest "what works when" table in the README.

### Changed
- `GET /health` now returns names and coarse numbers (still no secrets). `GET /screenshots/{name}` accepts `quality=low|normal` (a plain number still means JPEG quality).
- `POST /pair` also returns the phone's role. The task payload also returns `model` and `fallback`.
- The AI tool list hides the GUI input tools unless a GUI session is active.
- The home screen is longer: coding sessions and RustDesk are in a collapsed section at the bottom.
- Version is `1.1.0-rc1` for the agent and the app.

### Security
- New channels reviewed in `docs/THREAT_MODEL.md` (SMS gateway phone, BLE, GUI session, picture input, admin failover task, local AI, viewer role).
- Typed GUI text is never written to the audit log (`ActionSpec.redact`).

### Verified here
- `python -m pytest`, `flutter analyze`, `flutter test`, `scripts/check.ps1` (see the final numbers in `NEEDS_ME.md` / `PROGRESS.md`); the shared Cortex Wake vectors in Python, Dart and C++/WebAssembly.

## 1.0.0-rc1

Release candidate. Everything below is covered by automated tests; items that need the owner's own key, phone, SMS gateway, Android SDK or a real shutdown are listed in `NEEDS_ME.md` and were **not** verified.

### Added
- **Coding-agent watcher** (`watch_rules`): `process_exit`, `log_stalled`, `log_pattern` rules against `watched_programs` / `allowed_logs` names only; a thread in `serve` checks every 30 s; alerts carry just the rule name and a fixed sentence (never log text); dedupe + cooldown; optional push; `GET /watch`; `doctor` validates the rules; Flutter **Watch** screen.
- `ask --dry-run` prints the exact system prompt and tool list (no key, no network).
- AI task history: SQLite table with retention, `GET /ai/history`, `ai-history` command.
- `ai-usage` cost estimate from prices you set (`ai_price_per_mtok_input/_output`); nothing hard-coded.
- Bilingual (English/Bangla) API failure messages: no key, auth, no credit, rate limit, timeout, model not found, overloaded, network, server.
- 17 Bangla instruction wiring tests (scripted client; they prove wiring and confirmation flow, not model quality).
- Path fuzz tests (ADS, UNC, `\\?\`, 8.3, drive-relative, reserved names, trailing dots, junction chains).
- `scripts/precommit_check.py` + `scripts/install-git-hooks.ps1`: pre-commit secret scan.
- `scripts/check.ps1` (tests + secret scan + doctor) and `scripts/make-release.ps1` (zip of tracked files, size + SHA-256).
- `docs/THREAT_MODEL.md`, `docs/TROUBLESHOOTING.md` (Bangla), `docs/USER_GUIDE_BN.md` (Bangla).

### Changed
- `GET /alerts` now lists only power/battery alerts; rule alerts are under `GET /watch`.
- Notifier messages for non-battery events omit the battery figure.
- Version is `1.0.0-rc1` for the agent and the app.

### Security fixes
- Path components with trailing dots or spaces are refused (Windows drops them silently).
- Screenshot file-name pattern now accepts ASCII digits only (it matched other Unicode digits).
- PIN-like text typed into an AI instruction (`my pin is 1234`) is scrubbed before it reaches the audit log or AI history; audit string values and details pass through the scrubber.
- Request-validation (422) responses no longer echo the rejected input.

### Verified here
- `pytest` suite, `flutter analyze`, `flutter test`.
- Serve idle memory on this laptop: about 44 MB RSS after 60 s.

## 0.4.0
Screen viewer, power-cut watcher, push notifier, hibernate, TOTP SMS, doctor extensions.

## 0.3.x and earlier
Pairing, allowlisted actions, confirmations, SMS fallback, AI operator, Flutter app.
