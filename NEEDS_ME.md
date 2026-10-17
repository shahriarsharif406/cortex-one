# NEEDS_ME — শুধু আপনি যা করতে পারবেন (ক্রমানুসারে)

সব কমান্ড **PowerShell**-এর জন্য। শুরুতে সবসময়: `cd D:\cortex-one`। আমি (Claude) এই সেশনে আপনার কোনো API key, টোকেন, TOTP সিক্রেট, `.env`, আসল shutdown/sleep/hibernate/lock, নেটওয়ার্ক অ্যাডাপ্টার, পাওয়ার সেটিং, ফায়ারওয়াল বা রেজিস্ট্রি ছুঁইনি; আসল মাউস/কিবোর্ড/ব্লুটুথ/SMS/ম্যাজিক প্যাকেটও না। যা যাচাই হয়নি তা প্রতিটি ধাপে ও শেষে (ন) অংশে স্পষ্ট লেখা আছে। **সব ধাপ এই ক্রমে করুন; ধাপের শেষে `python -m agent.main doctor` চালান।** আরও গোছানো ক্রম: `docs\SETUP_ORDER_BN.md`।

---

## (ক) `check.ps1`, API ক্রেডিট + খরচের সীমা, key, প্রথম `ask`

```powershell
cd D:\cortex-one
.\scripts\check.ps1                      # টেস্ট + ভেক্টর + গোপন-তথ্য স্ক্যান + doctor + Flutter; শেষে ALL CHECKS PASSED চাই
```

`WARN` লাইন স্বাভাবিক (key, SMS, অটো-স্টার্ট এখনো নেই)। `FAIL` হলে আগে ঠিক করুন। "Skipped" লেখা থাকলে সেই অংশ যাচাই হয়নি।

১. https://console.anthropic.com → Billing: ক্রেডিট দিন (Claude.ai সাবস্ক্রিপশন আর API আলাদা)।
২. **key-র জন্য spending limit বসান** (যেমন মাসে ৫ ডলার)। Settings → API keys → নতুন key। key চ্যাটে বা ফাইলে লিখবেন না।
৩. লুকিয়ে টাইপ করে (কেবল এই উইন্ডোর জন্য):

```powershell
$k = Read-Host "Anthropic key" -AsSecureString
$env:ANTHROPIC_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($k))
Remove-Variable k
.\.venv\Scripts\python -m agent.main ask --dry-run "ল্যাপটপের অবস্থা বলো"     # কিছু পাঠায় না, key পড়ে না
.\.venv\Scripts\python -m agent.main ask "আমার ল্যাপটপের অবস্থা বলো"          # প্রথম আসল কল
.\.venv\Scripts\python -m agent.main ask "ল্যাপটপ বন্ধ করো"                  # চলবে না! শুধু কনফার্মেশন চাইবে
.\.venv\Scripts\python -m agent.main ai-usage
.\.venv\Scripts\python -m agent.main ai-history
```

৪. খরচের আন্দাজ: Anthropic-এর **বর্তমান দাম** নিজে `config.json`-এ বসান (`ai_price_per_mtok_input`, `ai_price_per_mtok_output`)।
৫. স্থায়ী করতে চাইলে (রেজিস্ট্রিতে সাদা লেখায়; সচেতন ঝুঁকি): `[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $env:ANTHROPIC_API_KEY, "User")`।

**অপরীক্ষিত:** আসল API কল (ছবি-সহ ও ছাড়া), মডেলের নাম `ai_model`, ক্রেডিট-শেষের আসল বার্তা, বাংলা নির্দেশ মডেল ঠিক বোঝে কিনা।

## (খ) আসল Windows পরীক্ষা: লক → শাটডাউন + ৩০ সেকেন্ডে cancel → স্লিপ ও জাগানো

**আগে সব কাজ সেভ করুন।** উইন্ডো ১: `python -m agent.main pair` তারপর `python -m agent.main serve`। উইন্ডো ২:

```powershell
$u = "http://127.0.0.1:8765"
$r = Invoke-RestMethod -Method Post "$u/pair" -ContentType application/json -Body '{"code":"<৬ অঙ্ক>","device_name":"test-pc"}'
$h = @{ Authorization = "Bearer $($r.token)" }
function Act($n,$b='{"params":{}}'){ Invoke-RestMethod -Method Post "$u/actions/$n" -Headers $h -ContentType application/json -Body $b }
function Confirm2($n){ $c = Act $n; Act $n (@{ params = @{}; confirm_token = $c.confirm_token } | ConvertTo-Json) }

Act system_info
Act lock                       # স্ক্রিন লক হলে ঠিক; আনলক করে ফিরুন
Confirm2 shutdown              # ৩০ সেকেন্ডের কাউন্টডাউন শুরু
Act cancel_shutdown            # ৩০ সেকেন্ডের ভেতরে! "Shutdown cancelled."
```

`cancel_shutdown` কাজ না করলে সাথে সাথে `shutdown /a`। **স্লিপ ও জাগানো (আলাদা পরীক্ষা, কাজ সেভ করে):** `Confirm2 sleep` → ল্যাপটপ ঘুমাবে (`SetSuspendState`; হাইবারনেট চালু ও স্লিপ বন্ধ থাকলে Windows হাইবারনেট করতে পারে) → পাওয়ার বোতাম চেপে জাগান। **হাইবারনেট:** আগে `powercfg /a`; না থাকলে অ্যাডমিন PowerShell-এ `powercfg /hibernate on`; তারপর `Confirm2 hibernate`।

**অপরীক্ষিত:** আসল shutdown/restart/sleep/hibernate/lock — টেস্টে শুধু FakeRunner।

## (গ) লগইনে অটো-স্টার্ট

```powershell
.\scripts\install-startup.ps1 -WhatIf        # কিছু বদলায় না
.\scripts\install-startup.ps1
Start-ScheduledTask -TaskName CortexOneAgent
Get-Content $env:APPDATA\CortexOne\logs\agent.log -Tail 20
```

রিবুট করে দেখুন এজেন্ট নিজে ওঠে। বন্ধ করতে `.\scripts\uninstall-startup.ps1`। **অপরীক্ষিত:** আসল ইনস্টল ও রিবুটের পর চালু হওয়া (শুধু `-WhatIf` দেখা হয়েছে)।

## (ঘ) Tailscale: ল্যাপটপ, ডেস্কটপ, ফোন + `hosts`

১. https://tailscale.com/download থেকে **তিনটিতেই** ইনস্টল, একই অ্যাকাউন্টে লগইন। ২. প্রতিটি কম্পিউটারে `tailscale ip -4` (যেমন `100.x.y.z`)। ৩. প্রতিটির `config.json` (`notepad $env:APPDATA\CortexOne\config.json`):

```json
"hosts": ["100.x.y.z"]
```

বাসার LAN-এও চাইলে `"hosts": ["100.x.y.z", "192.168.1.20"]`। **`0.0.0.0` বা পাবলিক IP দিলে এজেন্ট চালুই হবে না** (ইচ্ছাকৃত)। ৪. এজেন্ট আবার চালু করে `doctor`: "bind ঠিকানা বৈধ" ও "Tailscale ঠিকানা আছে"। ৫. ফোন না পৌঁছালে অ্যাডমিন PowerShell: `New-NetFirewallRule -DisplayName "Cortex One (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 8765 -RemoteAddress 100.64.0.0/10 -Action Allow`। ৬. অ্যাপে কম্পিউটার যোগ করুন (ঠিকানা `http://100.x.y.z:8765`; বাড়তি LAN ঠিকানা দিলে "আমার নিজের নেটওয়ার্ক" টিক লাগে)।

**অপরীক্ষিত:** আসল Tailscale-এ একাধিক ঠিকানায় বাইন্ড, বুটের সময় ঠিকানা দেরিতে ওঠার আচরণ।

## (ঙ) `doctor` ও `powercfg` wake পরীক্ষা (দুই কম্পিউটারেই), ডেস্কটপের BIOS-এ Wake-on-LAN

```powershell
.\.venv\Scripts\python -m agent.main doctor
powercfg /devicequery wake_armed
powercfg /devicequery wake_programmable
ipconfig /all                       # Physical Address = MAC (শুধু নিজের কাছে রাখুন)
```

`doctor`-এর "wake via Wi-Fi/Ethernet: yes/no/unknown" আর অ্যাডাপ্টার তালিকা দেখুন। **ডেস্কটপ:** BIOS/UEFI-তে "Wake on LAN"/"Power On By PCI-E" চালু; Device Manager → নেটওয়ার্ক কার্ড → Power Management → "Allow this device to wake the computer" + "Only allow a magic packet"; **তারের (Ethernet)** সংযোগ। "yes" মানে শুধু Windows অনুমতি দিচ্ছে, রাউটার/BIOS/ঘুমের ধরন সাথে না দিলে জাগবে না। Wi-Fi দিয়ে বন্ধ/হাইবারনেট থেকে জাগা প্রায় অসম্ভব।

## (চ) পাওয়ার প্ল্যান ও নেটওয়ার্ক অগ্রাধিকার স্ক্রিপ্ট (অ্যাডমিন PowerShell, আগে `-WhatIf`), SIM ব্যাকআপ

```powershell
.\scripts\set-power-plan.ps1 -WhatIf
.\scripts\set-power-plan.ps1 -PowerButton Sleep -EnableHibernate     # ঢাকনা বন্ধে কিছু না, চার্জারে ঘুম নেই, ক্রিটিক্যালে হাইবারনেট

Get-NetAdapter                                                       # নাম দেখুন (Wi-Fi, Ethernet 2 ...)
.\scripts\setup-network-priority.ps1 -WhatIf
.\scripts\setup-network-priority.ps1 -WifiAlias "Wi-Fi" -TetherAlias "Ethernet 2"
```

**SIM ব্যাকআপ:** পুরনো অ্যান্ড্রয়েডে SIM + USB টেদারিং (ফোনে Settings → Hotspot & tethering → USB tethering, তার লাগান) বা 4G ডঙ্গল। `config.json`-এ `"backup_adapter_name": "Ethernet 2"`। ঐচ্ছিক অটো-সুইচ (এজেন্ট নয়, আলাদা SYSTEM টাস্ক; ভুল করলে Wi-Fi বন্ধ থাকতে পারে, `-Remove` জানা রাখুন):

```powershell
.\scripts\install-network-failover.ps1 -WifiAlias "Wi-Fi" -TetherAlias "Ethernet 2" -WhatIf
.\scripts\install-network-failover.ps1 -WifiAlias "Wi-Fi" -TetherAlias "Ethernet 2"
# সরাতে:  .\scripts\install-network-failover.ps1 -Remove -WifiAlias "Wi-Fi"
```

**অপরীক্ষিত:** তিনটি স্ক্রিপ্টই (শুধু পার্স ও `ShouldProcess`-এর ভেতরে সব পরিবর্তন আছে এটুকু টেস্ট; আসলে চালানো হয়নি)।

## (ছ) RustDesk

`docs\REMOTE_DESKTOP_BN.md` পড়ে দুই দিকে ইনস্টল, "Direct IP access", **শক্ত স্থায়ী পাসওয়ার্ড + 2FA**। `config.json`:

```json
"allowed_apps": {"rustdesk": ["C:\\Program Files\\RustDesk\\rustdesk.exe"]},
"remote_desktop_app": "rustdesk", "remote_desktop_process": "rustdesk"
```

অ্যাপে কম্পিউটারের ✏️ → RustDesk ID (পাসওয়ার্ড নয়)। **অপরীক্ষিত:** `rustdesk://` লিংক আসল ফোনে, সংস্করণ বের করা, `remote_desktop_start`।

## (জ) `wake_targets` ও `wake_via`

যে কম্পিউটার জাগাবে (সবসময় চালু একটি) তার `config.json`-এ: `"wake_targets": {"desktop": {"mac": "AA:BB:CC:DD:EE:FF", "broadcast": "192.168.1.255"}}` (নাম = অ্যাপে ডেস্কটপের নামের ছোট হাতের রূপ)। অ্যাপে ডেস্কটপের ✏️ → "যে কম্পিউটার একে জাগাবে" = ল্যাপটপ। **পরীক্ষা:** ডেস্কটপ **স্লিপে** দিয়ে অ্যাপে "জাগান" → "{ল্যাপটপ}-এর মাধ্যমে জাগান"; এক মিনিট পরে অবস্থা দেখুন। **অপরীক্ষিত:** আসল ম্যাজিক প্যাকেটে আসল ডেস্কটপ জাগা।

## (ঝ) Cortex Wake: যন্ত্রাংশ কিনুন → বোতামের ধরন দেখুন → বানান → ফ্ল্যাশ → ক্যালিব্রেট → পরীক্ষা

`docs\cortex-wake\BUILD_GUIDE_BN.md` (যন্ত্রাংশের তালিকা, ASCII তারের নকশা, বোতামের ধরনভেদে বসানো, সতর্কতা)। সংক্ষেপে: ESP32 + সার্ভো (SG90/MG90S) + পাওয়ার ব্যাংক + জাম্পার + টেপ; সার্ভো **পাওয়ার ব্যাংকের ৫V** থেকে (ESP32-র 3.3V নয়), সব GND একসাথে। অ্যাপে "Cortex Wake গেটওয়ে" → "নতুন চাবি তৈরি" (একবারই দেখায়) → `firmware\cortex-wake\include\secrets.h` বানান। PlatformIO/arduino-cli ইনস্টল করে:

```powershell
cd D:\cortex-one\firmware\cortex-wake
pio run                         # কম্পাইল (এই ফার্মওয়্যার আজ পর্যন্ত কখনো কম্পাইল হয়নি; ত্রুটি আসতে পারে)
pio run -t upload               # ESP32 USB দিয়ে লাগিয়ে
pio device monitor
```

**প্রথম পরীক্ষা সার্ভো ল্যাপটপে না লাগিয়ে।** BOOT বোতাম চেপে (৬০ সেকেন্ড ক্যালিব্রেশন খোলে) কোণ ঠিক করুন। তারপর `scripts\set-power-plan.ps1` দিয়ে বোতাম = Sleep, ল্যাপটপে আটকে পরীক্ষা। **ল্যাপটপে ব্যাটারি/চার্জ ছাড়া কিছুই কাজ করবে না।** C++ হেডার (`cw_auth.h`) আমি সত্যিই চালিয়েছি (clang → WebAssembly → Node, ৫৪টি যাচাই, ০টি ব্যর্থ), কিন্তু `main.cpp`/ESP32/NimBLE/সার্ভো কখনো কম্পাইল বা চালানো হয়নি।

## (ঞ) SMS গেটওয়ে ও TOTP

**ল্যাপটপ এজেন্টের SMS:** `python -m agent.main sms-setup --totp +8801XXXXXXXXX` (gateway secret ও TOTP secret **একবারই** দেখায়; অথেনটিকেটরে যোগ করুন)। `STATUS 482913` ফরম্যাট; ল্যাপটপের ঘড়ি `w32tm /resync`। গেটওয়ে ফোনে SMS-ফরওয়ার্ডার অ্যাপ: URL `http://100.x.y.z:8765/sms/inbound`, হেডার `X-Gateway-Secret`, বডি `{"from":"...","text":"..."}`।

**Cortex Wake-এর আলাদা ওয়েক সিক্রেট** (এজেন্টের SMS সিক্রেট থেকে ভিন্ন): পুরনো ফোনে Cortex One অ্যাপ → সেটিংস → "Cortex Wake গেটওয়ে": অনুমতি দিন (SMS পড়া/পাঠানো, ব্লুটুথ, নোটিফিকেশন — কেন লাগে পর্দাতেই লেখা), **শুধু নিজের নম্বর** অনুমোদিত তালিকায়, চাবি তৈরি, অথেনটিকেটরে ওয়েক সিক্রেট, "গেটওয়ে চালু করুন"। ফোন সবসময় চার্জারে, ব্যাটারি-সেভার বন্ধ (Unrestricted)। পরীক্ষার ক্রম: `STATUS` → `PRESS কোড FORCE` (সার্ভো ল্যাপটপে না লাগিয়ে) → `ON কোড`।

**অপরীক্ষিত:** আসল SMS পথ, Kotlin `SmsReceiver`/`GatewayService` (কখনো কম্পাইল হয়নি), ফোন রিবুট/ব্যাটারি-নীতিতে সার্ভিস টিকে থাকা, Android ১৪-র ব্যাকগ্রাউন্ড-স্টার্ট নিয়ম, flutter_blue_plus দিয়ে আসল BLE।

## (ট) APK বানানো (কম-মেমরি সেটিং), সাইনিং কী, ইনস্টল, পেয়ারিং

Flutter (`D:\flutter`) আছে; আজ পর্যন্ত **APK বানানো হয়নি**। নতুন প্লাগইন যোগ হয়েছে (local_auth, connectivity_plus, flutter_blue_plus, image_picker, image, crypto) এবং Kotlin ফাইল ও `AndroidManifest`/থিম বদলেছে: **প্রথম বিল্ডে ত্রুটি আসতে পারে**। হিপ ১৫৩৬ MB, `daemon=false`, `workers.max=1` আগে থেকেই আছে। ব্রাউজার/IDE বন্ধ রাখুন; ১০–২০ মিনিট লাগে।

```powershell
mkdir D:\keys
keytool -genkey -v -keystore D:\keys\cortexone-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias cortexone
copy D:\cortex-one\mobile\android\key.properties.example D:\cortex-one\mobile\android\key.properties
notepad D:\cortex-one\mobile\android\key.properties        # পাসওয়ার্ড; storeFile=D:/keys/cortexone-release.jks
flutter doctor --android-licenses
cd D:\cortex-one\mobile
flutter clean
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm64
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

`.jks` ও পাসওয়ার্ডের ব্যাকআপ রাখুন (হারালে আপডেট দেওয়া যাবে না); `key.properties`/`.jks` গিটে যায় না। **ফোনে স্ক্রিন লক (পিন/আঙুলের ছাপ) থাকতে হবে**, নইলে কনফার্ম চলবে না। মেমরি ত্রুটি: `docs\TROUBLESHOOTING.md` ১২। পেয়ারিং: `python -m agent.main pair` (বা `--role viewer`) → অ্যাপে ঠিকানা ও কোড।

**অপরীক্ষিত:** APK বিল্ড, আসল ফোনে UI, বায়োমেট্রিক প্রম্পট, ভয়েস (অফলাইন বাংলা প্যাক সহ), ছবি তোলা/বাছা, connectivity_plus-এর SIM চেনা, Android থিম বদল (`AppCompat`), Keystore সাইনিং।

## (ঠ) নোটিফায়ার ও `watch_rules`

পুশ (ঐচ্ছিক): `$topic = "cortex-" + [guid]::NewGuid().ToString("N").Substring(0,16)`; `[Environment]::SetEnvironmentVariable("CORTEX_NOTIFY_TARGET",$topic,"User")`; `config.json`-এ `"notifier_type": "ntfy"`; ফোনের ntfy অ্যাপে টপিক সাবস্ক্রাইব (টপিক পাসওয়ার্ডের মতো গোপন)। এখন নেটওয়ার্ক পাহারাদারের (`net_*`) ও কোডিং-সেশন শেষের সতর্কতাও এই পথে যায়।

`watch_rules` (আগে `watched_programs`/`allowed_logs`-এ নাম):

```json
"watched_programs": ["claude", "node"],
"allowed_logs": {"coder": "C:\\Users\\<আপনি>\\AppData\\Local\\MyCodingAgent\\agent.log"},
"watch_rules": [
  {"name": "claude-done", "kind": "process_exit", "target": "claude"},
  {"name": "coder-stuck", "kind": "log_stalled", "target": "coder", "minutes": 15}
]
```

`doctor | Select-String "watch"`, এজেন্ট রিস্টার্ট, অ্যাপে হোম → "ওয়াচ"। **কোডিং সেশন** (ঐচ্ছিক): `coding_projects`-এ নাম, `path` (`allowed_roots`-এর ভেতরে), `argv`; `doctor` ভুল ধরে। **অপরীক্ষিত:** আসল ntfy/webhook, আসল কারেন্ট-কাট, আসল কোডিং এজেন্টের exit/stall।

## (ড) "Cortex One" ও "Cortex Wake" নামের ট্রেডমার্ক/ডোমেইন

ডোমেইন (cortexone.com/.ai/.app) registrar-এ, ট্রেডমার্ক আপনার দেশের IP অফিস ও WIPO Global Brand Database-এ খুঁজুন; দরকারে আইনজীবী। (আমি যাচাই করিনি।)

## (ঢ) ঐচ্ছিক বাড়তি: GUI মোড, লোকাল AI, viewer ফোন, টোকেনের মেয়াদ

- **GUI মোড (সবচেয়ে ঝুঁকির; আসল পর্দায় কখনো চালানো হয়নি):** `config.json`-এ `"gui_agent": {"enabled": true, "allowed_apps": ["notepad"], "max_session_minutes": 5, "max_actions": 30}`; অ্যাপ থেকে ছোট সেশন শুরু (আঙুলের ছাপ), **কাছে বসে**, নোটপ্যাডে। কিছু অস্বাভাবিক হলে বড় লাল STOP বা জরুরি স্টপ। ব্যাংক/পাসওয়ার্ড জানালা আটকানোর তালিকা **দুর্বল সুরক্ষা**; পাসওয়ার্ড-বক্স শনাক্তি শুধু ক্লাসিক Edit নিয়ন্ত্রণে। এই মোড ডিফল্টে বন্ধ রাখুন।
- **লোকাল AI:** ৪ GB ল্যাপটপে কাজের মতো মডেল চলে না (মেমরি ও গতি); এটা **ডেস্কটপের জন্য, স্পেক দেখে** (RAM, GPU)। ইনস্টল আমি করিনি, কোনো মডেল নামাইনি। Ollama নিজে ইনস্টল করে `config.json`: `"ai_fallback_to_local": true, "ai_local_endpoint": "http://127.0.0.1:11434", "ai_local_model": "<মডেলের নাম>"`। শুধু ইন্টারনেট-ত্রুটিতে, শুধু ৫টি পড়ার টুলে। ছোট মডেল ভুল করতে পারে।
- **viewer ফোন:** `python -m agent.main pair --role viewer`; হারালে `devices` তারপর `revoke <id>`। `token_ttl_days` (যেমন ৯০) বসাতে পারেন।

## (ণ) স্বাধীন রিভিউয়ের (Phase 11) ফল ও যা ঠিক করা হয়নি

এক জন নতুন-চোখ রিভিউয়ার (কিছু না জেনে, শুধু এই সেশনের পরিবর্তন) ১১টি সমস্যা পেয়েছে; কোনোটি "high" নয়। **আগে ব্যর্থ টেস্ট লিখে ঠিক করা হয়েছে** (`tests/test_review_session2.py`, Dart-এর জন্য `mobile/test/wake_test.dart`-এর শেষে):

1. সব POST-এ বডি আগে-থেকে সীমিত (৬৪ KB; ছবি শুধু `/ai/tasks`-এ) এবং chunked বডি বাতিল (আগে টোকেনের আগেই মেমরি ভরানো যেত)।
2. ফোন এখন যাচাই করে যে সই-করা উত্তরটি **ঠিক এই কমান্ডের** (পুরনো রেকর্ড-করা উত্তর চলে না)।
3. উত্তরহীন STATE/STATUS বারবার করে কাউন্টার ফার্মওয়্যারের জানালার বাইরে ঠেলে দেওয়া যেত; এখন উত্তর ছাড়া সর্বোচ্চ ৩ বার লাফ।
4. GUI স্ক্রিনশট এখন শুধু সামনের জানালার অংশে কাটা (পাশের ব্যাংক/পাসওয়ার্ড জানালা মডেল দেখে না); ক্লিকের বিন্দুতে সবার ওপরের জানালাও অনুমোদিত কিনা দেখা হয়।
5. লোকাল AI ক্লায়েন্ট প্রক্সি ব্যবহার করত; এখন সরাসরি।
6. `take_screenshot` ফোল্ডারের পথ ফেরত দিত (viewer-ও দেখত); `/health` অচেনাকে "শেষ কখন স্লিপ দেওয়া হয়েছে" বলত; GUI-তে টাইপ করা লেখা AI-র ধাপের তালিকায় যেত; অ্যাডমিন ইনস্টলার আগে-থেকে-থাকা ফোল্ডারের মালিকানা রিসেট করত না। সবই ঠিক।
7. ফার্মওয়্যার: কাউন্টার ফ্ল্যাশে না লিখতে পারলে আর কাজ করে না; ডকুমেন্টে ওয়াচডগের ভুল দাবি শুধরানো হয়েছে।

**ঠিক করা হয়নি (কারণসহ):**
- **SMS গেটওয়ের ৩-ভুলের লকআউট মেমরিতে থাকে:** সার্ভিস রিস্টার্ট করলে মুছে যায়; আবার, অনুমোদিত নম্বর নকল করে কেউ ৩ বার ভুল কোড পাঠিয়ে আপনাকে ১৫ মিনিট লক করতে পারে (নম্বর নকল সম্ভব নেটওয়ার্কভেদে)। TOTP-ই আসল গেট; লকআউট স্থায়ী করা পরের কাজ।
- **ফোন BLE ডিভাইস আইডি/ঠিকানা পিন করে না:** `CortexWake-*` নামের প্রথম বিজ্ঞাপনদাতাকে নেয়। ভুয়া ডিভাইস সই-করা কমান্ড ফ্রেম ধরে পরে আসলটাকে দিতে পারে (একবারই গৃহীত হয়)। শারীরিকভাবে কাছে থাকতে হয়; ঝুঁকি THREAT_MODEL ১৮-য়।
- **`STATUS` SMS-এ কোড লাগে না ও প্রতিবার ৮ সেকেন্ড BLE স্ক্যান:** অনুমোদিত নম্বর নকল করে ব্যাটারি খরচ করানো যায়; শুধু উত্তরটা সীমিত।
- **GUI ব্লকলিস্ট/পাসওয়ার্ড-বক্স শনাক্তি দুর্বল** (আগেই লেখা), এবং পুরো GUI মোড আসল পর্দায় অপরীক্ষিত। ক্রপ করায় পাশের জানালা দেখা যায় না, কিন্তু সামনের অনুমোদিত অ্যাপের ভেতরের ব্যাংকিং ট্যাব ধরা পড়বে শুধু শিরোনামে নাম থাকলে।
- রিভিউয়ার ai.py/gui.py-র GUI যুক্ততার সব অংশ, `doctor.py` ও Flutter পর্দাগুলো পুরো দেখেনি।

## (ত) জানা ঝুঁকি, আর যা **যাচাই হয়নি** (সৎ তালিকা)

**ঝুঁকি** (বিস্তারিত `docs\THREAT_MODEL.md` ৫ নং): টোকেন চুরি গেলে ফোন যা পারে হ্যাকারও পারে (`devices` → `revoke <id>`; ফোনে স্ক্রিন-লক); স্থির পিন SMS-এ replay সুরক্ষা নেই (TOTP নিন); LAN-এ http এনক্রিপ্ট ছাড়া (টিক দেওয়ার পর); `/health` কেউ পোর্টে পৌঁছালে দেখে (নাম, ব্যাটারি); চালু ল্যাপটপে পাওয়ার বোতাম চাপলে স্লিপ/বন্ধ হতে পারে; USB-সেন্সর ভুল বলতে পারে; BLE ফ্রেম দেরিতে পৌঁছালে একবার গৃহীত হয়; GUI সেশন বিপজ্জনক; কোডিং সেশন যা করে তাই করে; viewer স্ক্রিনশট দেখতে পায়।

**যা এখানে সত্যিই চালানো ও যাচাই হয়েছে:** `python -m pytest` (সংখ্যা শেষ রিপোর্টে), `flutter analyze` ও `flutter test`, `scripts\check.ps1`, Cortex Wake ভেক্টর পাইথন/Dart/C++(WebAssembly)-এ, প্রতিটি মিউটেশন-চেক (শেষ রিপোর্ট দেখুন)।

**যা যাচাই হয়নি (NOT verified):**
- আসল Anthropic কল (ছবি-সহ ও ছাড়া, GUI স্ক্রিনশট tool-result সহ), আসল লোকাল মডেল;
- আসল shutdown / restart / sleep / hibernate / lock / জাগানো (ম্যাজিক প্যাকেট আসল ডেস্কটপে);
- আসল ফোন: APK বিল্ড, বায়োমেট্রিক, connectivity_plus, ভয়েস (অফলাইন বাংলা), ছবি তোলা, `rustdesk://` লিংক;
- আসল SMS (এজেন্ট ও Cortex Wake), Kotlin `SmsReceiver`/`GatewayService`/`MainActivity` (কখনো কম্পাইল হয়নি), flutter_blue_plus BLE;
- ESP32 ফার্মওয়্যার (`main.cpp`) কম্পাইল/ফ্ল্যাশ, সার্ভো, সেন্সর, পুরো হার্ডওয়্যার;
- GUI মোডের আসল মাউস/কিবোর্ড/স্ক্রিন ক্যাপচার/ফোরগ্রাউন্ড-জানালা/পাসওয়ার্ড-বক্স শনাক্তি (ctypes কোড কখনো চালানো হয়নি);
- অ্যাডমিন স্ক্রিপ্ট (`setup-network-priority`, `set-power-plan`, `network-failover`, `install-network-failover`) আসলে চালানো;
- আসল `powercfg` আউটপুটের ভাষা/বিন্যাস (পার্সারে ইংরেজি আউটপুট ধরা), আসল Tailscale-এ বহু-ঠিকানা বাইন্ড;
- ntfy/webhook, আসল কারেন্ট-কাট, অটো-স্টার্ট ইনস্টল, PyInstaller বিল্ড;
- বাংলা ডকুমেন্টগুলো কোনো বাংলাভাষী পাঠক দিয়ে পড়ানো হয়নি।
