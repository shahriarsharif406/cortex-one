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

## v1.0.0-rc1 additions (rules to keep)
- Coding-agent watcher (`agent/watch.py`, `settings.watch_rules`): rule `target` is a NAME from `watched_programs` (process rules) or `allowed_logs` (log rules), never a path; invalid rules are rejected, not evaluated. Alerts hold only the rule name + a fixed sentence (never log text, process lines or patterns); same rule is deduped and cooled down. `GET /watch` needs a device token; `GET /alerts` is power-only. Mutation-check: the target allowlist in `parse_rules`.
- AI history (`ai_history` table, `GET /ai/history`, `ai-history`): instruction clipped to 200 chars and passed through `logging_setup.scrub`; retention `MAX_HISTORY_ROWS`. `ask --dry-run` must never build a client or read the key. Costs come only from owner-set `ai_price_per_mtok_*` (nothing hard-coded). API failures are mapped by class name/status to fixed bilingual sentences; never echo exception text or bodies.
- `resolve_allowed` refuses path components that end in a dot or space. Screenshot names are ASCII-digit only.
- `audit.redact` and audit `detail` pass through `scrub`; 422 responses do not echo input. `tests/test_secret_hygiene.py` greps every sink after a full session: extend it when adding a new sink or secret.
- Secrets in git: `scripts/precommit_check.py` (hook via `scripts/install-git-hooks.ps1`, release check via `scripts/check.ps1`). Keep real keys out of tests too (short fake key-shaped strings are allowed under `tests/`, realistic-length ones are blocked).
- Release: `scripts/make-release.ps1` packs tracked files only (`git archive`). `scripts/check.ps1` = tests + secret scan + doctor.
- When mutation-checking an untracked file, commit first: `git checkout` cannot restore it.

## v1.1.0-rc1 additions: session 2 (rules to keep)
- **Bind addresses** (`agent/netbind.py`): only 127.0.0.0/8, Tailscale 100.64.0.0/10, or a private LAN address the owner listed in `hosts`/`host`; never `0.0.0.0`/`::`/public/host names. One bad entry rejects the list and `serve` refuses to start. `BindManager` retries a missing address with backoff (cap 10 min) and never falls back to another address.
- `/health` is unauthenticated and small (names, version, uptime, coarse battery, link kind, network state); the last power request is added only for a valid token. Every POST body is capped before it is read (64 KB; pictures only on /ai/tasks) and chunked bodies are refused. No token, path, MAC or config value. The network watchdog (`agent/netwatch.py`) only reports; adapter changes belong to the separate admin task `scripts/network-failover.ps1` (SYSTEM task, script folder writable only by admins, installed by `install-network-failover.ps1`). Admin scripts must keep every changing command inside `ShouldProcess` (`tests/test_admin_scripts.py`). Never run them for real in tests or sessions.
- **Power layer**: `wake_computer` (Wake-on-LAN) only for names in `wake_targets`; MAC and broadcast are re-validated on every call (broadcast = 255.255.255.255 or a private-LAN x.y.z.255); rate limited. `sleep`, `hibernate`, `shutdown`, `restart` are all `risk="high"`. `power_capabilities` and `/health` never contain MAC addresses (only the local `doctor` prints them).
- **Phone app**: tokens/addresses/gateway tokens only in secure storage. Read-only calls fail over Tailscale -> LAN; calls that change something go to ONE address and are never retried elsewhere. Plain http to a home-LAN address needs the per-computer "my own network" tick. Every confirmation (power card, tools card, AI pending cards, gateway press) goes through the phone's biometric/screen lock first (`AppState.authorize`); a refused prompt sends nothing. The state badge never claims more than the phone can know ("probably asleep").
- **Cortex Wake** (`docs/cortex-wake/PROTOCOL.md`): every BLE frame is HMAC-SHA256 tagged; the tag is checked before the counter; the counter is saved before acting; PRESS is never retried; press time is capped; calibration needs the physical BOOT button. Python (`reference.py`), Dart (`mobile/lib/wake`) and C++ (`firmware/cortex-wake/include/cw_auth.h`) must all pass `docs/cortex-wake/test_vectors.json`; change the vectors only through `reference.py --write`. SMS gateway: allowlist, unknown senders get silence, TOTP from a SEPARATE wake secret with a stored replay guard, lockout, state-aware press (ON laptop is not pressed; unknown state needs `FORCE`). The HTTP listener never binds `0.0.0.0` and needs a bearer token. The firmware compiles (PlatformIO esp32dev, session 3) but has never been flashed or run: keep the "NOT FLASHED, NOT TESTED ON HARDWARE" banner until it has.
- **Pictures** (`agent/images.py`): refuse, never strip. At most 3 JPEG/PNG, 1.5 MB each, no metadata blocks, strict structure; image bytes never reach logs/audit/history; history stores "+N images"; the worst-case image tokens (x max steps) are checked against the per-task and daily caps; screen/picture text is untrusted.
- **Coding sessions / RustDesk**: the phone and the AI name a project; the argv/folder come from the owner's `coding_projects` (folder inside `allowed_roots`). `coding_session_start/stop` and `remote_desktop_start` are high-risk; stop touches only sessions this agent started. `high` requests that can never run are refused before a confirmation is asked (`sessions.precheck_high`).
- **GUI-agent mode** (`agent/gui.py`) is OFF by default and has never run on a real screen. The only way in is the high-risk `gui_session_start`; every input needs an allowed app in front; blocklists are added to, never replaced; the AI gets GUI tools only while a session is active, one GUI action per turn, with step and token caps; typed text is never logged (`ActionSpec.redact`); screenshots reach the AI only as image tool results (keys starting with `_` are stripped from HTTP responses). Tests use fake backends; `conftest` makes the real factories raise, keep that.
- **Local AI** (`agent/localai.py`): endpoint must be `http://127.0.0.1:PORT`; only `LOCAL_TOOLS` (read-only); no high-risk, no GUI, no pictures; fallback only for network/timeout errors and only if `ai_fallback_to_local`; answers carry the model name.
- **Roles**: `viewer` phones may only run `VIEWER_ACTIONS` and a short list of GET endpoints; `tests/test_phase9_roles.py` has a matrix that fails until every new route gets an explicit owner/viewer decision. `Engine.run(role=...)` is the second layer. Token expiry is `token_ttl_days` (0 = none); revoke works on the very next request.
- After a session-2 style review round, mutation-check one module at a time: bind validation, WoL allowlist, confirmation for sleep/hibernate/shutdown/coding_session_start, BLE HMAC + counter, SMS TOTP replay, image validation, GUI session gate + foreground allowlist, viewer role denial.

## v1.1.0-rc2 additions: session 3 (rules to keep)
- **Config is validated, never guessed** (`config.ConfigError`): wrong JSON/kind/negative/port -> clear message, exit 2. Do not add a `try/except` that falls back to defaults for a security setting. Unknown keys are only a `doctor` WARN. `tests/test_config_fuzz.py` covers hosts, wake_targets, coding_projects, gui_agent.
- **MACs**: only `doctor --show-mac` (console) and config.json. `wake-setup` never prints them. The two OS queries in `wakeinfo` (`powercfg /devicequery ...`, one `Get-NetAdapter -Physical`) are fixed read-only commands; tests replace both (see `conftest`).
- **Cortex Wake laptop byte** = low nibble state (0 off, 1 on, 2 unknown, 3 blink) + high nibble raw light level. `reference.py classify_led` / `cw_auth.h classify_led` / `test_vectors.json led_cases` must stay identical (`reference.py --write` only). ON on a blinking laptop wakes it; PRESS on a blinking laptop still needs FORCE.
- `tests/test_e2e_session3.py` is the scripted whole-flow test with the audit/HTTP leak grep: extend it for every new channel.
- ctx.gui is built lazily and captures `gui_backend`/`gui_foreground` at first use: tests must inject fakes before the first access.

## Session 4 actions (all `risk="low"`, rules to keep)
- `read_text_file(path)`: `resolve_allowed`, regular non-link file, extension allowlist `TEXT_EXTENSIONS`, never secret-looking names (`_SENSITIVE_NAME`) or anything under `data_dir`; 64 KB / 8000 chars, scrubbed, untrusted.
- `disk_usage_report(root)`: bounded walk (entries + seconds), junction pruning, names/GB only.
- `fetch_page_text(url)`: `check_url` + no query/fragment + short path; every redirect re-checked against `allowed_domains`; resolved IPs must all be global (`_public_ips`); connection pinned to the checked IP; text types only; 200 KB; untrusted. Tests inject `Context.page_fetcher`; never hit the network in tests.
- `write_report(name, text)` / `zip_folder(path, name)`: only create NEW files in `reports_dir` (inside `allowed_roots`, not the screenshots or data folder); name regex `_REPORT_NAME`; exclusive create / rename, never overwrite; zip skips secret-looking names and links, limits leave no partial file. `ActionSpec.long` lets only `text` exceed `MAX_PARAM_LEN`.
- Mutation-checked: sensitive names, data_dir refusal, private-IP refusal, query refusal, overwrite, redirect re-check, extension allowlist, reports_dir confinement, name regex, zip limits, content types.
