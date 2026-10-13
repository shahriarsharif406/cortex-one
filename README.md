# Cortex One — Windows Agent (v0.2, Phase 2 + Phase 3 AI operator)

FutureTech.ai-এর "One Command. Your Entire Computer." প্রজেক্টের প্রথম কার্যকর অংশ: ল্যাপটপে চলা একটি **নিরাপদ এজেন্ট**, যাকে ফোন (বা SMS) থেকে নিয়ন্ত্রিত কমান্ড পাঠানো যায়।

## এখন যা আছে

| অংশ | অবস্থা |
|---|---|
| ডিভাইস পেয়ারিং (৬ অঙ্কের কোড → টোকেন, টোকেন শুধু হ্যাশ করে সংরক্ষিত) | তৈরি ও পরীক্ষিত |
| অনুমোদিত কমান্ড তালিকা: status, lock, shutdown, restart, cancel_shutdown, emergency_stop, list/find/copy files, make_folder, open_app, run_script | তৈরি ও পরীক্ষিত |
| শাটডাউন/রিস্টার্ট/স্ক্রিপ্টে দুই ধাপের কনফার্মেশন | তৈরি ও পরীক্ষিত |
| ফাইল শুধু `allowed_roots`-এর ভেতরে (symlink দিয়ে বেরোনো আটকানো) | তৈরি ও পরীক্ষিত |
| SQLite অডিট লগ (পিন/টোকেন লুকিয়ে) | তৈরি ও পরীক্ষিত |
| SMS ফলব্যাক (`SHUTDOWN 4821`): নম্বর allowlist + পিন + ভুল পিনে লকআউট | তৈরি ও পরীক্ষিত |
| রেট লিমিট, জরুরি বন্ধ (`/emergency-stop`) | তৈরি ও পরীক্ষিত |
| **AI টাস্ক অপারেটর (Anthropic Claude)**: বাংলা/ইংরেজি নির্দেশ → ধাপে ধাপে অনুমোদিত অ্যাকশন চালানো → যাচাই → ছোট রিপোর্ট | তৈরি; **নকল API ও আসল SDK-র HTTP-নকল দিয়ে পরীক্ষিত, আসল key দিয়ে এখনো নয়** |

## AI অপারেটর কীভাবে নিরাপদ

- AI সরাসরি কম্পিউটারে কিছু করে না। সে শুধু ওই অনুমোদিত তালিকার টুল ডাকতে পারে (`/ai/tasks`), প্রতিটি কল একই যাচাই ও অডিট লগের ভেতর দিয়ে যায়।
- **shutdown, restart, run_script AI নিজে চালাতে পারে না।** সে শুধু অনুরোধ করে, আর আপনার ফোনে কনফার্মেশন (একবারের টোকেন) আসে।
- `emergency_stop` শুধু আপনার হাতে, AI-র টুলের তালিকায় নেই। এটি চাপলে চলমান AI টাস্কও থেমে যায়।
- ফাইলের নাম বা স্ক্রিপ্টের আউটপুটে লুকানো নির্দেশ থাকলেও (prompt injection) AI-র হাতে বেশি ক্ষমতা নেই, তাই ক্ষতির সীমা একই।
- খরচের সীমা: প্রতি টাস্কে সর্বোচ্চ ৮ ধাপ, প্রতিদিন ২,০০,০০০ টোকেন, প্রতি মিনিটে ৬টি AI অনুরোধ, একসাথে একটি টাস্ক। সবই `config.json`-এ বদলানো যায়।
- API key শুধু `ANTHROPIC_API_KEY` এনভায়রনমেন্ট ভ্যারিয়েবলে থাকে। কোনো ফাইল বা লগে লেখা হয় না।
- AI-কে শুধু আপনার নির্দেশ ও টুলের ফলাফল (ফাইলের নাম, স্ট্যাটাস) পাঠানো হয়। ফাইলের ভেতরের লেখা পড়ার কোনো টুল নেই।

ব্যবহার: `set ANTHROPIC_API_KEY=...` (PowerShell-এ `$env:ANTHROPIC_API_KEY="..."`), তারপর `python -m agent.main ask "Downloads-এর PDF ফাইলগুলো দেখাও"`, অথবা সার্ভার চালিয়ে ফোন থেকে `POST /ai/tasks`। আজকের ব্যবহার দেখতে `python -m agent.main ai-usage`। মডেল বদলাতে `config.json`-এ `ai_model`।

## এখনো নেই (পরের ধাপ)

- Flutter মোবাইল অ্যাপ (Phase 6)
- বাংলা ভয়েস কমান্ড: ফোনের নিজস্ব স্পিচ-টু-টেক্সট থেকে লেখা এজেন্টে পাঠানো যাবে, এজেন্টে নিজস্ব STT এখনো নেই
- স্ক্রিন দেখা/টাচ কন্ট্রোল: RustDesk বা Chrome Remote Desktop ব্যবহার করুন (Phase 1)
- ব্রাউজার/Office অটোমেশন (Phase 4)

**গুরুত্বপূর্ণ:** টেস্টগুলো Linux-এ নকল (fake) কমান্ড রানার দিয়ে চালানো হয়েছে। `shutdown`, `lock` ইত্যাদির আসল Windows আচরণ আপনার ল্যাপটপে একবার পরীক্ষা করা বাকি (`NEEDS_ME.md` দেখুন)।

## চালানোর নিয়ম (Windows, PowerShell)

```powershell
cd cortex-one
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m pytest            # সব টেস্ট পাস করা উচিত
.venv\Scripts\python -m agent.main pair   # ৬ অঙ্কের কোড দেখাবে
.venv\Scripts\python -m agent.main serve  # এজেন্ট চালু
```

অন্যান্য কমান্ড: `devices`, `revoke <id>`, `audit --limit 30`, `sms-setup <আপনার নম্বর>`।

## কনফিগ (`%APPDATA%\CortexOne\config.json`)

```json
{
  "host": "100.x.y.z",
  "port": 8765,
  "allowed_roots": ["C:\\Users\\<you>\\Downloads", "C:\\Users\\<you>\\Documents"],
  "allowed_apps": {"notepad": ["notepad.exe"], "chrome": ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"]},
  "approved_scripts": {"backup": ["powershell", "-File", "C:\\cortex\\scripts\\backup.ps1"]}
}
```

- `host` হবে ল্যাপটপের **Tailscale IP**। `0.0.0.0` দেবেন না।
- যা তালিকায় নেই, এজেন্ট তা করবে না। কোনো "যেকোনো কমান্ড চালাও" অ্যাকশন নেই।

## API সংক্ষেপে

| Method | Path | কাজ |
|---|---|---|
| GET | `/health` | জীবিত কিনা (টোকেন লাগে না) |
| POST | `/pair` | `{"code":"123456","device_name":"phone"}` → টোকেন |
| GET | `/actions` | অনুমোদিত অ্যাকশনের তালিকা |
| POST | `/actions/{name}` | `{"params":{...},"confirm_token":"..."}` |
| POST | `/ai/tasks` | `{"instruction":"..."}` → AI অপারেটর চালায় (সর্বোচ্চ ২০০০ অক্ষর) |
| GET | `/ai/usage` | আজকের টোকেন ব্যবহার ও সীমা |
| POST | `/emergency-stop` | চলমান টাস্ক বন্ধ + শাটডাউন বাতিল |
| GET | `/audit` | সাম্প্রতিক কাজের লগ |
| POST | `/sms/inbound` | SMS গেটওয়ে ফোন থেকে (`X-Gateway-Secret` হেডার) |

সব ফোন-রিকোয়েস্টে `Authorization: Bearer <token>` লাগে।

## SMS ফলব্যাকের সীমাবদ্ধতা

SMS গেটওয়ে ফোনকে ল্যাপটপে `POST /sms/inbound` করতে হয়, তাই দুটোকে **রাউটার ছাড়াই** যুক্ত থাকতে হবে। কারেন্ট গেলে রাউটার বন্ধ হয়, তাই গেটওয়ে ফোনের হটস্পট বা USB টেদারিং দিয়ে ল্যাপটপ যুক্ত রাখুন। এই অংশ বাস্তবে পরীক্ষা না করা পর্যন্ত নির্ভর করবেন না।
