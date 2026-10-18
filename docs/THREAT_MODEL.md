# Cortex One - threat model (v1.1.0-rc2)

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

### 4.9 Network reach and the admin failover task (session 2)
| Control | Test |
|---|---|
| Bind only to 127.0.0.0/8, Tailscale 100.64.0.0/10, or a private LAN address the owner listed in `hosts`/`host`; never 0.0.0.0, `::`, a public address or a host name; one bad entry rejects the list and `serve` refuses to start | `test_phase1_net.py::test_allowed_addresses`, `test_rejected_addresses`, `test_one_bad_host_rejects_the_whole_list`, `test_serve_refuses_wildcard` |
| An address that is not up yet is retried with exponential backoff (cap 10 min) and never replaced by another address | `test_address_not_up_is_retried_then_bound_when_it_appears`, `test_never_falls_back_to_another_address`, `test_backoff_doubles_up_to_the_cap` |
| `/health` is unauthenticated and small: names, version, uptime, coarse battery, the configured address a request used, network state. No token, path, MAC or config value | `test_health_fields_and_no_secrets`, `test_health_link_only_names_configured_addresses` |
| The network watchdog only reports (TCP connects to a fixed, validated target list) and never touches adapters | `test_watchdog_never_raises_and_never_touches_adapters`, `test_targets_parse_and_reject_bad` |
| `doctor` shows MAC addresses locally only; `power_capabilities` and `/health` never include them | `test_doctor_wake_and_adapters` |
| Admin scripts change nothing under `-WhatIf` (every changing command sits inside `ShouldProcess`) | `test_admin_scripts.py` |
| `wake_computer` can only wake names the owner listed in `wake_targets`; the MAC and the broadcast address (255.255.255.255 or a private-LAN x.y.z.255) are re-validated on every call; at most 1 packet per target per 15 s and 6 per minute; the packet is exactly 6 x 0xFF + 16 x MAC to UDP port 9; a failed send is a plain error; `sleep` is high-risk like `hibernate`/`shutdown`/`restart` and the AI can only request it | `test_phase2_power.py` |

**Privilege separation of the failover task.** The agent runs as the logged-in standard user. Disabling a network adapter needs administrator rights, so it is NOT an agent action and the agent has no code path to it. `scripts/network-failover.ps1` is a separate SYSTEM scheduled task, installed by the owner with `install-network-failover.ps1`. The installer copies the script into `%ProgramData%\CortexOne\failover\` and removes inherited rights so only Administrators/SYSTEM can write there; ordinary users (and so the agent, and anything it could be tricked into running) can only read it. If the script sat in a user-writable folder, anything that could write to the agent's folder could get SYSTEM. The script takes no value from the network: adapter names are fixed at install time and pattern-checked; probe targets are fixed IP addresses; it only re-enables an adapter it disabled itself; if the tether has no internet either it re-enables Wi-Fi at once. Residual risk: an administrator who edits the script or task controls it; a malfunction can leave Wi-Fi disabled until the next retest (15 min) or until `install-network-failover.ps1 -Remove -WifiAlias <name>`.

### 4.10 Phone app with several computers (session 2)
| Control | Test |
|---|---|
| Read-only calls fail over Tailscale -> LAN with short timeouts. A call that CHANGES something goes to exactly one address and is never retried on another (a timeout does not prove the first did not receive it) | `computers_test.dart` group `FailoverApi` |
| Plain http to a home-LAN address needs a per-computer "this is my own network" tick (the token is then unencrypted on that Wi-Fi); public http stays refused | `computers_test.dart` group `addresses`, `pairing a second computer with a LAN address needs the acknowledgement` |
| Sleep / hibernate / shutdown / restart (and confirming an AI request) need the phone's biometric or screen lock first; a refused prompt sends nothing and burns no token | `computers_test.dart` groups `power card`, `every confirmation needs the biometric` |
| Tokens, addresses, gateway tokens only in secure storage; plain prefs hold only a last-seen note (time, battery, last power request) | `home_test.dart` (prefs test), `gateway_screen_test.dart` |
| The state badge says only what the phone can know: "probably asleep" after a sleep request, never "asleep" as a fact | `computers_test.dart` group `classifyPower` |
| Data-saver (SIM): low-quality screenshots, no auto-refresh, no background polling | `computers_test.dart` group `data saver` |

### 4.11 Cortex Wake: SMS gateway phone and BLE power-button robot (session 2)
New channels: SMS into an old Android phone, BLE from that phone to an ESP32, and a small HTTP listener on the gateway phone.

| Control | Test |
|---|---|
| Every BLE frame carries a 16-byte HMAC-SHA256 tag over device id, counter, command and arguments; wrong tag, wrong key or wrong device id is ignored without any answer | `wake_test.dart` shared vectors, `tests/test_cortex_wake.py::test_every_single_byte_change_is_rejected` |
| Strictly increasing counter, saved BEFORE the servo moves; replays and out-of-window counters are ignored; the tag is checked before the counter (no oracle) | vectors `replay_*`, `jump_too_far`, `bad_tag_and_old_counter`; `wake_test.dart` `a recorded frame cannot be replayed` |
| The same vectors pass in Python (reference), Dart (app) and C++ (firmware header, compiled to WebAssembly and run in Node) | `test_cortex_wake.py`, `wake_test.dart`, `firmware/cortex-wake/test/run_cpp_vectors.py` |
| Press time is capped in firmware (100..1500 ms, refused not clamped); calibration only within 60 s after the physical BOOT button | `test_firmware_main_follows_the_documented_order`, simulator tests |
| PRESS is never retried after a lost answer (it may have pressed) | `wake_test.dart` `a lost answer to PRESS is NOT retried` |
| SMS: allowlist (numbers normalised), unknown senders get silence and cost no code, TOTP from a separate wake secret with replay protection that survives restarts, lockout after 3 wrong codes, Bangla digits, no SMS text/code/full number in the log | `wake_test.dart` group `gateway controller`, `gateway_screen_test.dart` group `gateway runtime` |
| State-aware press: ON laptop is not pressed (unless PRESS ... FORCE); unknown state needs FORCE | `wake_test.dart` |
| The HTTP listener never binds 0.0.0.0 or a public address, needs a bearer token, locks out a client after 5 wrong tokens | `wake_test.dart` group `gateway HTTP listener` |
| The wake secret, BLE key and HTTP token are shown once and kept only in the secure store | `gateway_screen_test.dart` |

Residual risks: SMS sender numbers can be spoofed on some networks (the TOTP code is the real gate and a spoofed sender only makes the reply go to the real owner); a BLE frame blocked and delivered later is still accepted once; the foreground service may be killed by the phone maker's battery rules; Android may refuse to start the service from the background after a reboot; pressing the power button of a running laptop can sleep or shut it down; the state sensor can be wrong on laptops that keep USB powered. **The hardware, the Kotlin service and the BLE client were never run.**

### 4.12 Picture input to the AI (session 2)
| Control | Test |
|---|---|
| At most 3 pictures, JPEG or PNG, at most 1.5 MB each after decoding; the declared type, the magic bytes and the file structure must agree; sane dimensions; refused on any doubt | `test_phase5_images.py` (validation block) |
| Metadata is REFUSED, never silently stripped: JPEG APP1/EXIF/XMP/comment blocks and PNG text/time/EXIF chunks make the whole task fail. The phone strips them first | `test_metadata_is_refused_not_stripped`, `pictures_test.dart`, `test_picture_prepared_by_the_phone_app_is_accepted_by_the_agent` |
| The request body is capped before it is read (413) and a length-less upload is refused (411) | `test_oversized_request_is_refused_before_it_is_read` |
| Pictures cost tokens on every step, so the worst case (estimated image tokens x max steps) is checked against the per-task and daily caps before the task starts | `test_pictures_are_counted_against_*` |
| Text inside a picture is untrusted: the system prompt says so, and a model that "obeys" it can still only create a pending confirmation or hit the allowlists | `test_text_inside_a_picture_*` |
| Image bytes never reach logs, audit, history, alerts, responses or the CLI; history stores only "+N images" | `test_image_bytes_never_reach_logs_audit_history_or_responses` |

### 4.13 Coding sessions and the remote-desktop helper (session 2)
| Control | Test |
|---|---|
| The phone and the AI only name a project. The program, arguments and folder come from the owner's `coding_projects`; the folder must be inside `allowed_roots`; invalid entries are dropped and never run | `test_phase6_sessions.py` (config and start blocks) |
| `coding_session_start`, `coding_session_stop`, `remote_desktop_start` are high-risk: two-step confirmation over HTTP; the AI can only request; the confirmation card shows the exact command and folder; a request that cannot run is refused before any confirmation is asked | `test_start_needs_the_two_step_confirmation_over_http`, `test_confirmation_card_shows_the_exact_command_and_folder`, `test_the_ai_is_not_asked_to_confirm_what_cannot_run` |
| Sessions are started by the same ProcessManager as `run_script` (shell=False, own console), so `emergency_stop` ends them; stopping works only on sessions this agent started | `test_emergency_stop_ends_sessions_and_blocks_new_ones`, `test_stop_only_touches_sessions_this_agent_started` |
| `coding_session_list` and `remote_desktop_status` are read-only and reveal no command line, path, password or config of RustDesk | `test_list_shows_states_without_commands_or_paths`, `test_status_does_not_touch_the_runner_or_any_file` |

Residual risks: the owner decides what `argv` runs, so a bad config entry is the owner's risk (the confirmation card shows it); a started session can do whatever that program can do as the Windows user; RustDesk with a weak password is remote access for anyone inside the tailnet.

### 4.14 Local AI fallback (session 2)
| Control | Test |
|---|---|
| The endpoint must be `http://127.0.0.1:PORT` (or `localhost`/`::1`): no other host, no https, no credentials, no path, no redirects | `test_phase8_local.py` endpoint tests, `test_a_redirect_is_never_followed` |
| A local model sees only `LOCAL_TOOLS` (read-only, low risk); anything else it names is refused and creates NOT EVEN a confirmation request; no GUI, no pictures | `test_a_local_model_asking_for_anything_else_is_refused`, `test_local_provider_refuses_pictures` |
| The fallback runs only for network/timeout errors and only when switched on; answers name the model; hostile or oversized local answers fail safely | `test_only_network_errors_trigger_the_fallback`, `test_unreadable_or_oversized_answers_fail_safely` |

### 4.15 Device roles and token hygiene (session 2)
| Control | Test |
|---|---|
| A `viewer` phone can only run `status`, `system_info`, `list_processes`, `take_screenshot` and a short list of GET endpoints; everything else is 403 and audited; `Engine.run(role=...)` is a second layer | `test_phase9_roles.py` (route matrix, every action against both roles) |
| A new route fails the matrix test until someone decides whether a viewer may use it | `test_every_route_has_an_explicit_role_decision` |
| The role is fixed when the pairing code is made; the phone cannot ask for one; an unknown role in the database means viewer | `test_the_phone_cannot_ask_for_a_role`, `test_an_unknown_role_in_the_database_is_treated_as_a_viewer` |
| Tokens may expire (`token_ttl_days`); revoke works on the very next request, including from the CLI while the server runs | `test_tokens_expire_after_the_configured_days`, `test_revoke_*` |

### 4.16 Session 3 additions

- **Config is untrusted input.** `Settings.load` raises `ConfigError` for unreadable JSON, a non-object root, a value of the wrong kind (for example `allowed_roots` as a string, which would otherwise be split into one path per character), negative numbers and an out-of-range port. `main` prints the problem and exits 2; nothing is guessed. Unknown keys are ignored but reported by `doctor`. `tests/test_config_fuzz.py` also throws junk at `hosts`, `wake_targets`, `coding_projects` and `gui_agent`: every bad value is an error or leaves the capability OFF, never a wider setting.
- **MAC addresses stay local.** `doctor` prints them only with `--show-mac`, and only to the console. `wake-setup` writes them only into config.json and never prints them. `power_capabilities`, `/health`, audit, history and logs never contain them (`tests/test_e2e_session3.py` greps the audit tables and every HTTP body).
- **New read-only OS queries** (fixed, no parameters, via `wakeinfo`): `powercfg /devicequery wake_armed|wake_programmable` and one `Get-NetAdapter -Physical` listing. Neither changes anything; they are not a shell and tests replace them with fakes.
- **Power-LED light sensor** (Cortex Wake, optional, untested): the ESP32 reads an ADC and reports on/off/blink. It only informs the existing safety rule (ON wakes a blinking = asleep laptop; a plain PRESS on a blinking laptop still needs FORCE). A blinded or lit sensor can cause a wrong reading, never a press that the HMAC/counter rules would not allow.
- **Read-only prep script** `scripts/wake-test-prep.ps1` is checked by a test for any changing command.

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
16. **New channels, never run for real:** the SMS gateway phone, the BLE link to the ESP32, the GUI session, picture input, the admin failover task and the local model are covered by tests with fakes only. Treat the first real use of each as an experiment, near the computer, with work saved.
17. **SMS sender numbers can be spoofed on some networks.** For Cortex Wake the TOTP code (from a separate wake secret, accepted once, stored replay guard) is the real gate; a spoofed sender only makes the reply go to the real owner. Anyone who holds the wake secret AND is near the ESP32 or knows the key can press the button.
18. **BLE frames can be delayed:** an attacker who blocks a good frame and delivers it later gets it accepted once. Radio jamming stops the robot. The firmware key sits in flash (readable by someone with physical access and a USB cable).
19. **Pressing the power button of a running laptop** sleeps or shuts it down depending on Windows settings; the USB-power sensor can say "ON" when the laptop is off (many laptops keep USB powered). The software refuses to press an "ON" laptop without FORCE but cannot know the truth.
20. **The GUI session is the most dangerous convenience.** While it runs, anything the model is talked into doing inside an approved app happens as the Windows user. The title/process blocklists are weak (a bank page can have an innocent title), password-field detection only works for classic edit controls, and the whole mode is unverified on a real screen. Keep it off unless needed, use short sessions, sit next to the computer.
21. **A started coding session can do whatever its program can do** as the Windows user; the owner chooses the program in `config.json`, the confirmation card shows it. A weak RustDesk password is remote access for anyone inside the tailnet.
22. **Home-LAN http is unencrypted:** after the owner ticks "my own network" the phone token crosses the home Wi-Fi in clear text. Anyone on that Wi-Fi who sniffs it can use it (until it is revoked).
23. **The local model is small and untrusted:** it can only read and cannot confirm anything, but it can say wrong things; its answers are labelled with the model name.
24. **A `viewer` phone can still see the screen** (screenshots) and process names; it cannot change anything. Treat a viewer pairing code like a password and revoke phones you no longer use. Tokens do not expire unless `token_ttl_days` is set.
25. **`/health` is open to anyone who can reach the port** (computer name, battery, uptime, network state). The port is only bound on Tailscale/LAN/loopback addresses, but anyone inside the tailnet or LAN sees that much.
