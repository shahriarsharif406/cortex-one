# যা শুধু আপনি করতে পারবেন (ক্রম অনুযায়ী) — v1.1.0-rc2

> সব কমান্ড PowerShell-এ, শুরুতে `cd D:\cortex-one`। আমি (Claude) এর কোনোটিই আপনার মেশিনে আসলে চালাইনি। যেখানে `-WhatIf` আছে সেখানে আগে সেটা। **আসল শাটডাউন/স্লিপ/লক করার আগে কাজ সেভ করুন।** প্রতি ধাপের শেষে `.\.venv\Scripts\python -m agent.main doctor` চালান: FAIL থাকলে থামুন।
> ছোট পথ: `docs\FIRST_DAY_BN.md`। বিস্তারিত ক্রম: `docs\SETUP_ORDER_BN.md`।

## (ক) সবকিছু ঠিক আছে কিনা
```powershell
.\scripts\check.ps1
```
শেষে `ALL CHECKS PASSED` চাই (আগে আমি এটা চালিয়েছি, কিন্তু আপনার মেশিনে নিজে একবার দেখুন)। doctor-এর WARN-গুলো পরের ধাপগুলোর কাজ।

## (খ) API ক্রেডিট, খরচের সীমা, key, প্রথম `ask`
1. Anthropic কনসোলে ক্রেডিট কিনুন ও **মাসিক খরচের সীমা** দিন।
2. key বসান (স্ক্রিনে দেখা যায় না; কোথাও লিখবেন না, আমাকে দেবেন না):
```powershell
$s = Read-Host "ANTHROPIC_API_KEY" -AsSecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b), "User")
```
3. নতুন PowerShell খুলে: `.\.venv\Scripts\python -m agent.main ask --dry-run "অবস্থা বলো"` তারপর `.\.venv\Scripts\python -m agent.main ask "ল্যাপটপের অবস্থা বলো"`। ছবি-সহ নির্দেশ ও আসল ত্রুটি-বার্তা (ক্রেডিট শেষ ইত্যাদি) এখনও কখনো আসল API-তে পরীক্ষা হয়নি।

## (গ) ঘুম থেকে জাগানোর পরীক্ষা (সবচেয়ে গুরুত্বপূর্ণ প্রশ্নের উত্তর)
```powershell
.\scripts\wake-test-prep.ps1
```
তারপর `docs\WAKE_TEST_BN.md` ধাপে ধাপে: ল্যাপটপ Sleep (Start মেনু থেকে) → ফোনের Wake-on-LAN অ্যাপ → **প্রথমে Wi-Fi MAC**, ৩০ সেকেন্ড অপেক্ষা; না জাগলে Ethernet ক্যাবল লাগিয়ে **Ethernet MAC**। MAC দেখতে: `.\.venv\Scripts\python -m agent.main doctor --show-mac` (শুধু আপনার কনসোলে)। ফল:
- জাগলে: Sleep-এর জন্য বাড়তি যন্ত্র লাগবে না।
- না জাগলে: Cortex Wake হার্ডওয়্যার (ধাপ ক) বা সবসময়-চালু সাহায্যকারী কম্পিউটার লাগবে।
আজকের doctor বলছে: Wi-Fi (Intel 7260) "armed, untested"; Ethernet (I218-LM) armed কিন্তু **ক্যাবল লাগানো নেই**। Wi-Fi ম্যাজিক-প্যাকেট প্রায়ই অনির্ভরযোগ্য।

## (ঘ) BIOS ও Device Manager
ল্যাপটপ চালুর সময় F10 → Advanced/Power Management → *Wake on LAN* / *Wake on WLAN* চালু। Device Manager → Network adapters → প্রতিটি → Power Management → "Allow this device to wake the computer" ও "Only allow a magic packet" টিক। ডেস্কটপেও একই (BIOS WoL)।

## (ঙ) আসল লক, শাটডাউন, স্লিপ পরীক্ষা (কাজ সেভ করে)
1. এজেন্ট চালান (`.\scripts\run-agent.ps1`), ফোন/curl থেকে `lock` অ্যাকশন: স্ক্রিন লক হলে ঠিক।
2. `shutdown` অ্যাকশন (দুই ধাপ নিশ্চিতকরণ) → **৩০ সেকেন্ডের মধ্যে** `cancel_shutdown`: শাটডাউন বাতিল হলে ঠিক।
3. `sleep` অ্যাকশন (নিশ্চিতকরণ সহ) → ল্যাপটপ ঘুমালে (গ)-এর পদ্ধতিতে জাগান।
এগুলো আজ পর্যন্ত কখনো আসলে চালানো হয়নি।

## (চ) অটো-স্টার্ট
```powershell
.\scripts\install-startup.ps1 -WhatIf
.\scripts\install-startup.ps1
```
রিবুট করে দেখুন এজেন্ট নিজে ওঠে।

## (ছ) Tailscale
ল্যাপটপ, ডেস্কটপ ও ফোনে Tailscale ইনস্টল, একই অ্যাকাউন্টে লগইন। প্রতিটির `100.x.y.z` ঠিকানা লিখুন। প্রতি কম্পিউটারের `%APPDATA%\CortexOne\config.json`-এ `"hosts": ["100.x.y.z"]` (চাইলে LAN ঠিকানাও; **কখনো `0.0.0.0` নয়**, এজেন্ট চালু হবে না)। তারপর `doctor`: "Tailscale address is present"।

## (জ) পাওয়ার প্ল্যান, নেটওয়ার্ক অগ্রাধিকার, SIM ব্যাকআপ — অ্যাডমিন PowerShell
```powershell
.\scripts\set-power-plan.ps1 -WhatIf
.\scripts\setup-network-priority.ps1 -WhatIf
```
ঠিক লাগলে `-WhatIf` ছাড়া। SIM-ফোনের USB টেদারিং বা 4G ডঙ্গল লাগিয়ে অ্যাডাপ্টারের নাম `config.json`-এর `backup_adapter_name`-এ দিন। (ঐচ্ছিক: `install-network-failover.ps1 -WhatIf`; পড়ুন `docs\THREAT_MODEL.md` 4.9।) এই স্ক্রিপ্টগুলো কখনো আসলে চালানো হয়নি।

## (ঝ) RustDesk
`docs\REMOTE_DESKTOP_BN.md` অনুযায়ী দুই পাশে ইনস্টল, স্থায়ী পাসওয়ার্ড + 2FA, Tailscale ঠিকানায় সরাসরি। তারপর `config.json`-এর `allowed_apps`-এ `rustdesk` যোগ করুন (doctor-এর WARN যাবে)।

## (ঞ) `wake_targets`, `wake_via`
যে কম্পিউটারকে জাগাতে চান তাতে `.\.venv\Scripts\python -m agent.main wake-setup` (নাম দিন যেমন `laptop`)। সৃষ্ট `laptop-wifi`/`laptop-ethernet` এন্ট্রি সবসময়-চালু কম্পিউটারের config-এর `wake_targets`-এ বসান। অ্যাপে ওই কম্পিউটারের তথ্যে "যে কম্পিউটার জাগাবে" (`wake_via`) দিন।

## (ট) Cortex Wake (ঐচ্ছিক; (গ)-তে না জাগলে)
1. **অনুভব পরীক্ষা (কেনার আগে):** ল্যাপটপের পাওয়ার বোতাম (বাঁ-ওপরে, কবজার পাশে, সাদা LED সহ ফালি-আকৃতি) আঙুলে চেপে দেখুন: ক্লিক আছে? কতটা জোর? মাপ নিন। `docs\cortex-wake\BUILD_GUIDE_BN.md` অংশ ৪ক (সিদ্ধান্তের গাছ)।
2. যন্ত্রাংশ কিনুন (ESP32 ডেভ বোর্ড, MG90S সার্ভো, পাওয়ার ব্যাংক, তার, টেপ/ব্র্যাকেট, ঐচ্ছিক: LDR + ১০ kΩ রেজিস্টর), পুরনো অ্যান্ড্রয়েড ফোন + SIM।
3. ফার্মওয়্যার: PlatformIO ইনস্টল, `firmware\cortex-wake\include\secrets.example.h` কপি করে `secrets.h`, `pio run` (**আমি এটি কম্পাইল করে দেখেছি: সফল**, কিন্তু কখনো ফ্ল্যাশ করিনি), `pio run -t upload`। প্রথম পরীক্ষা সার্ভো ল্যাপটপে না লাগিয়ে; BOOT চেপে ক্যালিব্রেট।
4. গেটওয়ে ফোনে অ্যাপ → Cortex Wake গেটওয়ে।
**কিছুই হার্ডওয়্যারে পরীক্ষা হয়নি। ল্যাপটপে ব্যাটারি/চার্জ, ফোনে ব্যাটারি/ব্যালেন্স/সিগন্যাল লাগবে।**

## (ঠ) SMS গেটওয়ে ও TOTP
`.\.venv\Scripts\python -m agent.main sms-setup +8801XXXXXXXXX --totp` (নিজের নম্বর)। দেখানো সিক্রেট অথেনটিকেটরে তুলুন। Cortex Wake-এর **আলাদা** ওয়েক সিক্রেট অ্যাপে তৈরি করুন। আসল SMS পথ কখনো পরীক্ষা হয়নি।

## (ড) APK বানানো, সাইনিং, ইনস্টল, পেয়ারিং
কম মেমরির সেটিংসে (Gradle জেভিএম সীমিত), `mobile\android\key.properties` ও কীস্টোর বানিয়ে (git-এ যায় না) `flutter build apk --release`, ফোনে ইনস্টল। `.\.venv\Scripts\python -m agent.main pair` → অ্যাপে কোড। APK আজ পর্যন্ত বানানো হয়নি; Kotlin কোড (`SmsReceiver`, `GatewayService`) Android SDK-তে কখনো কম্পাইল হয়নি।

## (ঢ) নোটিফায়ার ও watch_rules (ঐচ্ছিক)
`notifier_type` ("ntfy" বা "webhook") ও `CORTEX_NOTIFY_TARGET` পরিবেশ-চলক; `watch_rules` (README দেখুন)।

## (ণ) "Cortex One" নাম: ট্রেডমার্ক/ডোমেইন
প্রকাশ্যে দেওয়ার আগে নামটি ট্রেডমার্ক ডেটাবেস ও ডোমেইনে খুঁজে দেখুন।

## (ত) পরিষ্কার করা: আমার রেখে যাওয়া অস্থায়ী ফোল্ডার
ফার্মওয়্যার কম্পাইল করতে আমি D: ড্রাইভে অস্থায়ী PlatformIO ফোল্ডার বানিয়েছিলাম। মুছে ফেলার কমান্ড নিরাপত্তা-পরীক্ষায় আটকে গেছে, তাই আপনি মুছুন (আনুমানিক ১-৩ GB):
```powershell
Remove-Item -Recurse -Force D:\cortex-pio-tmp
Remove-Item -Force D:\cortex-pio-*.sh, D:\cortex-pio-log*.txt
```

## (থ) জানা ঝুঁকি ও যা যাচাই হয়নি
**যাচাই হয়েছে (স্বয়ংক্রিয় টেস্ট, নকল ব্যাকএন্ডে):** পুরো এজেন্ট, নিশ্চিতকরণ, ভূমিকা, WoL প্যাকেটের গঠন, ছবি যাচাই, কোডিং সেশন, GUI গেট, কনফিগ যাচাই, Cortex Wake প্রোটোকল (Python/Dart/C++ একই ভেক্টরে), অ্যাপের উইজেট টেস্ট, ফার্মওয়্যার **কম্পাইল**।
**যাচাই হয়নি:** আসল Anthropic কল (ছবি সহ), আসল শাটডাউন/স্লিপ/লক/জাগানো, আসল WoL প্যাকেট, আসল ফোন/APK, আসল SMS, BLE ও সার্ভো হার্ডওয়্যার, ফার্মওয়্যার ফ্ল্যাশ/চালানো, আলো-সেন্সর, আসল পর্দায় GUI মোড (SendInput, ফোরগ্রাউন্ড, পাসওয়ার্ড-ঘর শনাক্তকরণ শুধু ক্লাসিক Edit-এ), লোকাল AI মডেল, অ্যাডমিন স্ক্রিপ্ট (শুধু পার্স ও `-WhatIf`), বাংলা লেখা কোনো স্থানীয় পাঠক পড়ে দেখেননি।
**দুর্বলতা মনে রাখুন:** GUI মোডের শিরোনাম-ব্লকলিস্ট দুর্বল সুরক্ষা; SMS-এ PIN মোডে রিপ্লে সুরক্ষা নেই (TOTP নিন); টোকেনের মেয়াদ ডিফল্টে নেই (`token_ttl_days` দিন); কারেন্ট-কাট/ডেড ব্যাটারিতে কিছুই জাগাবে না।
**স্বাধীন পর্যালোচনা (সেশন ৩): ঠিক করা হয়েছে** (আগে ব্যর্থ-টেস্ট, তারপর ফিক্স): `open_app` দিয়ে RustDesk বিনা নিশ্চিতকরণে চালানো যেত (এখন আটকানো); অসম্ভব `gui_session_start` অনুরোধে আগে থেকেই নিশ্চিতকরণ চাওয়া হতো (এখন আগেই প্রত্যাখ্যাত); `secrets.h` কমিট-হুকে ব্লক ও রিলিজ-যাচাইয়ে `*.pem/*.key` ব্লক; অ্যাডাপ্টারের নামে কন্ট্রোল ক্যারেক্টার ফিল্টার।
**অমীমাংসিত (ঠিক করা হয়নি, কারণসহ):**
1. `install-network-failover.ps1` শুধু শেষ ফোল্ডারের অনুমতি ঠিক করে, বাবা-ফোল্ডার `C:\ProgramData\CortexOne` নয়। ঝুঁকি: সাধারণ ব্যবহারকারী আগেই ফোল্ডার বানিয়ে রাখলে SYSTEM টাস্ক তার স্ক্রিপ্ট চালাতে পারে। অ্যাডমিন স্ক্রিপ্ট আসলে চালিয়ে পরীক্ষা করা যায় না বলে আমি না ছুঁয়ে রেখেছি; **এই টাস্ক ইনস্টল করার আগে** `C:\ProgramData\CortexOne` ফোল্ডারটি নেই কিনা দেখুন (থাকলে মুছে ইনস্টল করুন)।
2. `network-failover.ps1`: Wi-Fi বন্ধ করার পরে লগ লিখতে ব্যর্থ হলে `disabledAt` সেভ হয় না, Wi-Fi বন্ধই থেকে যেতে পারে। একই কারণে অপরীক্ষিত রাখা; কিছু ইনস্টল করলে `Enable-NetAdapter -Name "Wi-Fi"` মনে রাখুন (TROUBLESHOOTING ২৭)।
3. `coding_projects`-এ প্রোগ্রামের নাম (যেমন `claude`) PATH থেকে খোঁজা হয়, কার্ডে পুরো পথ দেখানো হয় না। **সবসময় পুরো পথ (`C:\...\claude.exe`) দিন।**
4. Cortex Wake গেটওয়ে: SMS-এ ভুল কোডের ১৫ মিনিটের লকআউট সব প্রেরকের জন্য একসাথে (অনুমোদিত নম্বর নকল করে কেউ আপনাকে লক করে দিতে পারে); STATUS অনুরোধে হার-সীমা নেই (ব্যাটারি খরচ করানো সম্ভব)। ঝুঁকি ছোট; গ্রহণ করা হয়েছে।
5. ছবি যাচাই: একাধিক-স্ক্যান JPEG-এ প্রথম স্ক্যানের পরের মার্কার ও PNG `iCCP` পরীক্ষা হয় না। ফোন সবসময় মেটাডেটা মুছে পাঠায়, তাই আক্রমণ-পথ নয়, শুধু গোপনীয়তা-শিথিলতা।
6. ফোন অ্যাপ LAN ঠিকানায় টোকেন পাঠানোর আগে `/health.computer_id` মেলায় না (বাসার নেটওয়ার্কে ঠিকানা দখল হলে প্লেইন http-তে টোকেন যেতে পারে)। Tailscale ব্যবহার করুন; LAN-এ "আমার নিজের নেটওয়ার্ক" টিক সতর্কভাবে দিন।
