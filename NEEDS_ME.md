# NEEDS_ME — শুধু আপনি যা করতে পারবেন (ক্রমানুসারে)

সব কমান্ড **PowerShell**-এর জন্য। আগে `cd D:\cortex-one`। আমি (Claude) এই সেশনে কোনো API key, টোকেন, `.env`, আসল shutdown/lock/hibernate ছুঁইনি। যা যাচাই হয়নি তা প্রতিটি ধাপে ও শেষে স্পষ্ট লেখা আছে।

শুরুর আগে (২ মিনিট): সব ঠিক আছে কিনা এক কমান্ডে দেখুন।

```powershell
cd D:\cortex-one
.\scripts\install-git-hooks.ps1 -WhatIf      # (ঐচ্ছিক) commit-এর আগে গোপন তথ্য আটকানোর হুক
.\scripts\check.ps1                            # টেস্ট + গোপন-তথ্য স্ক্যান + doctor; শেষে ALL CHECKS PASSED চাই
```

`WARN` লাইন স্বাভাবিক (key, SMS, অটো-স্টার্ট এখনো সেট নেই)। `FAIL` থাকলে আগে ঠিক করুন।

---

## (ক) Anthropic API: ক্রেডিট, খরচের সীমা, key, প্রথম `ask`

1. https://console.anthropic.com → Billing: ক্রেডিট দিন (Claude.ai সাবস্ক্রিপশন আর API আলাদা)।
2. **ওই key-র জন্য spending limit বসান** (যেমন মাসে ৫ ডলার)। Settings → API keys → নতুন key।
3. key চ্যাটে/ফাইলে লিখবেন না। শুধু এই উইন্ডোর জন্য, লুকিয়ে টাইপ করে:

```powershell
$k = Read-Host "Anthropic key" -AsSecureString
$env:ANTHROPIC_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($k))
Remove-Variable k
.\.venv\Scripts\python -m agent.main ask --dry-run "ল্যাপটপের অবস্থা বলো"     # কিছু পাঠায় না; কী যাবে দেখায়
.\.venv\Scripts\python -m agent.main ask "আমার ল্যাপটপের অবস্থা বলো"          # প্রথম আসল কল
.\.venv\Scripts\python -m agent.main ask "Downloads-এর PDF ফাইলগুলো দেখাও"
.\.venv\Scripts\python -m agent.main ask "ল্যাপটপ বন্ধ করো"                  # চলবে না! শুধু কনফার্মেশন চাইবে
.\.venv\Scripts\python -m agent.main ai-usage
.\.venv\Scripts\python -m agent.main ai-history
```

4. খরচের আন্দাজ দেখতে Anthropic-এর **বর্তমান দাম** (কনসোল/প্রাইসিং পেজ থেকে, মিলিয়ন টোকেন প্রতি ডলার) নিজে `config.json`-এ বসান: `"ai_price_per_mtok_input": <দাম>`, `"ai_price_per_mtok_output": <দাম>`। না বসালে `ai-usage` লেখে "set prices in config"।
5. স্থায়ী করতে চাইলে (রেজিস্ট্রিতে সাদা লেখায় থাকে — সচেতন ঝুঁকি; না করলে অটো-স্টার্ট এজেন্টে AI বন্ধ থাকবে, বাকি সব চলবে):
   `[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $env:ANTHROPIC_API_KEY, "User")`

**অপরীক্ষিত:** আসল API কল। মডেলের নাম (`ai_model`), ক্রেডিট-শেষ ও অন্য ত্রুটির আসল বার্তা আমি শুধু নকল ও SDK-নকল HTTP দিয়ে দেখেছি। বাংলা নির্দেশ মডেল ঠিক বুঝবে কিনা (১৭টি টেস্ট শুধু তার-জোড়া প্রমাণ করে, মডেলের মান নয়) — নিজে কয়েকটি বাক্য চালিয়ে দেখুন।

## (খ) আসল Windows পরীক্ষা: lock, তারপর shutdown + ৩০ সেকেন্ডে cancel

**আগে সব কাজ সেভ করুন।**

উইন্ডো ১: `.\.venv\Scripts\python -m agent.main pair` (৬ অঙ্ক দেখাবে), তারপর `.\.venv\Scripts\python -m agent.main serve`
উইন্ডো ২:

```powershell
$u = "http://127.0.0.1:8765"
$r = Invoke-RestMethod -Method Post "$u/pair" -ContentType application/json -Body '{"code":"<৬ অঙ্ক>","device_name":"test-pc"}'
$h = @{ Authorization = "Bearer $($r.token)" }
function Act($n,$b='{"params":{}}'){ Invoke-RestMethod -Method Post "$u/actions/$n" -Headers $h -ContentType application/json -Body $b }

Act system_info
Act take_screenshot                   # তারপর: Invoke-RestMethod "$u/screenshots" -Headers $h
Act lock                              # স্ক্রিন লক হলে ঠিক আছে (আনলক করে ফিরে আসুন)

$c = Act shutdown                     # ধাপ ১: শুধু confirm_token দেয়, কিছু বন্ধ হয় না
$body = (@{ params = @{}; confirm_token = $c.confirm_token } | ConvertTo-Json)
Act shutdown $body                    # ধাপ ২ (৬০ সেকেন্ডের মধ্যে): ৩০ সেকেন্ডের কাউন্টডাউন শুরু
Act cancel_shutdown                   # ৩০ সেকেন্ডের ভেতরে! "Shutdown cancelled." আসা উচিত
```

`cancel_shutdown` কাজ না করলে সাথে সাথে `shutdown /a`। **hibernate** আলাদা পরীক্ষা: আগে `powercfg /a` (Hibernate চালু?); না থাকলে অ্যাডমিন PowerShell-এ `powercfg /hibernate on`; তারপর `Act hibernate` (দুই ধাপ)।

**অপরীক্ষিত:** আসল shutdown/restart/hibernate/lock — টেস্টে শুধু FakeRunner।

## (গ) লগইনে অটো-স্টার্ট

```powershell
.\scripts\install-startup.ps1 -WhatIf          # কী করবে দেখায়, কিছু বদলায় না
.\scripts\install-startup.ps1
Start-ScheduledTask -TaskName CortexOneAgent
Get-Content $env:APPDATA\CortexOne\logs\agent.log -Tail 20
.\.venv\Scripts\python -m agent.main doctor    # "অটো-স্টার্ট টাস্ক আছে" দেখা উচিত
# বন্ধ/মুছতে:  .\scripts\uninstall-startup.ps1
```

শুধু `-WhatIf` পর্যন্ত আমি পরীক্ষা করেছি; আসল ইনস্টল ও রিবুটের পর চালু হওয়া **অপরীক্ষিত**।

## (ঘ) Tailscale — ল্যাপটপ, ফোন ও `host`

1. https://tailscale.com/download থেকে ল্যাপটপ ও ফোনে ইনস্টল, **একই অ্যাকাউন্টে** লগইন।
2. ল্যাপটপে `tailscale ip -4` (যেমন `100.x.y.z`)।
3. `notepad $env:APPDATA\CortexOne\config.json` → `"host": "100.x.y.z"` (**`0.0.0.0` নয়**)।
4. এজেন্ট আবার চালু করে `.\.venv\Scripts\python -m agent.main doctor` ("host একটি Tailscale IP" দেখা উচিত)।
5. ফোন না পৌঁছালে অ্যাডমিন PowerShell-এ (শুধু Tailscale রেঞ্জ):
   `New-NetFirewallRule -DisplayName "Cortex One (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 8765 -RemoteAddress 100.64.0.0/10 -Action Allow`
6. ফোন থেকে যাচাই: `Test-NetConnection 100.x.y.z -Port 8765` (ল্যাপটপ থেকে), অ্যাপে ঠিকানা `http://100.x.y.z:8765`।

অ্যাপ সাধারণ `http` শুধু Tailscale (100.64–127.x বা `*.ts.net`) ও লোকালহোস্টে নেয়; ঘরের Wi-Fi-র `192.168.x` ইচ্ছাকৃতভাবে নেয় না।

## (ঙ) Android SDK + `flutter build apk` (কম-মেমরি সেটিং), সাইনিং কী, ইনস্টল, পেয়ারিং

Flutter ৩.৩৫.৫ ইনস্টল আছে (`D:\flutter`), `flutter analyze` পরিষ্কার, ৯০টি টেস্ট পাস। **APK বানানো হয়নি।** `mobile\android\gradle.properties`-এ হিপ ১৫৩৬ MB, `daemon=false`, `workers.max=1` আগে থেকেই আছে। **বিল্ড ধীর (১০–২০ মিনিট)। ব্রাউজার/IDE বন্ধ রাখুন।**

**সাইনিং কী (একবার):**

```powershell
mkdir D:\keys
keytool -genkey -v -keystore D:\keys\cortexone-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias cortexone
copy D:\cortex-one\mobile\android\key.properties.example D:\cortex-one\mobile\android\key.properties
notepad D:\cortex-one\mobile\android\key.properties     # পাসওয়ার্ড বসান; storeFile=D:/keys/cortexone-release.jks
```

`key.properties` ও `.jks` গিটে যায় না (gitignore + pre-commit হুক)। `.jks` ও পাসওয়ার্ডের ব্যাকআপ রাখুন; হারালে আপডেট দেওয়া যাবে না।

**বিল্ড:**

```powershell
flutter doctor --android-licenses       # শর্ত নিজে পড়ে প্রতিটিতে y (Android SDK আগে ইনস্টল থাকতে হবে)
cd D:\cortex-one\mobile
flutter clean
flutter pub get
flutter build apk --release --target-platform android-arm64     # কম মেমরির জন্য শুধু arm64
# ফাইল: build\app\outputs\flutter-apk\app-release.apk
```

মেমরি ত্রুটি হলে `docs\TROUBLESHOOTING.md`-এর ১২ নম্বর। **ফোনে ইনস্টল:** USB debugging চালু করে `adb install -r build\app\outputs\flutter-apk\app-release.apk` (বা APK ফোনে কপি করে খুলুন)।
**পেয়ারিং:** ল্যাপটপে `.\.venv\Scripts\python -m agent.main pair` → অ্যাপে ঠিকানা `http://100.x.y.z:8765` ও ৬ অঙ্কের কোড।

**অপরীক্ষিত:** APK বিল্ড, আসল ফোনে UI, ভয়েস (বাংলা চলতে ফোনে Google Bengali ভয়েস ডাউনলোড থাকা ভালো), স্ক্রিন ও ওয়াচ ট্যাব, Keystore সাইনিং, release-এ key ছাড়া ইচ্ছাকৃত ব্যর্থতার Gradle শর্ত।

## (চ) SMS ফলব্যাক: TOTP + গেটওয়ে ফোন + কারেন্ট গেলে হটস্পট/USB টিথারিং

```powershell
.\.venv\Scripts\python -m agent.main sms-setup --totp +8801XXXXXXXXX
```

- **একবারই** দুটি জিনিস দেখায়: gateway secret ও TOTP secret (base32)। ফাইলে/চ্যাটে রাখবেন না। TOTP secret একটি অথেনটিকেটর অ্যাপে (Google Authenticator, Aegis…) "time-based, ৬ অঙ্ক, ৩০ সেকেন্ড" দিয়ে যোগ করুন।
- SMS ফরম্যাট: `STATUS 482913` (কোড একবারই চলে)। ল্যাপটপের ঘড়ি ঠিক রাখুন: `w32tm /resync`।
- গেটওয়ে: পুরনো অ্যান্ড্রয়েডে সিম + HTTP POST পাঠানো SMS-ফরওয়ার্ডার অ্যাপ। URL `http://100.x.y.z:8765/sms/inbound`, হেডার `X-Gateway-Secret: <secret>`, বডি `{"from":"<sender>","text":"<message>"}`। গেটওয়ে ফোনেও Tailscale চালু রাখুন।
- **কারেন্ট গেলে:** রাউটার বন্ধ হবে। ল্যাপটপকে ফোনের **হটস্পটে** (Windows: Settings → Network → Wi-Fi) বা **USB টিথারিং-এ** (ফোনে Settings → Hotspot & tethering → USB tethering, তারপর তার লাগান) যুক্ত করুন; Tailscale আবার সংযুক্ত হলে অ্যাপ ও SMS কাজ করবে। আগে একবার অভ্যাস করে নিন।
- পরীক্ষার ক্রম: `STATUS` → অন্যগুলো → `SHUTDOWN` সবার শেষে। ভুল কোডে ৩ বারের পর ১৫ মিনিট লকআউট।

**অপরীক্ষিত:** আসল SMS পথ ও গেটওয়ে অ্যাপ, হটস্পটে Tailscale। (TOTP ও DPAPI আসল Windows-এ টেস্টে চলেছে।)

## (ছ) নোটিফায়ার (ntfy/webhook) ও `watch_rules` সেটআপ

**পুশ নোটিফায়ার (ঐচ্ছিক):**

```powershell
$topic = "cortex-" + [guid]::NewGuid().ToString("N").Substring(0,16)      # লম্বা, এলোমেলো; পাসওয়ার্ডের মতো গোপন
[Environment]::SetEnvironmentVariable("CORTEX_NOTIFY_TARGET",$topic,"User")
notepad $env:APPDATA\CortexOne\config.json                                  # "notifier_type": "ntfy"
```

ফোনে ntfy অ্যাপে ওই টপিক সাবস্ক্রাইব করুন (ntfy.sh তৃতীয় পক্ষ — তারা দেখবে কখন সতর্কতা গেল; বার্তায় শুধু ঘটনার নাম, সময়, ব্যাটারি %)। webhook হলে `"notifier_type": "webhook"` ও https URL একইভাবে `CORTEX_NOTIFY_TARGET`-এ।

**কোডিং এজেন্ট ওয়াচ (`watch_rules`)** — `config.json`-এ উদাহরণ (আগে `watched_programs`-এ `"claude"` আর `allowed_logs`-এ `"coder"` থাকতে হবে; `target` হলো এই তালিকার **নাম**, পথ নয়):

```json
"watched_programs": ["claude", "node"],
"allowed_logs": {"coder": "C:\\Users\\<আপনি>\\AppData\\Local\\MyCodingAgent\\agent.log"},
"watch_rules": [
  {"name": "claude-done",  "kind": "process_exit", "target": "claude"},
  {"name": "coder-stuck",  "kind": "log_stalled",  "target": "coder", "minutes": 15},
  {"name": "coder-error",  "kind": "log_pattern",  "target": "coder", "pattern": "error"}
]
```

```powershell
.\.venv\Scripts\python -m agent.main doctor | Select-String "watch"        # "N watch rule(s) valid" চাই
# এজেন্ট রিস্টার্ট করুন; তারপর ফোনে হোম → "ওয়াচ", অথবা:
Invoke-RestMethod "$u/watch" -Headers $h
```

- `process_exit` তখনই বলে যখন প্রোগ্রামটি আগে অন্তত একবার চলতে দেখা গেছে। এজেন্ট শুরুর আগে থেকে বন্ধ থাকলে কিছু বলবে না।
- একই রুল ১০ মিনিটের (`watch_cooldown_seconds`) মধ্যে দ্বিতীয়বার সতর্ক করে না; ৩০ সেকেন্ড পরপর চেক (`watch_check_seconds`)।
- সতর্কতায় শুধু রুলের নাম ও নির্দিষ্ট বাক্য থাকে, লগের লেখা নয়।

**`critical_action`** (`"hibernate"`/`"lock"`) চালু করার আগে (খ)-এর hibernate পরীক্ষা করুন। এটাই একমাত্র জায়গা যেখানে টোকেন ছাড়া কিছু চলে (শুধু ব্যাটারিতে, ≤ক্রিটিক্যাল %, একবার)। প্রথমে `"none"` রেখে কিছুদিন সতর্কতা দেখুন।

**অপরীক্ষিত:** আসল ntfy/webhook, আসল কারেন্ট-কাট, আসল কোডিং এজেন্টের exit/stall (টেস্টে নকল প্রসেস/ফাইল/ঘড়ি)।

## (জ) "Cortex One" নামের ট্রেডমার্ক ও ডোমেইন

- ডোমেইন: cortexone.com / .ai / .app registrar-এ দেখুন।
- ট্রেডমার্ক: আপনার দেশের IP অফিস ও WIPO Global Brand Database-এ "Cortex One" খুঁজুন; দরকারে আইনজীবী। (আমি যাচাই করিনি।)

## (ঝ) রিলিজ ও জানা ঝুঁকি

```powershell
.\scripts\check.ps1
.\scripts\make-release.ps1 -WhatIf
.\scripts\make-release.ps1          # dist\cortex-one-1.0.0-rc1.zip + SHA-256 (শুধু গিটে ট্র্যাক করা ফাইল)
```

**জানা ঝুঁকি** (বিস্তারিত `docs\THREAT_MODEL.md`):

- **টোকেন চুরি গেলে** (ফোন হারালে) ফোন যা পারে হ্যাকারও তাই পারে: `.\.venv\Scripts\python -m agent.main devices` তারপর `revoke <id>`। ফোনে স্ক্রিন-লক রাখুন।
- **স্থির পিন SMS-এ replay সুরক্ষা নেই** — TOTP ব্যবহার করুন।
- **AI ভুল ফোল্ডার/ফাইল বেছে নিতে পারে** (অনুমোদিত সীমার ভেতরে)। কপি কখনো ওভাররাইট করে না; ডিলিট অ্যাকশন নেই। শুরুতে ফল চোখে দেখুন।
- **স্ক্রিনশটে ব্যক্তিগত তথ্য** থাকতে পারে; Tailscale দিয়ে ফোনে যায়, কোথাও আপলোড হয় না।
- **`run_script`** অনুমোদিত স্ক্রিপ্ট যা করে তাই করে — যা নিজে পড়ে বোঝেননি তা অনুমোদন করবেন না।
- **Tailscale-এ http** (TLS নেই): WireGuard এনক্রিপ্ট করে, কিন্তু আপনার tailnet-এ অন্য ডিভাইস থাকলে ACL দিয়ে সীমিত করুন।
- **ওয়াচার সতর্কতা নিশ্চয়তা নয়:** ল্যাপটপ ঘুমালে/এজেন্ট বন্ধ থাকলে/ntfy ডাউন থাকলে মিস হতে পারে।
- **অপরীক্ষিত (সব মিলিয়ে):** আসল Anthropic কল, আসল shutdown/restart/hibernate/lock, আসল ফোন, আসল SMS গেটওয়ে, ntfy/webhook, APK বিল্ড, অটো-স্টার্ট ইনস্টল, PyInstaller বিল্ড।

## স্বাধীন রিভিউয়ের (Phase 7) যা ঠিক করা হয়নি

(নিচে সেশনের শেষে যোগ হয়েছে।)
