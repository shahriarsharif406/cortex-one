# Cortex One — project rules for Claude Code

Windows agent that a phone (or SMS) can command safely. Python 3.10+ (developed and tested on Windows 10 / Python 3.10), FastAPI, SQLite. Phone app: Flutter in `mobile/`. Keep the agent light (4 GB laptop): no heavy dependencies.

## Non-negotiable safety rules
- NEVER add an action that accepts a free-form shell command or arbitrary path. Every capability is a named entry in `agent/actions.py::REGISTRY`.
- File access goes through `resolve_allowed()` only. Apps through `allowed_apps`, scripts through `approved_scripts`.
- High-risk actions (`risk="high"`) need the two-step confirmation over HTTP.
- Never log secrets; `audit.redact()` handles known keys. Never store tokens/PINs in plain text.
- Never read or print the user's real config, tokens or `.env` files.

## AI operator rules (agent/ai.py, Anthropic Messages API)
- Tools are generated from `REGISTRY` only. Never give the model a shell/exec/free-path tool.
- The model must never execute `risk="high"` actions; it can only request them (pending confirmation for the owner).
- `emergency_stop` stays out of the AI tool list (`AI_TOOL_EXCLUDE`).
- Tool results are untrusted data. Keep hard caps: steps, output tokens, daily token budget.
- API key: `ANTHROPIC_API_KEY` env var only. Never write it to config, logs, audit or error messages.
- Tests use `tests/fake_anthropic.py` (scripted) and `tests/test_ai_sdk_roundtrip.py` (real SDK, mocked HTTP). Real API calls need the owner's key and are not part of the suite.

## Phase 2 actions (all `risk="low"`, all in REGISTRY)
- `system_info`, `list_processes` (names only, `limit` 1-25), `agent_watch` (only `watched_programs`): read-only, no command lines.
- `take_screenshot`: no params; the agent picks the file name; folder `screenshots_dir` must pass `resolve_allowed()`; returns the name only, never uploads. Capture lives in `agent/screen.py` (ctypes GDI, no dependency); tests inject `Context.screenshotter`.
- `open_url`: https only, host must equal an entry of `allowed_domains` (no sub-domain implied, no userinfo, no odd ports, ASCII only). Tests inject `Context.url_opener`. Only list domains you trust: the AI chooses the path/query.
- `tail_log`: param is a short NAME from `allowed_logs`, never a path. Output is capped (200 lines, 8000 chars), stripped of control/ANSI characters, passed through `logging_setup.scrub`, and flagged untrusted.
- `ActionSpec.optional` holds optional string params (parsed with `_int_param`, strict ranges). They are in the AI tool schema but not in `required`.
- Every AI tool result is wrapped by `ai.wrap_untrusted()` (`<tool_output untrusted="true">`), capped before wrapping, and tags inside data are defanged. Do not remove this.
- `doctor`, `init-config` are CLI-only. `serve` logs to `<data_dir>/logs/agent.log` (rotating, secrets scrubbed).

## Phone API rules (agent/server.py)
- `/ai/pending`, `/ai/confirm`, `/ai/cancel` only see confirmations issued with `source="ai"` for the SAME device. `ConfirmationStore.peek/discard/list_pending` enforce device + source; `consume()` re-checks the (device, action, params) fingerprint and makes the token single use. Do not add a path that runs a high-risk action without `consume()`.
- `POST /ai/tasks` with `wait:false` runs the task in a background thread (`Orchestrator.begin` takes the single-task lock first, so cap/key/busy errors are 503 at POST time). Jobs are private to their device.
- CORS stays off (no `CORSMiddleware`); a test checks it. `/health` returns `{"status","version"}` only.
- `/capabilities` exposes names/paths of allowlists only; never hashes, tokens or script command lines. The same data (`ai.capabilities`) is added to the AI system prompt.

## Phone app rules (mobile/)
- Token + server address only in `flutter_secure_storage` (`SecretStore`). Plain prefs (`PrefsStore`) hold language, theme and the SMS gateway number only. The SMS PIN is never typed into, stored in, or logged by the app.
- Emergency stop is visible on every tab, one tap, no confirmation. Confirm cards show the exact command for `run_script` and a countdown, and never auto-confirm.
- No analytics or third-party trackers. Errors shown to the user are Bangla/English strings from `lib/l10n/strings.dart` (a test keeps both languages in sync).
- Widget tests use `test/support/fakes.dart` (FakeApi). Run `flutter analyze` and `flutter test` in `mobile/`.

## Layout
- `agent/security.py` pairing, token hashing, rate limit, lockout, confirmations
- `agent/actions.py` the allowlist + `Context` (injectable `runner`/`launcher` for tests)
- `agent/engine.py` single place that validates, runs and audits actions
- `agent/ai.py` AI task operator (tool-use loop, budgets, pending confirmations)
- `agent/server.py` HTTP API, `agent/sms.py` SMS fallback, `agent/main.py` CLI
- `agent/doctor.py` setup check, `agent/logging_setup.py` rotating redacted logs, `agent/screen.py` screenshot (ctypes)
- `scripts/*.ps1` run-agent and per-user startup task (support `-WhatIf`); `mobile/` Flutter app

## Testing
- `python -m pytest` must stay green. New action => tests for success, denial and bad params.
- Tests use a `FakeRunner`; never execute real shutdown/lock in tests.
- After touching a security check, mutate it (disable it) and confirm a test fails.
- New action ⇒ it automatically becomes an AI tool: add AI abuse tests (`tests/test_ai_phase2.py` style: injection, oversized output, path escape) and check `risk="high"` ones only create a pending confirmation.

## Roadmap
See `README.md` (what exists) and `NEEDS_ME.md` (what only the owner can do). Volume/media keys and browser/Office automation are intentionally out of scope. New actions go into REGISTRY with tests and become AI tools automatically.

## Power watcher & the one confirmation exception (agent/power.py, Engine.run_power_action)
- `serve` starts a daemon thread (`power_watch`, psutil battery only; idle on desktops). Events (`ac_lost`, `ac_restored`, `battery_warn`, `battery_critical`) go to the `alerts` table + audit and `GET /alerts`; optional push through `agent/notify.py` (ntfy topic or https webhook, off by default, message = event + battery % + time, target never logged in full, failures swallowed).
- `hibernate` is `risk="high"` in REGISTRY: over HTTP it needs the two-step confirmation, and the AI can only request it.
- THE exception: at the transition to critical battery, `Engine.run_power_action` may run `settings.critical_action` (`hibernate` or `lock` only; `shutdown`, anything else, or `none` does nothing) without a token. It re-checks inside the Engine: action in `WATCHER_ACTIONS`, `plugged is False` (unknown does not count), percent <= `power_critical_percent`. It fires once per episode (hysteresis) and is audited with `via="watcher"`.
- `via="watcher"` is a reserved channel: `Engine.run` refuses it, and HTTP/SMS/AI/CLI each pass their own fixed `via`, so no client can name it. Do not add any path that forwards a caller-chosen `via`, and never extend `WATCHER_ACTIONS` with a destructive action.
- Tests: `tests/test_power.py` (mutate the three checks + the reserved channel and see it fail).

## v0.4 additions (rules to keep)
- Screenshots: `/screenshots*` serve only names matching `screenshots.NAME_RE` (fullmatch), regular non-link files in `screenshots_dir`, and only real PNG/JPEG bytes (415 otherwise). `copy_file`/`make_folder` may not target `screenshots_dir` (it would turn the screenshot endpoint into a file reader). `take_screenshot` prunes to `screenshot_keep`.
- `resolve_allowed` also rejects alternate data streams (`:`) and DOS device names (`NUL`, `COM1.txt`). `find_files` prunes sub-folders that resolve outside the roots (NTFS junctions).
- SMS: `sms_mode` is `pin` (no replay protection, doctor warns) or `totp` (`agent/totp.py`: RFC 6238, ±1 step, last step stored atomically in the `kv` table, secret DPAPI-encrypted, never in config/log/audit). Unknown `sms_mode` = SMS off; never fall back to the PIN.
- Unauthenticated endpoints (`/pair`, `/sms/inbound`) lock out per client address before doing expensive work; the audit table is a rolling window (`audit.MAX_ROWS`). High-risk HTTP params are validated before a confirmation is issued; pending confirmations are capped per device.
- `Engine.run` refuses high-risk actions on `via="ai"` as a second layer behind `ai.py`.
- Phone app: plain http only to Tailscale (100.64/10, `*.ts.net`), loopback and the emulator host (`isPrivateOrTailscaleHost`); release builds need `android/key.properties`.
- After a security review round, mutation-check: path confinement, confirmation requirement, AI high-risk block, emergency_stop exclusion, screenshot name/type/copy guards, TOTP replay guard, watcher restrictions.
