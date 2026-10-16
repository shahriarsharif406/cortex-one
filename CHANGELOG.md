# Changelog

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
