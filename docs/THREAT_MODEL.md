# Cortex One - threat model (v1.0.0-rc1)

Cortex One is a Windows agent that a phone (HTTP over Tailscale) or an SMS gateway can command, optionally through an AI operator (Anthropic Messages API). This document lists what is protected, who may attack it, where trust changes, which control answers which threat, and which test proves that control. Test names refer to files in `tests/`.

## 1. Assets

| Asset | Why it matters |
|---|---|
| The laptop itself (files, running programs, power state) | The agent can lock, shut down, restart, hibernate, run approved scripts and read/copy files |
| Device tokens, pairing codes, SMS PIN / TOTP secret, gateway secret | Anyone holding one can command the laptop |
| `ANTHROPIC_API_KEY` | Spend money, impersonate the owner to the API |
| Screenshots and allowlisted logs | May show private screen content or source code |
| Audit trail | Evidence of what happened; must stay trustworthy and secret-free |
| The owner's attention (alerts) | A flood of fake confirmations or alerts hides the real one |

## 2. Attackers

1. **Network stranger** - can reach the agent's port (wrong Wi-Fi, exposed host) but has no token.
2. **Nosy local user / malware without admin** - can read files the agent user can read, can call the loopback port.
3. **Lost or stolen phone** - holds a valid device token and the app.
4. **SMS spoofer / replayer** - can send SMS from another number or replay a captured message.
5. **Prompt injector** - controls text the AI later reads: file names, process names, log lines, web content, script output.
6. **Curious or compromised model** - the AI itself behaves badly (confused, jailbroken).
7. **Careless owner** - commits a key, types a PIN into a text box, exposes `0.0.0.0`.

Out of scope: an attacker with administrator rights on the laptop, physical access to an unlocked laptop, a compromised Windows kernel, and the security of Tailscale, Anthropic or the phone OS themselves.

## 3. Trust boundaries

```
 phone app --Tailscale/HTTP--> [ server.py ] --> [ engine.py ] --> REGISTRY actions --> Windows
 SMS gateway --HTTP + secret-> [ server.py /sms/inbound ] -^             ^
 AI (Anthropic API) <--tools-- [ ai.py ] -------------------+            |
 coding agent logs/processes --> [ watch.py ] --alerts only--+  power.py (battery) --+ (the one exception)
```

* Boundary A: network -> `server.py`. Everything except `/health`, `/pair`, `/sms/inbound` needs a device token.
* Boundary B: client -> `Engine.run`. The single place that validates, runs and audits an action. The `via` channel is fixed by each entry point.
* Boundary C: model -> tools. The model sees only tools generated from `REGISTRY`; everything it reads back is untrusted data.
* Boundary D: files/logs/processes -> watcher/AI. Their content is untrusted and is never turned into instructions or alert text.
* Boundary E: repository -> the outside world. Secrets must never be committed.

## 4. Controls and the tests that prove them

### 4.1 Authentication and pairing
| Control | Test |
|---|---|
| 6-digit pairing code, single use, expires; token stored only as a hash | `test_security.py::test_pairing_happy_path_and_token_not_stored_plain`, `test_pairing_code_is_single_use`, `test_pairing_code_expires` |
| Pairing lockout, per client address (one client cannot lock everyone out) | `test_security.py::test_pairing_lockout_blocks_even_correct_code`, `test_review_fixes.py::test_one_client_cannot_lock_out_everyone` |
| Concurrent use of one code fails | `test_review_fixes.py::test_pairing_code_cannot_be_used_twice_concurrently` |
| Revoked devices lose access immediately | `test_server.py::test_revoked_device_loses_access` |
| Rate limit per device | `test_server.py::test_rate_limit` |
| Protected routes reject missing/bad tokens; docs/schema hidden; CORS off | `test_server.py::test_protected_routes_need_a_valid_token`, `test_docs_and_schema_hidden`, `test_server_phase3.py::test_cors_is_off` |
| `/health` leaks only status+version | `test_server_phase3.py::test_health_has_version_and_nothing_else` |

### 4.2 Capability allowlist (no free-form command, no free path)
| Control | Test |
|---|---|
| Unknown actions / parameters rejected; every capability is a named `REGISTRY` entry | `test_actions.py::test_unknown_action_and_params_rejected`; `test_ai.py::test_tools_come_only_from_the_registry` |
| Files confined to `allowed_roots` (`..`, sibling prefix, symlink, junction) | `test_actions.py::test_paths_outside_roots_denied`, `test_sibling_folder_with_same_prefix_denied`, `test_symlink_escape_denied`; `test_review_fixes.py::test_find_files_does_not_follow_junctions` |
| Windows path tricks: ADS, UNC, `\\?\`, 8.3 names, drive-relative, reserved names, trailing dots/spaces, mixed case, junction chains | `test_path_fuzz.py` (fixed attack list, 4000 random paths, action fuzz, junction and 8.3 tests) |
| Apps and scripts only by approved name | `test_actions.py::test_open_app_only_approved`, `test_run_script_only_approved` |
| `open_url` https only, exact allowlisted host | `test_actions_phase2.py` (url tests), `test_path_fuzz.py::test_names_that_are_not_allowlisted_never_resolve` |
| `tail_log` takes a short name, never a path; output capped, scrubbed, flagged untrusted | `test_actions_phase2.py`, `test_ai_phase2.py` |
| Screenshot names match one strict ASCII pattern; only real PNG/JPEG bytes; no links; copy/make_folder may not target that folder | `test_screenshots.py`, `test_review_fixes.py::test_copy_into_screenshots_folder_is_refused`, `test_path_fuzz.py::test_screenshot_names_are_a_closed_pattern` |

### 4.3 High-risk actions and confirmation
| Control | Test |
|---|---|
| `shutdown`, `restart`, `hibernate`, `run_script` need a two-step, device-bound, action-bound, single-use, expiring token | `test_server.py::test_high_risk_needs_confirmation`, `test_confirmation_cannot_be_replayed_or_swapped`, `test_confirmation_bound_to_script_name`; `test_security.py::test_confirmation_is_bound_single_use_and_expires` |
| Parameters validated before a token is issued; pending confirmations capped per device | `test_review_fixes.py::test_high_risk_params_are_validated_before_a_token_is_issued`, `test_pending_confirmations_per_device_are_capped` |
| Emergency stop on every channel | `test_server.py::test_emergency_stop_endpoint`; `test_actions.py::test_emergency_stop_blocks_scripts` |

### 4.4 AI operator
| Control | Test |
|---|---|
| Tools generated from `REGISTRY` only; `emergency_stop` excluded | `test_ai.py` (tools tests) |
| AI cannot execute high-risk actions; it can only request them (pending confirmation for the owner) | `test_server_phase3.py::test_confirm_runs_exactly_the_requested_action_once`, `test_review_fixes.py::test_engine_refuses_high_risk_actions_from_the_ai_channel`, `test_power.py::test_ai_cannot_hibernate_only_request`, `test_ai_phase4.py::test_bangla_instruction_wiring` |
| The AI's confirmations are visible/decidable only by the same device | `test_server_phase3.py::test_pending_is_per_device_and_excludes_plain_http_confirmations`, `test_confirm_endpoint_cannot_redeem_plain_http_tokens` |
| Tool output is fenced as untrusted, capped, tags defanged; injection in logs/names cannot make the AI do harm | `test_ai_phase2.py::test_injection_in_log_text_cannot_make_the_ai_do_harm`, `test_review_fixes.py::test_wrap_untrusted_defangs_any_case_and_spacing` |
| Hard caps: steps, output tokens, daily token budget, requests per minute, one task at a time | `test_ai.py` (budget, step cap, busy tests) |
| API key only from the environment; failures never leak key or response bodies; instructions/history scrubbed | `test_ai.py::test_api_failure_does_not_leak_details`, `test_ai_phase4.py::test_failure_mapping_*`, `test_secret_hygiene.py` |
| Dry run shows exactly what would be sent, without a key or network | `test_ai_phase4.py::test_dry_run_prints_the_exact_prompt_and_tools_without_network_or_key` |

### 4.5 SMS fallback
| Control | Test |
|---|---|
| Sender allowlist, gateway secret, lockout before the expensive hash | `test_sms.py::test_unknown_sender_is_silent_and_logged`, `test_wrong_pin_locks_sender_out`; `test_review_fixes.py::test_sms_inbound_bad_secret_is_locked_out_before_pbkdf2` |
| TOTP: RFC 6238, +-1 step, replay guard persisted, secret encrypted with DPAPI | `test_sms_totp.py` (RFC vectors, replay, restart, DPAPI tests) |
| Unknown `sms_mode` never falls back to the PIN; small command set | `test_review_fixes.py::test_unknown_or_sloppy_sms_mode_never_falls_back_to_the_pin`; `test_sms.py::test_only_small_command_set_exposed` |

### 4.6 Watchers (the only code paths that act or alert without a request)
| Control | Test |
|---|---|
| Power watcher may run only `hibernate`/`lock`, only when `plugged is False` and charge <= critical, once per episode; `via="watcher"` is reserved | `test_power.py::test_shutdown_and_junk_are_never_executed_by_the_watcher`, `test_no_action_while_plugged_in_even_at_critical`, `test_watcher_channel_is_reserved`, `test_critical_hibernate_runs_once_through_the_engine` |
| Coding-agent watcher: rule targets must be allowlisted names; alerts carry only rule name + fixed sentence, never log text; dedupe + cooldown; bad rules rejected | `test_watch.py::test_rule_with_non_allowlisted_target_is_rejected`, `test_alerts_never_contain_log_text`, `test_pattern_dedupe_and_cooldown` |
| Notifications: ntfy topic hard to guess, https-only webhook, no redirects, failures silent, target never logged in full | `test_power.py::test_ntfy_topic_must_be_hard_to_guess`, `test_no_redirects_followed`, `test_notifier_failure_is_silent_and_never_logs_the_target` |

### 4.7 Secrets in outputs and in git
| Control | Test |
|---|---|
| Logs, audit, DB, CLI, CSV export and HTTP responses contain no token/PIN/TOTP/gateway secret/API key | `test_secret_hygiene.py::test_full_session_leaks_nothing` |
| Error bodies do not echo input or internals | `test_secret_hygiene.py::test_error_responses_do_not_echo_input_or_internals` |
| Audit is a rolling window with size-capped params | `test_review_fixes.py::test_audit_log_is_capped`, `test_audit_params_are_size_capped` |
| Pre-commit hook blocks keys, secret files and random-looking tokens | `test_precommit_hook.py` (unit rules and real commits in a temp repo) |

### 4.8 Phone app
Tokens only in secure storage; plain http only to Tailscale/loopback; emergency stop on every tab; confirm cards show the exact command and never auto-confirm; no analytics. Proved by the Flutter widget tests in `mobile/test` (`flutter test`).

## 5. Residual risks (accepted or open)

1. **Stolen unlocked phone or stolen token** - the thief can do everything the owner's phone can, including requesting confirmations and confirming them. Mitigation is operational: revoke the device (`revoke <id>`), lock the phone, keep the Android screen lock on.
2. **Plain http over Tailscale** - encrypted by WireGuard, but the agent speaks no TLS itself. Anyone inside the tailnet (other devices, shared nodes) can reach the port; the token is the only gate there. Keep the tailnet private and use ACLs.
3. **PIN mode SMS has no replay protection** - use `sms-setup --totp`. SMS itself is unencrypted and sender numbers can be spoofed on some networks; the PIN/TOTP is the real gate.
4. **Local malware running as the same Windows user** can read the database, the DPAPI-protected TOTP secret and the screenshots, and can call the loopback port. DPAPI protects against other users and offline disk theft only.
5. **Screenshots show whatever is on screen** (passwords being typed, private chats) and travel over the tailnet. They are view-only and auto-pruned, but a stolen token can request one.
6. **The model can still be wrong** within the allowlist (copy the wrong file, open an allowed site, make a folder). Impact is bounded by the allowlists; it cannot delete, overwrite, or run arbitrary code. Review the audit trail.
7. **Prompt injection reduces to the allowlist** - hostile text can at most steer the model toward allowed low-risk actions or a confirmation card that the owner must still approve. The card shows the exact action; read it.
8. **`run_script` runs whatever the approved script does.** Approve only scripts you wrote or fully read, and keep them outside folders the agent can write to.
9. **Watcher alerts can be missed** (agent stopped, laptop asleep, notifier down, ntfy outage). They are a convenience, not a guarantee.
10. **Hibernate/lock at critical battery run without a token** by design (the one exception). They are reversible, but a spoofed battery reading by malware could trigger them.
11. **Windows path semantics evolve** - the fuzz tests cover known tricks on Windows 10; new junction/reparse behaviours need re-testing after major Windows updates.
12. **Real-world verification is incomplete**: no real Anthropic call, real shutdown/lock, real phone, real SMS gateway or APK build has been run in the automated suite (see `NEEDS_ME.md`).
13. **The pre-commit hook is local** and can be bypassed with `--no-verify`; `scripts/check.ps1` repeats the scan before a release.
14. **Watcher limits**: a very busy log (more than 256 KB between 30 s checks) can hide an earlier match; `process_exit` matches the process name only; log paths from `allowed_logs` are opened as given (owner-controlled config). Free-text PIN scrubbing is best effort.
15. **Supply chain**: dependencies are pinned loosely in `requirements.txt`; review updates before installing.
