# Cortex One — Windows এজেন্ট ও ফোন অ্যাপ (v0.3)

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
| **নতুন:** Flutter অ্যাপ (`mobile/`): পেয়ারিং, স্ট্যাটাস, ভয়েস/টেক্সট কমান্ড, কনফার্মেশন, জরুরি বন্ধ, লগ, SMS সাহায্য | কোড লেখা, `flutter analyze` পরিষ্কার, ৬৩টি widget/unit টেস্ট পাস; **APK বানানো ও আসল ফোনে চালানো বাকি** |

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

অন্যান্য কমান্ড: `devices`, `revoke <id>`, `audit --limit 30`, `ask "..."`, `ai-usage`, `sms-setup <নম্বর>`।

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
  "screenshots_dir": "C:\\Users\\<you>\\Documents\\CortexOne-Screenshots"
}
```

- `host` হবে ল্যাপটপের **Tailscale IP**। `0.0.0.0` দেবেন না (`doctor` এটাকে FAIL ধরে)।
- `screenshots_dir` অবশ্যই `allowed_roots`-এর ভেতরে হতে হবে, নইলে স্ক্রিনশট বন্ধ।
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
| POST | `/sms/inbound` | SMS গেটওয়ে ফোন থেকে (`X-Gateway-Secret` হেডার) |

## SMS ফলব্যাকের সীমাবদ্ধতা

SMS গেটওয়ে ফোনকে ল্যাপটপে `POST /sms/inbound` করতে হয়, তাই দুটোকে **রাউটার ছাড়াই** যুক্ত থাকতে হবে। কারেন্ট গেলে রাউটার বন্ধ হয়, তাই গেটওয়ে ফোনের হটস্পট বা USB টেদারিং দিয়ে ল্যাপটপ যুক্ত রাখুন। SMS-এ পুরনো মেসেজ আবার পাঠানো (replay) ঠেকানো যায় না; পিন গোপন রাখুন। এই অংশ বাস্তবে পরীক্ষা না করা পর্যন্ত নির্ভর করবেন না।

## এখনো নেই

- স্ক্রিন দেখা/টাচ কন্ট্রোল: RustDesk বা Chrome Remote Desktop ব্যবহার করুন।
- ভলিউম/মিডিয়া কী, ব্রাউজার/Office অটোমেশন: ইচ্ছাকৃতভাবে বাদ।
- iOS অ্যাপ।
