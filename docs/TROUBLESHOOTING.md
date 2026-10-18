# সমস্যা সমাধান — Cortex One (বাংলা)

সব কমান্ড **PowerShell**-এ চালান। শুরুতে সবসময়:

```powershell
cd D:\cortex-one
```

প্রথম ধাপে যেকোনো সমস্যায় চালান — বেশিরভাগ সমস্যা এখানেই ধরা পড়ে:

```powershell
.\.venv\Scripts\python -m agent.main doctor
Get-Content "$env:APPDATA\CortexOne\logs\agent.log" -Tail 40      # এজেন্টের সর্বশেষ লগ (গোপন তথ্য মুছে লেখা হয়)
```

---

## ১. `python` পাওয়া যাচ্ছে না

লক্ষণ: `python : The term 'python' is not recognized...`

```powershell
py -3.10 --version                 # py লঞ্চার থাকলে এটা কাজ করে
where.exe python                   # কিছু না দেখালে Python নেই বা PATH-এ নেই
winget install Python.Python.3.10  # ইনস্টল (নতুন PowerShell খুলে আবার দেখুন)
```

ইনস্টলারে "Add python.exe to PATH" টিক দিতে ভুলবেন না।

## ২. `.venv` নেই বা ভাঙা

লক্ষণ: `.venv\Scripts\python.exe` পাওয়া যায় না; `run-agent.ps1` বলে "Python venv not found"।

```powershell
Remove-Item .venv -Recurse -Force -ErrorAction SilentlyContinue
python -m venv .venv
.\.venv\Scripts\python -m pip install --upgrade pip
.\.venv\Scripts\pip install -r requirements.txt
.\.venv\Scripts\python -m pytest -q          # সব পাস করলে ঠিক আছে
```

## ৩. পোর্ট 8765 ব্যস্ত ("port in use")

```powershell
Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue | Select-Object LocalAddress, State, OwningProcess
Get-Process -Id (Get-NetTCPConnection -LocalPort 8765 -State Listen).OwningProcess   # কোন প্রোগ্রাম ধরে আছে
```

আগের এজেন্টই চলছে মনে হলে বন্ধ করুন: `Stop-Process -Id <উপরের Id> -Force`। অন্য পোর্ট চাইলে `config.json`-এ `"port": 8766` বসান (ফোন অ্যাপেও নতুন পোর্ট দিতে হবে)।

## ৪. ফোন লগইন/সংযোগ করতে পারছে না — host ভুল

`host` মানে এজেন্ট কোন ঠিকানায় শোনে। `127.0.0.1` হলে শুধু ল্যাপটপ থেকেই পৌঁছানো যায়; **`0.0.0.0` দেবেন না**।

```powershell
tailscale ip -4                                            # ল্যাপটপের Tailscale IP (100.x.y.z)
notepad "$env:APPDATA\CortexOne\config.json"               # "host": "100.x.y.z" বসান
.\.venv\Scripts\python -m agent.main doctor                # "host একটি Tailscale IP" দেখতে হবে
```

ফোনের অ্যাপে সার্ভার ঠিকানা: `http://100.x.y.z:8765`। এজেন্ট রিস্টার্ট করুন (প্রশ্ন ১৩ দেখুন)।

## ৫. পেয়ারিং লক হয়ে গেছে ("Pairing is temporarily locked")

ভুল কোড বারবার দিলে ৫ মিনিট (ডিফল্ট) লক থাকে।

```powershell
Get-Process python | Where-Object { $_.Path -like "*cortex-one*" } | Stop-Process -Force   # এজেন্ট বন্ধ (লক মেমরিতে থাকে)
.\.venv\Scripts\python -m agent.main pair     # নতুন ৬ অঙ্কের কোড (৫ মিনিট বৈধ, একবার ব্যবহার)
.\.venv\Scripts\python -m agent.main serve    # আবার চালু করুন
```

কোড ঠিকঠাক টাইপ করুন; নতুন `pair` চালালে আগের কোড বাতিল হয়।

## ৬. `ANTHROPIC_API_KEY` সেট নেই ("AI is not set up")

key কখনো চ্যাটে/ফাইলে লিখবেন না। শুধু এই উইন্ডোর জন্য (লুকিয়ে টাইপ হয়):

```powershell
$k = Read-Host "Anthropic key" -AsSecureString
$env:ANTHROPIC_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($k))
.\.venv\Scripts\python -m agent.main doctor   # "ANTHROPIC_API_KEY সেট আছে" দেখতে হবে
```

স্থায়ী করতে (রেজিস্ট্রিতে সাদা লেখায় থাকে — সচেতন ঝুঁকি): `[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $env:ANTHROPIC_API_KEY, "User")`, তারপর **নতুন** PowerShell/লগইন।

## ৭. API ক্রেডিট নেই / key গ্রহণ হচ্ছে না

বার্তা "Anthropic অ্যাকাউন্টে ক্রেডিট নেই" বা "API key গ্রহণ হয়নি" এলে:

1. https://console.anthropic.com → Billing: ক্রেডিট আছে কি দেখুন (Claude.ai সাবস্ক্রিপশন আর API আলাদা)।
2. Settings → API keys: key সক্রিয় কি না, spending limit পার হয়েছে কি না।

```powershell
.\.venv\Scripts\python -m agent.main ai-usage      # আজ কত টোকেন গেছে (দাম config-এ বসালে খরচের আন্দাজও দেখায়)
.\.venv\Scripts\python -m agent.main ai-history    # শেষ ৫০টি AI কাজ
```

## ৮. অটো-স্টার্ট টাস্ক চলছে না

```powershell
Get-ScheduledTask -TaskName CortexOneAgent | Get-ScheduledTaskInfo      # LastRunTime, LastTaskResult
Start-ScheduledTask -TaskName CortexOneAgent                            # এখনই চালান
Get-Content "$env:APPDATA\CortexOne\logs\launcher.log" -Tail 20
.\scripts\install-startup.ps1 -WhatIf                                   # কী করবে আগে দেখুন
.\scripts\install-startup.ps1                                           # (আবার) ইনস্টল
```

টাস্ক শুধু আপনি **লগইন করলে** চালু হয় (অ্যাডমিন লাগে না)। `LastTaskResult` 0 না হলে লগ দেখুন; `Task not found` হলে ইনস্টল করা হয়নি।

## ৯. স্ক্রিনশট কালো বা খালি

স্ক্রিনশট শুধু **আনলক করা লগইন সেশনে** কাজ করে।

- স্ক্রিন লক/স্ক্রিনসেভার/রিমোট ডেস্কটপ বন্ধ থাকলে কালো আসে — ল্যাপটপ আনলক রাখুন।
- ফোল্ডার অনুমোদিত কি না: `doctor`-এ "স্ক্রিনশট ফোল্ডার অনুমোদিত এলাকার ভেতরে" দেখতে হবে; না হলে `screenshots_dir` ঠিক করুন (`allowed_roots`-এর ভেতরে হতে হবে)।

```powershell
.\.venv\Scripts\python -m agent.main doctor | Select-String "স্ক্রিনশট"
Get-ChildItem "$env:USERPROFILE\Documents\CortexOne-Screenshots" | Sort-Object LastWriteTime -Descending | Select-Object -First 3
```

## ১০. SMS-এ কোনো উত্তর আসে না

নিরাপত্তার জন্য ভুল নম্বর/ভুল কোডে কোনো উত্তর দেওয়া হয় না — তাই নীরবতা স্বাভাবিক হতে পারে।

```powershell
.\.venv\Scripts\python -m agent.main doctor | Select-String "SMS"      # SMS চালু আছে?
.\.venv\Scripts\python -m agent.main audit --limit 20                  # via=sms সারিতে কারণ দেখুন (sender not allowed / wrong pin / bad format)
.\.venv\Scripts\python -m agent.main sms-setup --totp 01XXXXXXXXX      # আবার সেটআপ (নতুন gateway secret ও TOTP secret একবারই দেখায়)
```

চেকলিস্ট: ফরম্যাট `STATUS 482913`; পাঠানোর নম্বর `sms_allowed_numbers`-এ; গেটওয়ে অ্যাপে `X-Gateway-Secret` হেডার ঠিক; ৩ বার ভুল কোডে ১৫ মিনিট লক; TOTP কোড একবারই চলে (একই কোড আবার পাঠালে বাতিল) — ফোনের ঘড়ি স্বয়ংক্রিয় সময়ে রাখুন।

## ১১. Tailscale দিয়ে পৌঁছানো যাচ্ছে না

```powershell
tailscale status                       # ল্যাপটপ ও ফোন দুটোই "online" দেখাতে হবে
tailscale ping <ফোনের-নাম-বা-IP>
Test-NetConnection 100.x.y.z -Port 8765   # TcpTestSucceeded : True হওয়া চাই (এজেন্ট চালু থাকতে হবে)
```

- এজেন্ট চালু না থাকলে `False` আসবে (প্রশ্ন ১৩)। ফোনে Tailscale অ্যাপ চালু ও একই অ্যাকাউন্টে লগইন কি না দেখুন।
- Windows ফায়ারওয়াল আটকালে (অ্যাডমিন PowerShell, শুধু Tailscale রেঞ্জ): `New-NetFirewallRule -DisplayName "CortexOne-Tailscale" -Direction Inbound -Protocol TCP -LocalPort 8765 -RemoteAddress 100.64.0.0/10 -Action Allow`
- ফোনে মোবাইল ডেটা/অন্য নেটওয়ার্ক থেকেও Tailscale লাগবে; সাধারণ ওয়াই-ফাইয়ের IP কাজ করবে না।

## ১২. APK বানাতে মেমরি ত্রুটি (4 GB ল্যাপটপ)

লক্ষণ: `OutOfMemoryError`, `Java heap space`, Gradle ডেমন ক্র্যাশ। `mobile\android\gradle.properties`-এ ইতিমধ্যে কম মেমরির সেটিং আছে (`-Xmx1536M`, ১ ওয়ার্কার, ডেমন বন্ধ)।

```powershell
cd D:\cortex-one\mobile
taskkill /F /IM java.exe 2>$null; flutter clean                       # পুরনো Gradle প্রসেস ও বিল্ড সাফ
# ব্রাউজার/IDE বন্ধ করে, শুধু আপনার ফোনের স্থাপত্য (arm64) বানান:
flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons
```

তবুও না হলে: পেজফাইল বাড়ান (সিস্টেম > অ্যাডভান্সড > পারফরম্যান্স > ভার্চুয়াল মেমরি, ৪–৬ GB), বা `-Xmx1536M`-কে `-Xmx2048M` করুন। রিলিজের জন্য `mobile\android\key.properties` লাগে (টেমপ্লেট: `key.properties.example`)।

## ১৩. এজেন্ট চালু আছে কিনা / রিস্টার্ট কীভাবে

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health                       # {status: ok, version: ...} আসা চাই (host আলাদা হলে সেটি দিন)
Get-Process python | Where-Object { $_.Path -like "*cortex-one*" }   # চলছে?
Get-Process python | Where-Object { $_.Path -like "*cortex-one*" } | Stop-Process -Force    # বন্ধ
Start-ScheduledTask -TaskName CortexOneAgent                          # টাস্ক দিয়ে চালু
# অথবা হাতে (জানালা খোলা থাকবে):
.\.venv\Scripts\python -m agent.main serve
```

## ১৪. ল্যাপটপ ঘুমিয়ে গেলে এজেন্ট ধরা যায় না

ঘুমন্ত ল্যাপটপ কমান্ড নিতে পারে না। চার্জারে থাকা অবস্থায় ঘুম বন্ধ করুন:

```powershell
powercfg /change standby-timeout-ac 0         # চার্জারে থাকলে কখনো ঘুমাবে না
powercfg /change monitor-timeout-ac 10        # স্ক্রিন বন্ধ হলেও এজেন্ট চলবে
powercfg /query SCHEME_CURRENT SUB_SLEEP      # বর্তমান সেটিং দেখুন
```

## ১৫. `watch_rules` সতর্কতা আসছে না / `doctor` অভিযোগ করছে

```powershell
.\.venv\Scripts\python -m agent.main doctor | Select-String "watch"
```

- "target is not in watched_programs/allowed_logs": রুলের `target` অবশ্যই `watched_programs` (প্রসেস রুল) বা `allowed_logs` (লগ রুল) তালিকার নাম হতে হবে — ফাইলের পথ নয়।
- `process_exit` তখনই সতর্ক করে যখন প্রোগ্রামটি আগে অন্তত একবার চলতে দেখা গেছে। `log_stalled`-এ `minutes` ১–১৪৪০। `log_pattern`-এ `pattern` সাধারণ লেখা (regex নয়), বড়-ছোট হাতের অক্ষর গুরুত্বহীন।
- একই রুল ১০ মিনিটের (`watch_cooldown_seconds`) মধ্যে দ্বিতীয়বার সতর্ক করে না। ফোনের "ওয়াচ" স্ক্রিনে প্রতিটি রুলের বর্তমান অবস্থা দেখুন; কনফিগ বদলালে এজেন্ট রিস্টার্ট করুন।
- ফোনে পুশ চাইলে `notifier_type`/`CORTEX_NOTIFY_TARGET` সেট করুন (`doctor` বলে দেবে ঠিক আছে কি না)।

## ১৬. (বোনাস) "running scripts is disabled on this system"

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-startup.ps1 -WhatIf
```

সিস্টেম-স্তরের নীতি বদলাতে হয় না; উপরের মতো শুধু ওই একবারের জন্য Bypass দিন।

---

# সেশন ২-এর নতুন সমস্যাগুলো (v1.1.0-rc1)

## ১৭. এজেন্ট চালু হচ্ছে না: "Refusing to start: ... 0.0.0.0 ..."

`hosts` বা `host`-এ এমন ঠিকানা আছে যা নিষিদ্ধ: `0.0.0.0`, পাবলিক IP বা হোস্টের নাম। শুধু `127.0.0.1`, Tailscale (`100.64.0.0/10`) বা বাসার LAN ঠিকানা (যেমন `192.168.1.20`) চলে। `doctor` চালান; কোন ঠিকানা ভুল তা বলে দেবে।

## ১৮. Tailscale ঠিকানা বুটের সময় এখনো ওঠেনি

এজেন্ট নিজে অপেক্ষা করে (২ সেকেন্ড, ৪, ৮ ... সর্বোচ্চ ১০ মিনিটের বিরতিতে চেষ্টা) এবং ঠিকানা উঠলেই বাইন্ড করে; **অন্য ঠিকানায় চলে যায় না**। লগে (`%APPDATA%\CortexOne\logs\agent.log`) "address ... is not up yet" দেখাবে। অনেকক্ষণ না উঠলে Tailscale অ্যাপ চালু ও লগইন করা আছে কিনা দেখুন; `doctor`-এ "Tailscale ঠিকানা আছে" OK হওয়া উচিত।

## ১৯. ফোনে অবস্থা "অজানা" / "অফলাইন" / "সম্ভবত ঘুমে"

- **অজানা**: ফোন এই কম্পিউটারের কাছ থেকে একবারও সাড়া পায়নি। ঠিকানা/Tailscale দেখুন।
- **সম্ভবত ঘুমে**: আপনি ফোন থেকে স্লিপ/হাইবারনেট দিয়েছিলেন আর তারপর সাড়া নেই। ফোন **বলতে পারে না** এটা সত্যিই ঘুমে নাকি নেটওয়ার্ক গেছে।
- **অফলাইন**: শাটডাউন দিয়েছিলেন, বা শেষবার ব্যাটারি প্রায় শেষ ছিল, বা কারণ অজানা। কারণটা কার্ডের নিচের লেখায় আছে।
এজেন্ট চালু থাকলেও অন্য ঠিকানা (LAN) বা Tailscale ঠিক না থাকলে ফোন তাকে "অফলাইন" দেখাতে পারে: "সম্পাদনা" থেকে দুই ঠিকানাই দিন।

## ২০. "জাগান" চাপলাম কিন্তু কম্পিউটার জাগেনি

"পাঠানো হয়েছে" মানে "জেগেছে" নয়। যা লাগে: (ক) সাহায্যকারী কম্পিউটার চালু ও একই বাসার নেটওয়ার্কে; (খ) এই কম্পিউটারের BIOS-এ Wake-on-LAN এবং Windows-এর নেটওয়ার্ক কার্ড সেটিংয়ে "Allow this device to wake the computer" + "Only allow a magic packet"; (গ) `wake_targets`-এ MAC ঠিক আছে (`ipconfig /all` → Physical Address); (ঘ) **তারের (Ethernet) সংযোগে** অনেক বেশি কাজ করে: Wi-Fi দিয়ে ঘুম থেকে মাঝে মাঝে, বন্ধ/হাইবারনেট থেকে প্রায় নয়। `powercfg /devicequery wake_armed` চালিয়ে দেখুন কার্ডটি আছে কিনা; `doctor`-এর "wake via" লাইনও দেখুন। ল্যাপটপের ব্যাটারি ও কারেন্ট না থাকলে কোনো উপায়েই জাগবে না।

## ২১. Cortex Wake: SMS-এর উত্তর আসে না / বোতাম চাপে না

পরীক্ষা এই ক্রমে: ১) গেটওয়ে ফোনে ব্যাটারি, ব্যালেন্স, সিগন্যাল; ২) অ্যাপের "Cortex Wake গেটওয়ে" পর্দায় "গেটওয়ে চলছে" ও সব অনুমতি; ৩) আপনার নম্বর অনুমোদিত তালিকায় (অন্য নম্বরের SMS-এ **কোনো উত্তর যায় না**, এটাই নকশা); ৪) `STATUS` পাঠিয়ে দেখুন: "cannot reach the ESP32" মানে ব্লুটুথে ESP32 পাচ্ছে না (পাওয়ার ব্যাংক, দূরত্ব, `secrets.h`-র চাবি অ্যাপের সাথে মেলে কিনা); ৫) "Wrong code" হলে অথেনটিকেটরে **ওয়েক সিক্রেট** (এজেন্টের SMS সিক্রেট নয়) আর দুই ডিভাইসের ঘড়ি; একই কোড দুবার চলে না; ৩ বার ভুলে ১৫ মিনিট লক (সে সময় সঠিক কোডেও চুপ); ৬) "state UNKNOWN / ON" লিখলে `FORCE` যোগ করুন, ঝুঁকি বুঝে। **হার্ডওয়্যার অপরীক্ষিত**: ফার্মওয়্যার কম্পাইল ত্রুটি আসতে পারে (`docs/cortex-wake/BUILD_GUIDE_BN.md`)।

## ২২. ছবি পাঠালে "The JPEG contains metadata" / "too large"

এজেন্ট ছবি **ঠিক করে না, ফিরিয়ে দেয়**। অ্যাপ নিজে ছোট করে EXIF মুছে পাঠায়; তবু ফিরলে ছবিটি অন্য কিছু (যেমন GIF/WebP) বা খুব জটিল। অন্য ছবি দিন। ছবি সর্বোচ্চ ৩টি, প্রতিটি ১.৫ MB-র কম। "too many AI tokens" মানে ছবিগুলোর আনুমানিক খরচ সীমা পেরিয়েছে: কম বা ছোট ছবি দিন।

## ২৩. কোডিং সেশন চালু হয় না

`config.json`-এর `coding_projects`-এ নাম, `path` (অবশ্যই `allowed_roots`-এর ভেতরের ফোল্ডার) আর `argv` (প্রোগ্রাম পাওয়া যেতে হবে) ঠিক থাকতে হবে। `doctor` কোন প্রজেক্টে কী সমস্যা বলে। ফোন/AI শুধু নাম দিতে পারে; কী চলবে তা শুধু আপনার কনফিগে। এজেন্ট শুধু **নিজের চালু করা** সেশন বন্ধ করতে পারে।

## ২৪. GUI সেশন: "A blocked app is in front" / "not an approved app"

GUI মোড ডিফল্টে বন্ধ (`gui_agent.enabled`)। চালু হলে ইনপুট চলে **শুধু** `allowed_apps`-এর কোনো অ্যাপ সামনে থাকলে। ব্যাংক/পাসওয়ার্ড/লগইন লেখা জানালার নামে থাকলে বা পাসওয়ার্ড ম্যানেজার/টার্মিনাল জাতীয় অ্যাপ সামনে থাকলে সব আটকে যায় (ছবিও দেখানো হয় না)। ১০টি আটকানো অনুরোধে সেশন নিজে শেষ হয়। ক্লিকের আগে স্ক্রিনশট নিতে হয় (কোঅর্ডিনেট সেই ছবির পিক্সেল)। **এই মোড আসল পর্দায় কখনো চালানো হয়নি**; প্রথমে নোটপ্যাডে ছোট সেশনে পরীক্ষা করুন, কাছে বসে।

## ২৫. লোকাল AI: "The local model is not reachable"

লোকাল মডেল (যেমন Ollama) আপনার নিজের কম্পিউটারে চালু থাকতে হবে এবং `ai_local_endpoint` অবশ্যই `http://127.0.0.1:পোর্ট`। অন্য কম্পিউটার বা https দেওয়া যায় না। ফলব্যাক শুধু **নেটওয়ার্ক/টাইমআউট** ত্রুটিতে চলে (ভুল key, ক্রেডিট নেই, রেট লিমিটে নয়), শুধু ৫টি পড়ার টুল দিয়ে, আর উত্তরে মডেলের নাম লেখা থাকে। ৪ GB ল্যাপটপে কাজের মতো মডেল চলে না; এটা ডেস্কটপের জন্য।

## ২৬. "This phone has the viewer role" (403) / টোকেনের মেয়াদ

`pair --role viewer` দিয়ে জোড়া ফোন শুধু দেখতে পারে (অবস্থা, স্ক্রিনশট, সতর্কতা)। বদলাতে হলে `revoke <id>` করে `pair` (owner) দিয়ে আবার জোড়া লাগান। `token_ttl_days` দিলে সেই দিনের পর টোকেন অচল হয় (অ্যাপ আবার পেয়ারিং চাইবে); `devices` দেখায় কোন ফোনের মেয়াদ কবে। হারানো ফোন: `revoke` করলে **পরের অনুরোধেই** সে আটকে যায়।

## ২৭. `network-failover` Wi-Fi বন্ধ করে রেখেছে

আলাদা অ্যাডমিন টাস্কটি Wi-Fi অ্যাডাপ্টার বন্ধ করেছে কারণ ইন্টারনেট ছিল না আর টেদার চালু ছিল। প্রতি ১৫ মিনিটে সে নিজে পরীক্ষা করে ফেরত আনে। এখনই ফেরাতে (অ্যাডমিন PowerShell): `Enable-NetAdapter -Name "Wi-Fi"`। টাস্কটি সরাতে: `.\scripts\install-network-failover.ps1 -Remove -WifiAlias "Wi-Fi"`। লগ: `%ProgramData%\CortexOne\failover\failover.log`।

# সেশন ৩-এর নতুন সমস্যাগুলো (v1.1.0-rc2)

## ২৮. "config.json সমস্যা / config problem"

এজেন্ট বা `doctor` শুরুতেই থেমে বলছে `config.json`-এ ভুল আছে (ভাঙা JSON, ভুল ধরনের মান, ঋণাত্মক সংখ্যা, পোর্ট সীমার বাইরে)। বার্তায় কোন কী-তে সমস্যা লেখা থাকে। ফাইল `%APPDATA%\CortexOne\config.json`; ঠিক করুন বা নাম বদলে `python -m agent.main init-config` দিয়ে নতুন বানান। এজেন্ট ইচ্ছা করেই অনুমান করে চলে না।

## ২৯. `doctor`: "unknown keys (typo?)"

config-এ এমন একটি কী আছে যা এজেন্ট চেনে না (বানান ভুল হতে পারে, যেমন `allowd_roots`)। ওই সেটিং কাজ করছে না। বানান ঠিক করুন।

## ৩০. "Wi-Fi wake: armed (untested)" মানে কী?

Windows জাগানোর অনুমতি দিয়েছে। বাস্তবে জাগবে কিনা রাউটার, BIOS, ড্রাইভার ও ঘুমের ধরনের ওপর নির্ভর করে। `docs\WAKE_TEST_BN.md` দিয়ে সত্যিকারের পরীক্ষা করুন। "Ethernet wake: armed but the adapter is not connected": ক্যাবল লাগান।

## ৩১. `doctor --show-mac` কেন লাগে?

MAC ঠিকানা সবসময় কনসোলে দেখানো হয় না, যাতে ভুলে স্ক্রিনশট/চ্যাটে চলে না যায়। ফোনের Wake-on-LAN অ্যাপে দিতে হলে `--show-mac` দিয়ে নিজের কনসোলে দেখুন, আর কাউকে পাঠাবেন না।
