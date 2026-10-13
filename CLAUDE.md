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
