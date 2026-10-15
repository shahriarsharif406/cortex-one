# Cortex One — Windows এজেন্ট ও ফোন অ্যাপ (v0.4)

FutureTech.ai-এর "One Command. Your Entire Computer." প্রজেক্ট: ল্যাপটপে চলা একটি **নিরাপদ এজেন্ট**, যাকে ফোন অ্যাপ (বা SMS) থেকে নিয়ন্ত্রিত কমান্ড পাঠানো যায়। AI অপারেটর বাংলা/ইংরেজি নির্দেশ বুঝে শুধু অনুমোদিত তালিকার কাজ করে।

## এখন যা আছে

| অংশ | অবস্থা |
|---|---|
| ডিভাইস পেয়ারিং (৬ অঙ্কের কোড → টোকেন, টোকেন শুধু হ্যাশ করে সংরক্ষিত) | তৈরি ও পরীক্ষিত (Windows-এ চালানো টেস্ট) |
| অনুমোদিত কমান্ড: status, lock, shutdown, restart, cancel_shutdown, emergency_stop, list/find/copy files, make_folder, open_app, run_script | তৈরি ও পরীক্ষিত (shutdown/lock আসল মেশিনে অপরীক্ষিত) |
| **নতুন:** `system_info` (CPU, RAM, ডিস্ক, ব্যাটারি, চার্জ, আপটাইম) | তৈরি ও পরীক্ষিত |
| **নতুন:** `list_processes` (মেমরি অনুযায়ী শীর্ষ N, শুধু নাম) | তৈরি ও পরীক্ষিত |
| **নতুন:** `take_screenshot` (PNG শুধু `screenshots_dir`-এ, শুধু ফাইলের নাম ফেরত) | তৈরি; আসল স্ক্রিন ক্যাপচার এই ল্যাপটপে চালিয়ে দেখা হয়েছে |
| **নতুন:** `open_url` (শুধু https এবং `allowed_domains`-এর হোস্ট) | তৈরি ও পরীক্ষিত (আসল ব্রাউজার খোলা অপরীক্ষিত) |
| **নতুন:** `tail_log` (শুধু `allowed_logs`-এর ছোট নাম, শেষ N লাইন, অবিশ্বস্ত ডেটা হিসেবে চিহ্নিত) | তৈরি ও পরীক্ষিত |
| **নতুন:** `agent_watch` (`watched_programs` চলছে কিনা, শুরুর সময়, মেমরি) | তৈরি ও পরীক্ষিত |
| শাটডাউন/রিস্টার্ট/স্ক্রিপ্টে দুই ধাপের কনফার্মেশন | তৈরি ও পরীক্ষিত |
| ফাইল শুধু `allowed_roots`-এর ভেতরে (symlink দিয়ে বেরোনো আটকানো) | তৈরি ও পরীক্ষিত |
| SQLite অডিট লগ (পিন/টোকেন লুকিয়ে) | তৈরি ও পরীক্ষিত |
| SMS ফলব্যাক (`SHUTDOWN 4821`): নম্বর allowlist + পিন + ভুল পিনে লকআউট | তৈরি ও পরীক্ষিত (আসল গেটওয়ে ফোনে অপরীক্ষিত) |
| AI টাস্ক অপারেটর (Anthropic Claude) | তৈরি; নকল API ও আসল SDK-র HTTP-নকল দিয়ে পরীক্ষিত, **আসল key দিয়ে এখনো নয়** |
| **নতুন:** AI-র অনুরোধ করা কনফার্মেশন ফোন থেকে দেখা/নিশ্চিত/বাতিল (`/ai/pending`, `/ai/confirm`, `/ai/cancel`) | তৈরি ও পরীক্ষিত |
| **নতুন:** ব্যাকগ্রাউন্ড AI টাস্ক + পোলিং (`wait=false`, `GET /ai/tasks/{id}`) | তৈরি ও পরীক্ষিত |
| **নতুন:** `doctor`, `init-config`, ঘূর্ণায়মান লগ, লগইনে অটো-স্টার্ট (Scheduled Task) স্ক্রিপ্ট | তৈরি; Scheduled Task আসলে ইনস্টল করে দেখা হয়নি (শুধু `-WhatIf`) |
| Flutter অ্যাপ (`mobile/`): পেয়ারিং, স্ট্যাটাস, ভয়েস/টেক্সট কমান্ড, কনফার্মেশন, জরুরি বন্ধ, লগ, SMS সাহায্য | কোড লেখা, `flutter analyze` পরিষ্কার, ৮৭টি widget/unit টেস্ট পাস; **APK বানানো ও আসল ফোনে চালানো বাকি** |
| **v0.4:** স্ক্রিন দেখা (শুধু দেখা, টাচ নেই): `GET /screenshots`, `GET /screenshots/{name}`; অ্যাপে "স্ক্রিন" ট্যাব (পিঞ্চ জুম, ঐচ্ছিক অটো-রিফ্রেশ); পুরনো স্ক্রিনশট নিজে মোছে (`screenshot_keep`, ডিফল্ট ২০) | তৈরি ও পরীক্ষিত (Pillow থাকলে ছবি ছোট করে পাঠায়, না থাকলে আসল ছবি) |
| **v0.4:** কারেন্ট-কাট/ব্যাটারি ওয়াচার (`power_watch`): AC গেলে/ফিরলে, ৩০% ও ১০%-এ সতর্কতা → অডিট + `GET /alerts` + অ্যাপের হোম ব্যানার | তৈরি ও নকল ব্যাটারি দিয়ে পরীক্ষিত (আসল কারেন্ট-কাটে অপরীক্ষিত) |
| **v0.4:** ঐচ্ছিক পুশ (ntfy টপিক বা https webhook), ডিফল্টে বন্ধ; শুধু ঘটনা + ব্যাটারি % + সময় পাঠায় | তৈরি ও পরীক্ষিত (আসল ntfy/webhook অপরীক্ষিত) |
| **v0.4:** `hibernate` (high-risk, দুই ধাপ কনফার্মেশন) এবং ঐচ্ছিক `critical_action` (`none`/`hibernate`/`lock`, **কখনো shutdown নয়**): ব্যাটারি ক্রিটিক্যালে, চার্জে না থাকলে, ওয়াচার নিজে একবার চালায় | তৈরি ও পরীক্ষিত; HTTP/AI/SMS থেকে এই ছাড় ব্যবহার করা যায় না (টেস্টে প্রমাণিত); আসল hibernate অপরীক্ষিত |
| **v0.4:** SMS-এ TOTP মোড (`sms-setup --totp`): ৬ অঙ্কের এককালীন কোড, একই কোড দুবার চলে না (replay সুরক্ষা), সিক্রেট Windows DPAPI দিয়ে | তৈরি ও পরীক্ষিত (DPAPI আসল Windows-এ পরীক্ষিত; আসল SMS অপরীক্ষিত) |
| **v0.4:** `doctor` আরও পরীক্ষা (স্টার্টআপ টাস্ক, ব্যাটারি, নোটিফায়ার, TOTP, Tailscale host), `export-audit --days 7` (ছাঁকা CSV), ঐচ্ছিক `scripts\build-exe.ps1` (PyInstaller) | তৈরি ও পরীক্ষিত (PyInstaller বিল্ড চালানো হয়নি) |

## AI অপারেটর কীভাবে নিরাপদ

- AI সরাসরি কম্পিউটারে কিছু করে না। সে শুধু `REGISTRY`-র টুল ডাকতে পারে; প্রতিটি কল একই যাচাই ও অডিট লগের ভেতর দিয়ে যায়।
- **shutdown, restart, run_script AI নিজে চালাতে পারে না।** সে শুধু অনুরোধ করে; আপনার ফোনে কনফার্মেশন কার্ড আসে (একবারের টোকেন, ডিভাইস+অ্যাকশন+প্যারামিটারে বাঁধা, মেয়াদী)।
- `emergency_stop` AI-র টুল তালিকায় নেই। এটি চাপলে চলমান AI টাস্কও থামে।
- প্রতিটি টুল-ফলাফল `<tool_output untrusted="true">` বেড়ার ভেতরে যায়, আকারে সীমিত, আর ভেতরের লেখায় বেড়া বন্ধ করার ট্যাগ অকেজো করা হয়। লগের লেখা, ফাইলের নাম, প্রসেসের নামে লুকানো নির্দেশ থাকলেও AI-র হাতে বেশি ক্ষমতা নেই।
- AI-কে বলা হয় কোন ফোল্ডার/অ্যাপ/ওয়েবসাইট/লগ অনুমোদিত (শুধু নাম; কোনো গোপন তথ্য নয়), যাতে সে পথ আন্দাজ না করে। তালিকার বাইরে গেলেও কোড আটকে দেয়।
- খরচের সীমা: প্রতি টাস্কে সর্বোচ্চ ৮ ধাপ, প্রতিদিন ২,০০,০০০ টোকেন, প্রতি মিনিটে ৬টি AI অনুরোধ, একসাথে একটি টাস্ক।
- API key শুধু `ANTHROPIC_API_KEY` এনভায়রনমেন্ট ভ্যারিয়েবলে থাকে। কোনো ফাইল, লগ বা অডিটে লেখা হয় না।

## চালানোর নিয়ম (Windows 10, PowerShell)

```powershell
cd D:\cortex-one
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m pytest -q                 # সব পাস হওয়া উচিত
.venv\Scripts\python -m agent.main init-config    # config.json না থাকলে ডিফল্ট বানায়
.venv\Scripts\python -m agent.main doctor         # সেটআপ পরীক্ষা (বাংলা/English)
.venv\Scripts\python -m agent.main pair           # ৬ অঙ্কের কোড
.venv\Scripts\python -m agent.main serve          # এজেন্ট চালু (লগ: %APPDATA%\CortexOne\logs\agent.log)
```

অন্যান্য কমান্ড: `devices`, `revoke <id>`, `audit --limit 30`, `export-audit --days 7`, `ask "..."`, `ai-usage`, `sms-setup <নম্বর>` (স্থির পিন) বা `sms-setup --totp <নম্বর>` (এককালীন কোড; সিক্রেট একবারই দেখায়)।

লগইনে নিজে চালু হতে: `scripts\install-startup.ps1` (আগে `-WhatIf` দিয়ে দেখুন), বন্ধ করতে `scripts\uninstall-startup.ps1`। অ্যাডমিন লাগে না।

## কনফিগ (`%APPDATA%\CortexOne\config.json`)

```json
{
  "host": "100.x.y.z",
  "port": 8765,
  "allowed_roots": ["C:\\Users\\<you>\\Downloads", "C:\\Users\\<you>\\Documents"],
  "allowed_apps": {"notepad": ["notepad.exe"], "chrome": ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"]},
  "approved_scripts": {"backup": ["powershell", "-File", "C:\\cortex\\scripts\\backup.ps1"]},
  "allowed_domains": ["github.com", "docs.python.org"],
  "allowed_logs": {"coder": "C:\\Users\\<you>\\AppData\\Local\\MyCodingAgent\\agent.log"},
  "watched_programs": ["claude", "node", "python"],
  "screenshots_dir": "C:\\Users\\<you>\\Documents\\CortexOne-Screenshots",
  "screenshot_keep": 20,
  "power_watch": true,
  "power_warn_percent": 30,
  "power_critical_percent": 10,
  "power_check_seconds": 30,
  "critical_action": "none",
  "notifier_type": "",
  "notifier_target": "",
  "sms_mode": "pin"
}
```

- `host` হবে ল্যাপটপের **Tailscale IP**। `0.0.0.0` দেবেন না (`doctor` এটাকে FAIL ধরে)।
- `screenshots_dir` অবশ্যই `allowed_roots`-এর ভেতরে হতে হবে, নইলে স্ক্রিনশট বন্ধ।
- `screenshot_keep`: সর্বশেষ কতটি স্ক্রিনশট রাখবে (১–১৯৯, ডিফল্ট ২০); পুরনোগুলো নিজে মোছে। শুধু এজেন্টের নিজের নামের (`screenshot-YYYYMMDD-HHMMSS.png`) ফাইল মোছে, আপনার অন্য ফাইল ছোঁয় না।
- `power_watch`: ডিফল্ট চালু। শুধু psutil-এর ব্যাটারি তথ্য; ডেস্কটপে (ব্যাটারি নেই) কিছুই করে না। `power_warn_percent` ৩০, `power_critical_percent` ১০, `power_check_seconds` ৩০ (৫–৩৬০০)।
- `critical_action`: `"none"` (ডিফল্ট), `"hibernate"` বা `"lock"`। ব্যাটারি ক্রিটিক্যাল **এবং** চার্জে নেই, তখনই ওয়াচার একবার চালায়। `"shutdown"` বা অন্য কিছু দিলে কিছুই হয় না (`doctor` সতর্ক করে)। আগে `"none"` রেখে সতর্কতা ঠিকমতো আসছে দেখুন।
- `notifier_type` = `"ntfy"` (`notifier_target` = আপনার টপিক, ৬–৬৪ অক্ষর) বা `"webhook"` (`notifier_target` = https URL)। টপিক/URL পাসওয়ার্ডের মতো গোপন; বরং এনভায়রনমেন্ট ভ্যারিয়েবল `CORTEX_NOTIFY_TARGET` ব্যবহার করুন (কনফিগের চেয়ে অগ্রাধিকার পায়)। ডিফল্টে বন্ধ। বার্তা শুধু: ঘটনা, ব্যাটারি %, সময়। পাঠানো ব্যর্থ হলে এজেন্টে কিছু হয় না।
- `sms_mode`: `"pin"` (ডিফল্ট; **replay সুরক্ষা নেই**) বা `"totp"` (`sms-setup --totp` নিজে বসায়)। TOTP-তে ল্যাপটপ ও ফোনের ঘড়ি মিলিয়ে রাখুন (±৩০ সেকেন্ড সহ্য করে)।
- `allowed_domains`: শুধু যাদের বিশ্বাস করেন তাদের দিন। হুবহু হোস্ট মিলতে হবে (সাবডোমেইন আপনাআপনি ধরা হয় না), শুধু https। পথ ও কোয়েরি AI ঠিক করে, তাই আপনার নিজের সাইট বা অচেনা সার্চ ইঞ্জিন দেবেন না।
- `allowed_logs`: ছোট নাম → ফাইলের পথ। ফোন/AI শুধু নাম দিতে পারে, পথ নয়। লগ ফাইলের টোকেন-সদৃশ লেখা আউটপুটে মুছে দেওয়া হয়।
- যা তালিকায় নেই, এজেন্ট তা করবে না। "যেকোনো কমান্ড চালাও" ধরনের কোনো অ্যাকশন নেই।

## API সংক্ষেপে

সব ফোন-রিকোয়েস্টে `Authorization: Bearer <token>` লাগে (শুধু `/health`, `/pair`, `/sms/inbound` ছাড়া)। CORS বন্ধ: API শুধু নেটিভ অ্যাপের জন্য।

| Method | Path | কাজ |
|---|---|---|
| GET | `/health` | জীবিত কিনা + `version` (টোকেন লাগে না) |
| POST | `/pair` | `{"code":"123456","device_name":"phone"}` → টোকেন |
| GET | `/actions` | অনুমোদিত অ্যাকশনের তালিকা (`params`, `optional`) |
| POST | `/actions/{name}` | `{"params":{...},"confirm_token":"..."}` (high-risk হলে দুই ধাপ) |
| GET | `/capabilities` | অনুমোদিত ফোল্ডার/অ্যাপের নাম (গোপন কিছু নয়) |
| POST | `/ai/tasks` | `{"instruction":"...","wait":true}`; `wait:false` হলে সাথে সাথে `202 {"id"}` |
| GET | `/ai/tasks/{id}` | `running/ok/stopped/error`, ধাপ, উত্তর, অপেক্ষমাণ কনফার্মেশন |
| GET | `/ai/pending` | AI-র অনুরোধ করা অপেক্ষমাণ কাজ (বিবরণ, হুবহু কমান্ড, বাকি সময়) |
| POST | `/ai/confirm` | `{"confirm_token":"..."}` → সেই কাজ চালায় (একবারই) |
| POST | `/ai/cancel` | `{"confirm_token":"..."}` → অনুরোধ বাতিল |
| GET | `/ai/usage` | আজকের টোকেন ব্যবহার ও সীমা |
| POST | `/emergency-stop` | চলমান টাস্ক বন্ধ + শাটডাউন বাতিল |
| GET | `/audit` | সাম্প্রতিক কাজের লগ |
| GET | `/alerts?limit=20` | কারেন্ট/ব্যাটারি সতর্কতা (ওয়াচার থেকে) |
| GET | `/screenshots` | এজেন্টের নিজের স্ক্রিনশটের তালিকা (নতুন আগে) |
| GET | `/screenshots/{name}?width=1000&quality=60` | ছবি (নাম কঠোর ছাঁচে মিলতে হবে; Pillow থাকলে ছোট JPEG, না থাকলে আসল) |
| POST | `/sms/inbound` | SMS গেটওয়ে ফোন থেকে (`X-Gateway-Secret` হেডার) |

## SMS ফলব্যাকের সীমাবদ্ধতা

SMS গেটওয়ে ফোনকে ল্যাপটপে `POST /sms/inbound` করতে হয়, তাই দুটোকে **রাউটার ছাড়াই** যুক্ত থাকতে হবে। কারেন্ট গেলে রাউটার বন্ধ হয়, তাই গেটওয়ে ফোনের হটস্পট বা USB টেদারিং দিয়ে ল্যাপটপ যুক্ত রাখুন। **স্থির পিন মোডে (ডিফল্ট) পুরনো মেসেজ আবার পাঠানো (replay) ঠেকানো যায় না**; কেউ একটি SMS ধরতে পারলে বারবার পাঠাতে পারবে। তাই `sms-setup --totp` পছন্দ করুন: কমান্ড `SHUTDOWN 482913` (অথেনটিকেটর অ্যাপের ৬ অঙ্ক), প্রতিটি কোড ৩০ সেকেন্ডের ধাপে একবারই চলে, শেষ ব্যবহৃত ধাপ ডেটাবেসে থাকে বলে এজেন্ট রিস্টার্ট করলেও replay আটকায়। সিক্রেট Windows-এ DPAPI দিয়ে এনক্রিপ্ট করা (অন্য PC/ইউজারে কাজ করে না, কিন্তু আপনার ইউজারে চলা যেকোনো প্রোগ্রাম পড়তে পারে); অন্য সিস্টেমে ফাইল পারমিশন 600। SMS দেরিতে এলে (৯০ সেকেন্ডের বেশি) কোড মেয়াদ পেরোয়; নতুন কোড দিয়ে আবার পাঠান। এই অংশ বাস্তবে পরীক্ষা না করা পর্যন্ত নির্ভর করবেন না।

## এখনো নেই

- টাচ/মাউস কন্ট্রোল: স্ক্রিন শুধু দেখা যায়। রিমোট কন্ট্রোল দরকার হলে RustDesk বা Chrome Remote Desktop আলাদাভাবে ব্যবহার করুন।
- ভলিউম/মিডিয়া কী, ব্রাউজার/Office অটোমেশন: ইচ্ছাকৃতভাবে বাদ।
- iOS অ্যাপ।
