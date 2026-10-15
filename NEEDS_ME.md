# NEEDS_ME — শুধু আপনিই যা করতে পারবেন (ক্রমানুসারে)

সব কমান্ড PowerShell-এর জন্য। আগে `cd D:\cortex-one`। **আমি (Claude) কোনো key, টোকেন, `.env` বা আসল shutdown/lock ছুঁইনি।** যা আমি পরীক্ষা করতে পারিনি, নিচে স্পষ্ট লেখা আছে।

---

## ১. `doctor` ও পুরো টেস্ট (৫ মিনিট)

```powershell
cd D:\cortex-one
.\.venv\Scripts\python -m agent.main init-config     # config.json না থাকলে ডিফল্ট বানায়, থাকলে ছোঁয় না
.\.venv\Scripts\python -m agent.main doctor
.\.venv\Scripts\python -m pytest -q                  # আশা: প্রায় 362 passed, 2 skipped (Pillow/symlink ছাড়া)
cd mobile; flutter analyze; flutter test; cd ..      # আশা: No issues / 87 tests passed
```

`FAIL` থাকলে আগে ঠিক করুন। `WARN` স্বাভাবিক (key, SMS, নোটিফায়ার এখনো সেট নেই)।
ঐচ্ছিক: স্ক্রিন ছবি ছোট করে পাঠাতে (মোবাইল ডেটা বাঁচে): `.\.venv\Scripts\pip install pillow` (প্রায় ১০ MB)। না দিলে আসল ছবিই যায়।

কনফিগ খুলতে: `notepad $env:APPDATA\CortexOne\config.json` (সব অপশনের ব্যাখ্যা `README.md`-তে)।

## ২. Anthropic API: ক্রেডিট, খরচের সীমা, প্রথম `ask`

1. https://console.anthropic.com → Billing-এ ক্রেডিট দিন (Claude.ai সাবস্ক্রিপশন আর API আলাদা)।
2. **ওই key-র জন্য spending limit বসান** (যেমন মাসে ৫ ডলার)।
3. key চ্যাটে বা ফাইলে লিখবেন না। শুধু ওই PowerShell উইন্ডোর জন্য:

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."        # আপনার key, নিজে টাইপ করুন
.\.venv\Scripts\python -m agent.main ask "আমার ল্যাপটপের অবস্থা বলো"
.\.venv\Scripts\python -m agent.main ask "Downloads-এর PDF ফাইলগুলো দেখাও"
.\.venv\Scripts\python -m agent.main ask "ল্যাপটপ বন্ধ করো"     # চালানো উচিত নয়! শুধু কনফার্মেশন চাইবে
.\.venv\Scripts\python -m agent.main ai-usage
```

- **আসল API কল এখনো পরীক্ষা হয়নি।** মডেলের নাম (`ai_model`) বা অন্য গরমিল ধরা পড়তে পারে; ত্রুটির বার্তা আমাকে দেখান (key নয়)।
- অটো-স্টার্টেও AI চালাতে চাইলে key ব্যবহারকারী-স্তরের ভ্যারিয়েবলে রাখতে হয় (রেজিস্ট্রিতে সাদা লেখায় থাকে; সচেতন ঝুঁকি):
  `[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY","sk-ant-...","User")`
  না চাইলে করবেন না; তখন অটো-স্টার্ট এজেন্টে AI বন্ধ থাকবে, বাকি সব চলবে।

## ৩. আসল Windows পরীক্ষা: lock, তারপর shutdown + ৩০ সেকেন্ডে cancel

**আগে সব কাজ সেভ করুন।** টেস্টে আমি আসল shutdown/lock/hibernate কখনো চালাইনি।

উইন্ডো ১: `.\.venv\Scripts\python -m agent.main pair` (কোড দেখাবে), তারপর `.\.venv\Scripts\python -m agent.main serve`
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

যদি `cancel_shutdown` কাজ না করে: সাথে সাথে `shutdown /a` চালান।

**hibernate** (নতুন, আলাদা পরীক্ষা, কাজ সেভ করে নিন): আগে `powercfg /a` দিয়ে দেখুন Hibernate চালু আছে কিনা; না থাকলে অ্যাডমিন PowerShell-এ `powercfg /hibernate on`। তারপর `Act hibernate` (দুই ধাপ shutdown-এর মতোই)।

## ৪. লগইনে অটো-স্টার্ট ইনস্টল

```powershell
.\scripts\install-startup.ps1 -WhatIf          # কী করবে দেখায়, কিছু বদলায় না
.\scripts\install-startup.ps1
Start-ScheduledTask -TaskName CortexOneAgent
Get-Content $env:APPDATA\CortexOne\logs\agent.log -Tail 20
.\.venv\Scripts\python -m agent.main doctor    # "অটো-স্টার্ট টাস্ক আছে" দেখা উচিত
# বন্ধ/মুছতে:  .\scripts\uninstall-startup.ps1
```

শুধু `-WhatIf` পর্যন্ত আমি পরীক্ষা করেছি; আসল ইনস্টল ও রিবুটে চালু হওয়া অপরীক্ষিত। Tailscale IP লগইনের সময় তখনো না থাকলে এজেন্ট ১ মিনিট পরপর ৫ বার আবার চেষ্টা করে।

## ৫. Tailscale ও `host`

1. https://tailscale.com/download থেকে ল্যাপটপ ও ফোনে ইনস্টল, **একই অ্যাকাউন্টে** লগইন।
2. ল্যাপটপে: `tailscale ip -4` (যেমন `100.x.y.z`)।
3. `notepad $env:APPDATA\CortexOne\config.json` → `"host": "100.x.y.z"` (**`0.0.0.0` নয়**)।
4. এজেন্ট আবার চালু করে `doctor` চালান ("host একটি Tailscale IP" দেখা উচিত)।
5. ফোন কানেক্ট না হলে ফায়ারওয়াল। **অ্যাডমিন PowerShell-এ** (শুধু Tailscale রেঞ্জ):
   `New-NetFirewallRule -DisplayName "Cortex One (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 8765 -RemoteAddress 100.64.0.0/10 -Action Allow`

অ্যাপ এখন সাধারণ `http` শুধু Tailscale ঠিকানায় (100.64–127.x বা `*.ts.net`) নেয়; ঘরের Wi-Fi-র `192.168.x` বা `10.x` ঠিকানা **ইচ্ছাকৃতভাবে** নেয় না (ওই Wi-Fi-তে অন্য কেউ টোকেন দেখে ফেলতে পারে)।

## ৬. SMS ফলব্যাক: TOTP (পছন্দের) ও গেটওয়ে ফোন

```powershell
.\.venv\Scripts\python -m agent.main sms-setup --totp +8801XXXXXXXXX
```

- এটি **একবারই** দুটি জিনিস দেখায়: gateway secret এবং TOTP secret (base32)। কাগজে লিখে রাখুন বা সরাসরি অ্যাপে বসান; ফাইলে/চ্যাটে রাখবেন না।
- TOTP secret একটি অথেনটিকেটর অ্যাপে (Google Authenticator, Aegis ইত্যাদি) "time-based, ৬ অঙ্ক, ৩০ সেকেন্ড" দিয়ে যোগ করুন।
- SMS ফরম্যাট: `STATUS 482913`। কোড একবারই চলে; একই কোড দুবার পাঠালে "Wrong code."। ল্যাপটপ ও ফোনের ঘড়ি ঠিক রাখুন (`w32tm /resync`)।
- স্থির পিন চাইলে `sms-setup +8801XXXXXXXXX` (**replay সুরক্ষা নেই**, `doctor` সতর্ক করবে)।
- গেটওয়ে: পুরনো অ্যান্ড্রয়েডে সিম + এমন SMS-ফরওয়ার্ডার অ্যাপ যা HTTP POST পাঠায়। URL `http://<ল্যাপটপের IP>:8765/sms/inbound`, হেডার `X-Gateway-Secret: <secret>`, বডি `{"from":"<sender>","text":"<message>"}`।
- **কারেন্ট গেলে রাউটার বন্ধ:** গেটওয়ে ফোনের **হটস্পট বা USB টেদারিং** দিয়ে ল্যাপটপকে যুক্ত রাখুন। সবচেয়ে সহজ পথ: গেটওয়ে ফোনেও Tailscale চালু রাখুন, ফরওয়ার্ডার অ্যাপ ল্যাপটপের `100.x.y.z` ঠিকানায় পাঠাক (এজেন্ট শুধু সেই IP-তে শোনে, `0.0.0.0` লাগে না)। হটস্পটে Tailscale কাজ করবে কিনা আমি পরীক্ষা করিনি।
- পরীক্ষার ক্রম: আগে `STATUS`, তারপর অন্য কিছু, `SHUTDOWN` সবার শেষে। আসল SMS-পথ **অপরীক্ষিত** (DPAPI ও TOTP আসল Windows-এ টেস্টে চলেছে)।
- ভুল কোডে ৩ বার পর ১৫ মিনিট লকআউট; ওই সময় নম্বর চুপ থাকে।

## ৭. কারেন্ট-কাট সতর্কতা ও (ঐচ্ছিক) পুশ

ডিফল্টে ওয়াচার চালু; ল্যাপটপে ব্যাটারি থাকলে প্লাগ খুলে/লাগিয়ে দেখুন অ্যাপের হোম ব্যানার ও `Invoke-RestMethod "$u/alerts" -Headers $h`।

পুশ চাইলে (ntfy):

```powershell
# টপিক হবে লম্বা ও এলোমেলো (১৬+ অক্ষর); এটি পাসওয়ার্ডের মতো গোপন
$topic = "cortex-" + [guid]::NewGuid().ToString("N").Substring(0,16)
[Environment]::SetEnvironmentVariable("CORTEX_NOTIFY_TARGET",$topic,"User")
notepad $env:APPDATA\CortexOne\config.json     # "notifier_type": "ntfy"
```

ফোনে ntfy অ্যাপে ওই টপিকে সাবস্ক্রাইব করুন। webhook হলে `"notifier_type": "webhook"` এবং URL একইভাবে `CORTEX_NOTIFY_TARGET`-এ (শুধু https)। বার্তায় থাকে শুধু ঘটনা, ব্যাটারি %, সময়। ntfy.sh একটি তৃতীয় পক্ষ: তারা দেখতে পাবে আপনার ল্যাপটপ কখন ব্যাটারিতে গেল। আসল ntfy/webhook **অপরীক্ষিত**।

`critical_action` (`"hibernate"` বা `"lock"`) চালু করার আগে: ধাপ ৩-এর hibernate পরীক্ষা করুন, এবং বুঝে নিন এটাই একমাত্র জায়গা যেখানে কনফার্মেশন ছাড়া কিছু চলে (শুধু ব্যাটারিতে, ≤ক্রিটিক্যাল % হলে, একবার)। `"shutdown"` দিলে কিছুই হয় না। প্রথমে `"none"` রেখে কিছুদিন সতর্কতা দেখুন।

## ৮. Flutter অ্যাপ: কম-মেমরিতে বিল্ড, সাইনিং কী, ইনস্টল, পেয়ারিং

এই ল্যাপটপে Flutter 3.35.5 ও Android SDK (`D:\AndroidSDK`) আছে। `flutter analyze` পরিষ্কার, ৮৭টি টেস্ট পাস, কিন্তু **APK বানানো হয়নি** (লাইসেন্স গ্রহণ আপনার কাজ)। `gradle.properties`-এ হিপ ১৫৩৬ MB, `daemon=false`, `workers.max=1`; **বিল্ড ধীর হবে (১০–২০ মিনিট হতে পারে)। অন্য সব প্রোগ্রাম (ব্রাউজার, IDE) বন্ধ রাখুন।**

**(ক) সাইনিং কী তৈরি (একবার):** `keytool` Android Studio/JDK-তে থাকে।

```powershell
mkdir D:\keys
keytool -genkey -v -keystore D:\keys\cortexone-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias cortexone
copy D:\cortex-one\mobile\android\key.properties.example D:\cortex-one\mobile\android\key.properties
notepad D:\cortex-one\mobile\android\key.properties     # পাসওয়ার্ড বসান; storeFile=D:/keys/cortexone-release.jks
```

`key.properties` ও `.jks` গিট-এ যায় না (gitignored)। `.jks` ও পাসওয়ার্ডের ব্যাকআপ নিরাপদ জায়গায় রাখুন; হারালে অ্যাপ আপডেট করা যাবে না। **কী ছাড়া release বিল্ড ইচ্ছাকৃতভাবে ব্যর্থ হয়** (ডিবাগ কী দিয়ে সই করা অ্যাপ ফোনে বসানো ঠিক নয়)। এই Gradle শর্ত আমি চালিয়ে দেখিনি।

**(খ) বিল্ড:**

```powershell
flutter doctor --android-licenses       # প্রতিটিতে y (শর্ত নিজে পড়ে)
cd D:\cortex-one\mobile
flutter pub get
flutter build apk --release
# ফাইল: build\app\outputs\flutter-apk\app-release.apk
```

**(গ) ফোনে:** USB debugging চালু করে `adb install -r build\app\outputs\flutter-apk\app-release.apk` (অথবা APK ফাইল ফোনে কপি করে খুলুন)।
**(ঘ) পেয়ারিং:** ল্যাপটপে `python -m agent.main pair` → অ্যাপে ঠিকানা `100.x.y.z` (পোর্ট না দিলে 8765) ও ৬ অঙ্কের কোড। ভুল ঠিকানা, ভুল কোড, লকআউট, মেয়াদোত্তীর্ণ টোকেন, ল্যাপটপ অফলাইন: প্রতিটির আলাদা বাংলা বার্তা আছে (টেস্টে যাচাই করা)।
ভয়েস: বাংলা চলতে ফোনের Google ভয়েস সেটিংসে Bengali ডাউনলোড থাকা ভালো।
**অপরীক্ষিত:** আসল ফোনে UI, ভয়েস, স্ক্রিন ট্যাব, SMS অ্যাপ খোলা, Keystore, আইকন কেমন দেখায় (আইকন কোড দিয়ে আঁকা সাধারণ নকশা)।

## ৯. (ঐচ্ছিক) এক-ফোল্ডার .exe

```powershell
.\scripts\build-exe.ps1 -WhatIf
.\.venv\Scripts\python -m pip install pyinstaller    # শুধু বিল্ডের জন্য
.\scripts\build-exe.ps1
dist\CortexOneAgent\CortexOneAgent.exe doctor
```

PyInstaller এখানে ইনস্টল নেই; বিল্ড আমি **চালাইনি**। স্বাভাবিক ব্যবহারে লাগে না।

## ১০. অডিট এক্সপোর্ট

```powershell
.\.venv\Scripts\python -m agent.main export-audit --days 7    # %APPDATA%\CortexOne\audit-*.csv (গোপন তথ্য ছাঁকা)
```

## ১১. "Cortex One" নামের ট্রেডমার্ক ও ডোমেইন

- ডোমেইন: cortexone.com / .ai / .app পাওয়া যায় কিনা registrar-এ দেখুন।
- ট্রেডমার্ক: আপনার দেশের IP অফিস ও WIPO Global Brand Database-এ "Cortex One" খুঁজুন; দরকারে আইনজীবী। (আমি যাচাই করিনি।)

---

## জানা ঝুঁকি (সচেতন থাকুন)

- **স্থির পিন SMS-এ replay সুরক্ষা নেই।** TOTP ব্যবহার করুন (ধাপ ৬)।
- **AI ভুল ফোল্ডার বেছে নিতে পারে।** শুরুতে ফলাফল চোখে দেখুন। কপি কখনো ওভাররাইট করে না; ডিলিট অ্যাকশন নেই। (স্ক্রিনশট ফোল্ডারে কপি এখন নিষিদ্ধ।)
- **টোকেন চুরি গেলে** (ফোন হারালে) ফোন যা পারে হ্যাকারও তাই পারে: `devices` দেখে `revoke <id>` করুন। ফোনে স্ক্রিন-লক রাখুন।
- **স্ক্রিনশটে ব্যক্তিগত তথ্য** থাকতে পারে; ল্যাপটপে থাকে, ফোনে দেখার সময় ডাউনলোড হয়, কোথাও আপলোড হয় না। সর্বশেষ ২০টি রাখা হয়।
- **`open_url` সীমিত হলেও:** অনুমোদিত সাইটের পথ/কোয়েরি AI ঠিক করে। বিশ্বাসযোগ্য ডোমেইন ছাড়া দেবেন না।
- **Windows আচরণ অপরীক্ষিত:** আসল shutdown/restart/hibernate, lock-এর ফল, অটো-স্টার্ট, ব্রাউজার খোলা, ফায়ারওয়াল, আসল কারেন্ট-কাটে ওয়াচার।
- **আসল Anthropic API কল, আসল SMS, আসল ফোনে অ্যাপ, ntfy/webhook, PyInstaller বিল্ড, APK বিল্ড** এখনো পরীক্ষা হয়নি।
- `/screenshots` Pillow ছাড়া সবসময় পুরো ছবি পাঠায় (১২ MB পর্যন্ত): মোবাইল ডেটায় Pillow ইনস্টল করে নিন।

### স্বাধীন নিরাপত্তা রিভিউ: যা ঠিক করা হয়নি / আংশিক (কারণসহ)

ঠিক করা হয়েছে (প্রতিটির টেস্টসহ, `tests/test_review_fixes.py`): স্ক্রিনশট-পথে যেকোনো ফাইল পড়ার ফাঁক (কপি নিষিদ্ধ + ছবির ম্যাজিক বাইট যাচাই), পেয়ারিং লকআউট এখন ক্লায়েন্ট-ভিত্তিক, `/sms/inbound` রেট-লিমিট ও লকআউট, junction দিয়ে `find_files` বেরোনো, কনফার্মেশন/অডিট/পরামিতির আকার সীমা, ইঞ্জিনে AI-high-risk দ্বিতীয় আটকানো, `sms_mode` ভুল বানানে PIN-এ ফিরে যাওয়া, `build-exe.ps1` বাগ, ডিভাইস-নাম (`NUL`, `COM1`) ও ADS (`:stream`) নিষিদ্ধ, টুল-আউটপুটে যেকোনো `<`/`>` নিষ্ক্রিয়, অদৃশ্য/Unicode-tag অক্ষর ছাঁটা, ntfy টপিক ≥১৬ অক্ষর, পেয়ারিং কোডের race, অ্যাপে http শুধু Tailscale, release বিল্ডে ডিবাগ কী নিষিদ্ধ।

এখনো খোলা (ইচ্ছাকৃত বা কম ঝুঁকি):
1. **TOCTOU/hardlink:** `take_screenshot`-এ আগে থেকে বসানো symlink বা hardlink দিয়ে লেখা সরানো যায়; এজন্য আক্রমণকারীকে আগেই আপনার ইউজারে লোকাল ফাইল বানাতে হয়, তখন সে এমনিতেই বেশি পারে। ঠিক করা হয়নি।
2. **`notifier_target` কনফিগে প্লেইন টেক্সটে** থাকতে পারে যদি `CORTEX_NOTIFY_TARGET` ব্যবহার না করেন; ডক্স env ভ্যারিয়েবল বলে।
3. **SMS স্পুফ:** কেউ আপনার নম্বর জাল করে ভুল কোড পাঠালে (গেটওয়ে secret জানা লাগে) আসল নম্বর ১৫ মিনিট লক হতে পারে; এটি লকআউটের স্বাভাবিক দাম।
4. **ওয়াচারের ব্যাটারি নমুনা** hibernate কলের কয়েক মাইক্রোসেকেন্ড আগের; পুনরায় নমুনা নেওয়া হয় না (ঝুঁকি নগণ্য)।
5. **Uvicorn এক্সেপশন ট্রেসব্যাক** লগ-ফিল্টার শুধু বার্তা ছাঁকে; কোনো ফাঁস-পথ পাওয়া যায়নি, কিন্তু নিশ্চয়তা নেই।
6. **নেটওয়ার্ক সিকিউরিটি কনফিগ** Android-এ IP রেঞ্জ লিখতে পারে না, তাই cleartext চালু আছে এবং সীমা অ্যাপের কোডে (টেস্টসহ)।
7. **পেয়ারিং:** ক্লায়েন্ট-ভিত্তিক লকআউট ৫ বার, বিশ্বব্যাপী সীমা ৫০ বার; বহু ঠিকানা থেকে ছড়িয়ে আক্রমণ (শুধু আপনার Tailscale নেটওয়ার্কের ডিভাইস সম্ভব) তাত্ত্বিকভাবে সম্ভব।
