# Cortex One coverage matrix (audit of v1.1.0-rc2, read from the code)

Method: read `agent/actions.py::REGISTRY` (36 actions), `agent/ai.py`, `agent/gui.py`,
`agent/sessions.py`, `agent/localai.py`, `agent/security.py` (viewer role), `mobile/lib/screens`,
`README.md` and `CLAUDE.md`. Nothing was run on Windows. "Covered" means the code path exists and
has tests; it does **not** mean it was verified on the real laptop/phone (see `NEEDS_ME.md`).

## সংক্ষেপে (বাংলা)

- ৩৬টি অ্যাকশন আছে। শক্তিশালী: পাওয়ার (shutdown/sleep/hibernate/wake), স্ক্রিনশট দেখা, কোডিং সেশন, GUI-সেশন, নিরাপত্তা।
- **নেই:** ফাইল পড়া/লেখা/সরানো/জিপ, ডকুমেন্ট (Word/Excel/PDF) তৈরি, ওয়েবপেজ পড়া, CSV/Excel বিশ্লেষণ, শিডিউল, স্টোরেজ রিপোর্ট।
- `run_script` (high-risk, শুধু নাম) হলো মালিকের অনুমোদিত স্ক্রিপ্ট চালানোর নিরাপদ পথ; "সব কাজ" এর দিকে যেতে এটাই সবচেয়ে সস্তা পথ।
- স্ক্রিন: লাইভ ভিডিও নেই। দুটি পথ আছে: স্ক্রিনশট (অটো-রিফ্রেশ) এবং RustDesk (লাইভ, আলাদা অ্যাপ)।
- README-তে ব্রাউজার/Office অটোমেশন "ইচ্ছাকৃতভাবে বাদ" লেখা আছে। এটা আপনার "সব কাজ" চাওয়ার সঙ্গে সরাসরি দ্বন্দ্বে; নিচে সমাধান-প্রস্তাব আছে।

## Matrix

Legend: Covered / Partial / Missing. Offline = works with no internet on the laptop (LAN/SMS still needed to command it).

| # | Category | Status | Actions / parts that cover it | Offline | Risk | Note |
|---|---|---|---|---|---|---|
| 1 | Writing and documents | Missing | `open_app` (e.g. notepad, word) + GUI session (`gui_type` max 200 chars) | yes | low/high | No create/edit/export of docx, xlsx, pdf. GUI route is slow and weak. |
| 2 | File and computer management | Partial | `list_files`, `find_files`, `copy_file` (never overwrites), `make_folder` | yes | low | No read, move, rename, zip, delete, or disk-usage report. Deliberate: no delete anywhere. |
| 3 | Communication, calendar, email | Missing | `open_url` (allowed domains), notifier (outbound alerts only) | no | low | Cannot read or send mail, no calendar. |
| 4 | Internet and research | Partial | `open_url` (https, exact allowed host, opens default browser) | no | low | AI cannot read the page it opened. No page-text fetch, search, download, or form fill (GUI session could click). |
| 5 | Business and finance | Missing | `run_script` | yes | high | Out of scope in code. See policy note below. |
| 6 | Software and development | Covered (core) | `coding_session_start/stop/list`, `tail_log`, `agent_watch`, `watch_rules` alerts, `remote_desktop_start/status`, `run_script` | yes | high/low | No git or test-runner action; use approved scripts or the coding session itself. |
| 7 | Learning and skills | Covered by AI | The AI operator answers directly; `open_url` for courses | no | low | Needs no PC action. |
| 8 | Graphics and design | Missing | `open_app` + GUI session | yes | high | |
| 9 | Video | Missing | `open_app` only | yes | low | |
| 10 | Audio and music | Missing | none | yes | n/a | Volume/media keys explicitly out of scope. |
| 11 | 3D and games | Missing | `open_app` | yes | low | |
| 12 | AI assistant use | Covered | `ask`, `/ai/tasks`, voice/text/pictures in app, history, usage caps | no (online) | low | Not verified with a real key from the phone yet. |
| 13 | AI agent / multi-step work | Partial | Tool-use loop (max 8 steps, token caps), pending confirmations for high-risk | no | low/high | Capped by what REGISTRY offers. |
| 14 | Repetitive automation | Partial | `run_script` (name only, confirmed), `watch_rules` | yes | high | No schedules ("every night at 2"), no script parameters. |
| 15 | Data analysis (Excel/CSV) | Missing | none | yes | n/a | AI cannot open a CSV/XLSX. |
| 16 | Local AI (offline) | Partial | `agent/localai.py`: 127.0.0.1 endpoint, `LOCAL_TOOLS` read-only, fallback on network errors | yes | low | Never exercised on the 4 GB laptop; small models only. |
| 17 | Computer maintenance | Partial | `status`, `system_info`, `list_processes`, `power_capabilities`, `take_screenshot` | yes | low | No storage report, cleanup, install/update, settings. The C: drive problem had to be solved by Claude Code on the laptop. |
| 18 | Cyber security | Partial | `tail_log`, audit log + export, `doctor` | yes | low | No scanners. Appropriate. |
| 19 | Network management | Partial | netwatch (reports state), bind rules, `/health` link kind, admin scripts for failover | yes | low/admin | No ping/diagnose action for the AI. |
| 20 | Data protection (backup, encrypt, restore) | Missing | `copy_file` as a poor backup, `run_script` | yes | high | No zip, encrypt or restore. |
| 21 | Science and maths | Covered by AI / Partial | AI reasoning; code via coding session | yes/no | | |
| 22 | Engineering / CAD | Missing | `open_app` + GUI session | yes | high | The owner has AutoCAD installers, so GUI session is the only route. |
| 23 | Robotics | Out of scope here | coding session can run another project (e.g. hermes-ai) | yes | high | |
| 24 | Office and administration | Missing | none | yes | n/a | Policy: never use Cortex One on bank/office data (see below). |
| 25 | Remote work | Partial | `remote_desktop_start/status` (RustDesk), `open_app` for meeting apps | no | high | |

### Other parts of the owner's stated goals

| Goal | State |
|---|---|
| Phone turns laptop/desktop OFF | Code and tests done: `shutdown`, `sleep`, `hibernate`, `restart`, `cancel_shutdown`, `emergency_stop`. Real run untested. |
| Phone turns laptop ON | `wake_computer` (WoL from another machine), SMS gateway, BLE, ESP32 servo firmware. Compiled once, **never flashed**. Wake from full shutdown depends on BIOS and Ethernet. |
| Voice, text, picture commands | App has `speech_to_text`, `image_picker`, `/ai/tasks` with up to 3 pictures. No real-phone test. |
| See the laptop monitor on the phone | Screenshots (`/screenshots`, `screen_view.dart`, optional auto-refresh), GUI session screenshots, RustDesk for live view. No built-in live video. |
| Never disconnected | Tailscale/LAN failover in the app, netwatch, SMS and BLE fallbacks, battery watcher. Cannot be literally guaranteed (power cut, router down, empty battery); the "wake controller" needs its own power backup. |

## Policy note

`README.md` says browser and Office automation are "intentionally out of scope", but the owner's goal is
"do everything a person can". Recommended resolution, keeping the safety rules in `CLAUDE.md`:

1. Keep: no free shell, no free path, high-risk needs confirmation, AI cannot run high-risk.
2. Add safe, narrow native actions (below), each with tests and AI abuse tests.
3. Ship a small library of owner-reviewed approved scripts (via `run_script`) for everything else.
4. Keep GUI session as the last-resort "anything" path (already time-boxed, foreground-allowlisted).
5. Document that Cortex One must not be used on bank or office data (the owner states AI use in bank
   work is prohibited). Home laptop only.

## Top 8 safe additions (not implemented)

Every new action becomes an AI tool automatically, so each needs: success, denial, bad-params tests,
AI abuse tests (injection, oversized output, path escape), viewer-role decision in
`tests/test_phase9_roles.py`, and a mutation check.

| # | Action (name only; no free paths) | What it does | Risk | Confirmation |
|---|---|---|---|---|
| 1 | `read_text_file(path)` | Read a text/CSV/log file inside `allowed_roots` via `resolve_allowed()`; size cap 64 KB; wrapped untrusted; scrubbed | low | none |
| 2 | `disk_usage_report(root)` | Top 15 folders by size inside an allowed root (names and GB only, bounded walk, junction-safe). Would have solved the C: drive problem from the phone. | low | none |
| 3 | `fetch_page_text(url)` | HTTPS GET only, host exactly in `allowed_domains`, no cookies/auth, 200 KB cap, HTML stripped to text, untrusted. Gives the AI web reading without a browser (light for 4 GB RAM). | low | none |
| 4 | `write_report(name, text)` | Create a NEW .txt/.md file in a dedicated `reports_dir` inside the roots; fixed name pattern; never overwrite; size cap | low | none |
| 5 | `make_document(kind, name, content)` | Create docx/xlsx/pdf in `reports_dir` from structured content (small libs, optional dependency; fails clearly if missing); never overwrite | low | none |
| 6 | `zip_folder(path, name)` | Zip a folder inside the roots into `reports_dir`; never overwrite; size cap | low | none |
| 7 | `archive_file(src)` | Move (not delete) a file from an allowed root into an `archive_dir` with a timestamp name; never overwrites; no hard delete | high | two-step |
| 8 | `run_schedule` / `schedules` config | Owner defines named schedules in config that call only low-risk actions at set times; results to alerts; AI cannot create schedules | low | owner config only |

Not recommended: Playwright browser automation on the 4 GB laptop (heavy; `fetch_page_text` plus GUI session covers most needs), clipboard access (leaks secrets), package install/update without a per-package allowlist.

## Session-4 candidates that are not new actions

1. **Power-survival queue**: persist accepted commands and AI tasks in SQLite so they survive a power cut and resume after the agent restarts (`install-startup.ps1` already starts it at login).
2. **Phone approval for Claude Code prompts**: forward "needs permission" events from a coding session to the phone. Must keep the rule that confirmations are never auto-approved.
3. **Time-boxed permissions**: the GUI session already is one. Do **not** generalise to auto-approving high-risk actions (it breaks the "never auto-confirm" rule in `CLAUDE.md`).
4. **Low-bandwidth mode** in the app: text-only screen description, command queue while offline.
5. **Wake controller**: ESP32 with Wi-Fi plus the existing BLE/SMS path, on its own power bank; test WoL from shutdown over Ethernet first because it may remove the need for the servo.

## Found while auditing

- One test passed on Windows only by accident (`test_project_names_only_in_capabilities`): on Linux the test folder is both a coding-project path and an allowed root, and `/capabilities` lists allowed roots by design. The assertion was narrowed to the project list and `argv`. No code leak.
- Suite on Linux (Python 3.13): 1286 passed, 21 skipped (Windows-only), 0 failed after that change.
