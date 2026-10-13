# NEEDS_ME — শুধু আপনিই যা করতে পারবেন (ক্রমানুসারে)

সব কমান্ড PowerShell-এর জন্য। আগে `cd D:\cortex-one`। **আমি (Claude) কোনো key, টোকেন বা আসল শাটডাউন ছুঁইনি।**

---

## ১. `doctor` ও পুরো টেস্ট চালান (৫ মিনিট)

```powershell
cd D:\cortex-one
.\.venv\Scripts\python -m agent.main init-config     # config.json না থাকলে ডিফল্ট বানায়, থাকলে ছোঁয় না
.\.venv\Scripts\python -m agent.main doctor
.\.venv\Scripts\python -m pytest -q                  # আশা: 210 passed
cd mobile; flutter analyze; flutter test; cd ..      # আশা: No issues / 63 tests passed
```

`doctor`-এ **FAIL** থাকলে আগে ঠিক করুন। `WARN` স্বাভাবিক (যেমন key বা SMS এখনো সেট নেই)।

নতুন ফিচার চালু করতে `config.json` খুলে (ফাঁকা থাকলে ফিচার বন্ধ থাকে):

```powershell
notepad $env:APPDATA\CortexOne\config.json
```

- `"allowed_domains": ["github.com"]` → `open_url` চালু (শুধু https, হুবহু হোস্ট; যাদের বিশ্বাস করেন কেবল তাদের)
- `"allowed_logs": {"coder": "C:\\পথ\\agent.log"}` → `tail_log` চালু
- `"watched_programs": ["claude", "node", "python"]` → `agent_watch` চালু
- `screenshots_dir` ডিফল্ট `Documents\CortexOne-Screenshots` (অবশ্যই `allowed_roots`-এর ভেতরে)

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

- **আসল API কল এখনো পরীক্ষা হয়নি।** প্রথম রানে গরমিল (যেমন মডেলের নাম `ai_model`) ধরা পড়তে পারে; ত্রুটির বার্তা আমাকে দেখান।
- অটো-স্টার্টেও AI চালাতে চাইলে key ব্যবহারকারী-স্তরের ভ্যারিয়েবলে রাখতে হয় (রেজিস্ট্রিতে সাদা লেখায় থাকে; এটা সচেতন ঝুঁকি):
  `[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY","sk-ant-...","User")`
  না চাইলে এটা করবেন না; তখন অটো-স্টার্ট চালু এজেন্টে AI বন্ধ থাকবে, বাকি সব চলবে।

## ৩. আসল Windows পরীক্ষা: lock, তারপর shutdown + ৩০ সেকেন্ডে cancel

**আগে সব কাজ সেভ করুন।** টেস্টে আমি আসল shutdown/lock কখনো চালাইনি।

উইন্ডো ১: `.\.venv\Scripts\python -m agent.main pair` (কোড দেখাবে), তারপর `.\.venv\Scripts\python -m agent.main serve`
উইন্ডো ২:

```powershell
$u = "http://127.0.0.1:8765"
$r = Invoke-RestMethod -Method Post "$u/pair" -ContentType application/json -Body '{"code":"<৬ অঙ্ক>","device_name":"test-pc"}'
$h = @{ Authorization = "Bearer $($r.token)" }
function Act($n,$b='{"params":{}}'){ Invoke-RestMethod -Method Post "$u/actions/$n" -Headers $h -ContentType application/json -Body $b }

Act system_info                       # নতুন অ্যাকশন: CPU/RAM/ডিস্ক/ব্যাটারি
Act take_screenshot                   # ফাইল Documents\CortexOne-Screenshots-এ; স্ক্রিনশট নিজে একবার দেখুন
Act lock                              # স্ক্রিন লক হলে ঠিক আছে (আনলক করে ফিরে আসুন)

$c = Act shutdown                     # ধাপ ১: শুধু confirm_token দেয়, কিছু বন্ধ হয় না
$body = (@{ params = @{}; confirm_token = $c.confirm_token } | ConvertTo-Json)
Act shutdown $body                    # ধাপ ২ (৬০ সেকেন্ডের মধ্যে): ৩০ সেকেন্ডের কাউন্টডাউন শুরু
Act cancel_shutdown                   # ৩০ সেকেন্ডের ভেতরে! "Shutdown cancelled." আসা উচিত
```

যদি `cancel_shutdown` কাজ না করে: সাথে সাথে `shutdown /a` চালান।

## ৪. লগইনে অটো-স্টার্ট ইনস্টল

```powershell
.\scripts\install-startup.ps1 -WhatIf          # কী করবে দেখায়, কিছু বদলায় না
.\scripts\install-startup.ps1
Start-ScheduledTask -TaskName CortexOneAgent
Get-Content $env:APPDATA\CortexOne\logs\agent.log -Tail 20
# বন্ধ/মুছতে:  .\scripts\uninstall-startup.ps1
```

শুধু `-WhatIf` পর্যন্ত আমি পরীক্ষা করেছি; আসল ইনস্টল ও রিবুটে চালু হওয়া অপরীক্ষিত। Tailscale IP লগইনের সময় তখনো না থাকলে এজেন্ট ১ মিনিট পরপর ৫ বার আবার চেষ্টা করে।

## ৫. Tailscale (ল্যাপটপ + ফোন) ও `host`

1. https://tailscale.com/download থেকে ল্যাপটপ ও ফোনে ইনস্টল, **একই অ্যাকাউন্টে** লগইন।
2. ল্যাপটপে: `tailscale ip -4` (যেমন `100.x.y.z`)।
3. `notepad $env:APPDATA\CortexOne\config.json` → `"host": "100.x.y.z"` (**`0.0.0.0` নয়**)।
4. এজেন্ট আবার চালু করে `doctor` চালান।
5. ফোন কানেক্ট না হলে Windows Firewall আটকাচ্ছে হতে পারে। **অ্যাডমিন PowerShell-এ** (শুধু Tailscale রেঞ্জের জন্য):
   `New-NetFirewallRule -DisplayName "Cortex One (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 8765 -RemoteAddress 100.64.0.0/10 -Action Allow`

## ৬. Flutter অ্যাপ: APK বানানো, ফোনে ইনস্টল, পেয়ারিং

এই ল্যাপটপে Flutter 3.35.5 ও Android SDK (`D:\AndroidSDK`) আছে। `flutter analyze` ও ৬৩টি টেস্ট পাস, কিন্তু **APK বানানো হয়নি** (Android লাইসেন্স গ্রহণ আপনার কাজ)।

```powershell
flutter doctor --android-licenses       # প্রতিটিতে y (শর্ত নিজে পড়ে)
cd D:\cortex-one\mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release             # ৪ জিবি RAM: অন্য প্রোগ্রাম বন্ধ রাখুন, প্রথমবার ধীর
# ফাইল: build\app\outputs\flutter-apk\app-release.apk
```

ফোনে: Developer options → USB debugging চালু, তারপর `adb install -r build\app\outputs\flutter-apk\app-release.apk` (অথবা APK ফাইল ফোনে কপি করে খুলুন)।
পেয়ারিং: ল্যাপটপে `python -m agent.main pair` → অ্যাপে ঠিকানা `100.x.y.z` (পোর্ট না দিলে 8765) ও ৬ অঙ্কের কোড।
ভয়েস: বাংলা (bn_BD) চলতে ফোনের Google ভয়েস সেটিংসে Bengali ডাউনলোড থাকা ভালো। ভয়েসের অডিও ফোনের স্পিচ সার্ভিস সামলায়, আমাদের অ্যাপ নয়।
অপরীক্ষিত: আসল ফোনে UI, ভয়েস, SMS অ্যাপ খোলা, Keystore।

## ৭. SMS গেটওয়ে (পুরনো ফোন) ও কারেন্ট যাওয়ার সময়ের ব্যবস্থা

```powershell
.\.venv\Scripts\python -m agent.main sms-setup +8801XXXXXXXXX   # আপনার নম্বর; পিন বেছে নিন; gateway secret একবারই দেখায়, লিখে রাখুন
```

1. পুরনো অ্যান্ড্রয়েডে সিম + এমন SMS-ফরওয়ার্ডার অ্যাপ লাগবে যা HTTP POST পাঠায় (অ্যাপ আপনি বাছবেন)।
2. URL: `http://<ল্যাপটপের IP>:8765/sms/inbound`, হেডার `X-Gateway-Secret: <secret>`, বডি `{"from":"<sender>","text":"<message>"}`।
3. **কারেন্ট গেলে রাউটার বন্ধ:** গেটওয়ে ফোনের **হটস্পট বা USB টেদারিং** দিয়ে ল্যাপটপকে যুক্ত রাখুন, নইলে SMS পথও কাটা পড়ে। ল্যাপটপ ও ফোন একই নেটওয়ার্কে থাকতে হবে (Tailscale ছাড়া সরাসরি IP)।
4. **আগে `STATUS <পিন>` দিয়ে পরীক্ষা করুন, তারপর অন্য কিছু, `SHUTDOWN` সবার শেষে।**

## ৮. "Cortex One" নামের ট্রেডমার্ক ও ডোমেইন যাচাই

- ডোমেইন: cortexone.com / .ai / .app পাওয়া যায় কিনা registrar-এ দেখুন।
- ট্রেডমার্ক: আপনার দেশের IP অফিস ও WIPO Global Brand Database-এ "Cortex One" খুঁজুন; দরকারে আইনজীবীর সাথে কথা বলুন। (আমি যাচাই করিনি।)

## ৯. জানা ঝুঁকি (সচেতন থাকুন)

- **SMS-এ replay সুরক্ষা নেই:** কেউ আপনার পুরনো SMS আবার পাঠাতে পারলে কাজ আবার চলবে। তাই SMS-এ শুধু ছোট কমান্ড, আর `CANCEL`/`STOP` আছে। পিন গোপন রাখুন।
- **AI ভুল ফোল্ডার বেছে নিতে পারে।** এখন AI-কে অনুমোদিত ফোল্ডারের তালিকা বলা হয়, তবু শুরুতে ফলাফল চোখে দেখুন। কপি কখনো ওভাররাইট করে না; ডিলিট অ্যাকশনই নেই।
- **`open_url` সীমিত হলেও:** অনুমোদিত সাইটের পথ/কোয়েরি AI ঠিক করে। বিশ্বাসযোগ্য ডোমেইন ছাড়া দেবেন না।
- **Windows আচরণ অপরীক্ষিত:** আসল shutdown/restart, lock-এর ফল, অটো-স্টার্ট, ব্রাউজার খোলা, ফায়ারওয়াল।
- **আসল Anthropic API কল** ও **আসল ফোনে অ্যাপ** এখনো পরীক্ষা হয়নি।
- পেয়ারিংয়ে গ্লোবাল লকআউট ইচ্ছাকৃত: ভুল কোড স্প্যামে ৫ মিনিট পেয়ারিং বন্ধ থাকে।
- অ্যাপ plain `http` ব্যবহার করে (Tailscale-এর WireGuard এনক্রিপশনের ওপর)। Tailscale ছাড়া অন্য নেটওয়ার্কে কখনো পেয়ার করবেন না।
- স্ক্রিনশটে ব্যক্তিগত তথ্য থাকতে পারে; সেগুলো ল্যাপটপেই থাকে, কোথাও আপলোড হয় না।
