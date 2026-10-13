# Cortex One — project rules for Claude Code

Windows agent that a phone (or SMS) can command safely. Python 3.11+, FastAPI, SQLite.

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

## Layout
- `agent/security.py` pairing, token hashing, rate limit, lockout, confirmations
- `agent/actions.py` the allowlist + `Context` (injectable `runner`/`launcher` for tests)
- `agent/engine.py` single place that validates, runs and audits actions
- `agent/ai.py` AI task operator (tool-use loop, budgets, pending confirmations)
- `agent/server.py` HTTP API, `agent/sms.py` SMS fallback, `agent/main.py` CLI

## Testing
- `python -m pytest` must stay green. New action => tests for success, denial and bad params.
- Tests use a `FakeRunner`; never execute real shutdown/lock in tests.
- After touching a security check, mutate it (disable it) and confirm a test fails.

## Roadmap
See `README.md` (what exists) and `NEEDS_ME.md` (what only the owner can do). Next: Flutter app, then Phase 4 app/browser automation (new actions go into REGISTRY with tests, and become AI tools automatically).
