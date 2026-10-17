# কোন ক্রমে কী সেটআপ করবেন (সঠিক ক্রম, এক ধাপ শেষ হলে পরেরটি)

> সব কমান্ড **PowerShell**-এ, শুরুতে `cd D:\cortex-one`। অ্যাডমিন লাগার জায়গায় লেখা আছে "অ্যাডমিন PowerShell"। **আসল শাটডাউন/স্লিপ/ফ্ল্যাশ/APK আপনিই করবেন;** এই ডকুমেন্টের কোনো ধাপ আমি (Claude) আপনার মেশিনে চালাইনি। প্রতিটি ধাপে `-WhatIf` থাকলে আগে সেটা চালান।
>
> ছোট নিয়ম: প্রতি ধাপের শেষে `python -m agent.main doctor` চালান। FAIL থাকলে থামুন, WARN বুঝে এগোন।

## ধাপ ১: আগে থেকে বাকি কাজ (API key ও প্রথম `ask`)

1. `.\scripts\check.ps1` (সব সবুজ হতে হবে)।
2. Anthropic কনসোলে ক্রেডিট ও **মাসিক খরচের সীমা** দিন।
3. key বসান (স্ক্রিনে দেখা যায় না):
   ```powershell
   $s = Read-Host "ANTHROPIC_API_KEY" -AsSecureString
   $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
   [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b), "User")
   ```
4. নতুন PowerShell খুলে `python -m agent.main ask --dry-run "status দেখাও"` (কিছু পাঠায় না), তারপর `python -m agent.main ask "ল্যাপটপের অবস্থা বলো"`।

## ধাপ ২: আসল পরীক্ষা: লক, শাটডাউন, স্লিপ (কাজ সেভ করে)

`NEEDS_ME.md`-র (খ) অংশ: আগে লক, তারপর শাটডাউন + ৩০ সেকেন্ডের মধ্যে `cancel_shutdown`, তারপর স্লিপ ও জাগানো।

## ধাপ ৩: অটো-স্টার্ট

`.\scripts\install-startup.ps1 -WhatIf`, তারপর ছাড়া। রিবুট করে দেখুন এজেন্ট নিজে ওঠে।

## ধাপ ৪: Tailscale

লোকাল ল্যাপটপ, ডেস্কটপ ও ফোন তিনটিতেই Tailscale ইনস্টল, একই অ্যাকাউন্টে লগইন। প্রতিটির Tailscale IP (`100.x.y.z`) লিখে রাখুন। প্রতি কম্পিউটারের `config.json`-এ:
```json
"hosts": ["100.x.y.z"]
```
বাসার LAN-এও চাইলে (ইন্টারনেট ছাড়া Wi-Fi থাকলে কাজে আসে): `"hosts": ["100.x.y.z", "192.168.1.20"]`। **কখনো `0.0.0.0` নয়।**

## ধাপ ৫: নেটওয়ার্ক অগ্রাধিকার (SIM টেদার ব্যাকআপ) — অ্যাডমিন PowerShell

১. SIM-ফোনটি USB টেদারিংয়ে বা 4G ডঙ্গল লাগান। ২. `Get-NetAdapter` দিয়ে নাম দেখুন (যেমন `Wi-Fi`, `Ethernet 2`)। ৩. আগে:
```powershell
.\scripts\setup-network-priority.ps1 -WhatIf
```
৪. ঠিক লাগলে নাম দিয়ে চালান: `.\scripts\setup-network-priority.ps1 -WifiAlias "Wi-Fi" -TetherAlias "Ethernet 2"` (Wi-Fi মেট্রিক ১০, টেদার ৫০)। ৫. `config.json`-এ `"backup_adapter_name": "Ethernet 2"`।
৬. (ঐচ্ছিক, পরে) Wi-Fi-তে ইন্টারনেট না থাকলে নিজে টেদারে যেতে: `.\scripts\install-network-failover.ps1 -WifiAlias "Wi-Fi" -TetherAlias "Ethernet 2" -WhatIf` তারপর ছাড়া। এটা এজেন্ট নয়, আলাদা অ্যাডমিন টাস্ক। ভুল হলে `-Remove -WifiAlias "Wi-Fi"`।

## ধাপ ৬: পাওয়ার প্ল্যান — অ্যাডমিন PowerShell

```powershell
.\scripts\set-power-plan.ps1 -WhatIf
.\scripts\set-power-plan.ps1 -PowerButton Sleep -EnableHibernate
```
ঢাকনা বন্ধে কিছু হবে না, চার্জারে ঘুম/স্ক্রিন-অফ নেই, ক্রিটিক্যাল ব্যাটারিতে হাইবারনেট, পাওয়ার বোতাম = স্লিপ।

## ধাপ ৭: RustDesk

`docs\REMOTE_DESKTOP_BN.md` অনুযায়ী দুই দিকে ইনস্টল, সরাসরি IP, **শক্ত স্থায়ী পাসওয়ার্ড + 2FA**। `config.json`-এ `allowed_apps` ও `remote_desktop_app` বসান; অ্যাপে কম্পিউটারের তথ্যে RustDesk ID (পাসওয়ার্ড নয়)।

## ধাপ ৮: SIM ব্যাকআপ যাচাই

Wi-Fi বন্ধ করে (সাময়িকভাবে) দেখুন ফোন (মোবাইল ডেটায়, Tailscale চালু) ল্যাপটপে পৌঁছায় কিনা; অ্যাপে লিংক "SIM (ডেটা-সেভার)" দেখাবে।

## ধাপ ৯: ডেস্কটপের BIOS-এ Wake-on-LAN

১. BIOS/UEFI-তে "Wake on LAN" / "Power On By PCI-E" চালু (নাম মডেলভেদে)। ২. Windows → Device Manager → নেটওয়ার্ক কার্ড → Power Management → "Allow this device to wake the computer" ও "Only allow a magic packet"। ৩. ডেস্কটপে `powercfg /devicequery wake_armed` ও `... wake_programmable` চালিয়ে দেখুন কার্ডটি আছে কিনা (`python -m agent.main doctor`-ও দেখায়)। ৪. **তারের (Ethernet) সংযোগ** ব্যবহার করুন; Wi-Fi দিয়ে বন্ধ/হাইবারনেট থেকে প্রায় জাগে না। ৫. ডেস্কটপের MAC (`ipconfig /all`) নিন।

## ধাপ ১০: `wake_targets` ও `wake_via`

যে কম্পিউটার জাগাবে (সবসময় চালু থাকা একটি, যেমন ল্যাপটপ) তার `config.json`-এ:
```json
"wake_targets": {"desktop": {"mac": "AA:BB:CC:DD:EE:FF", "broadcast": "192.168.1.255"}}
```
(`desktop` নামটি অ্যাপে ডেস্কটপ কম্পিউটারের **নামের** ছোট হাতের রূপের সাথে মিলতে হবে।) অ্যাপে ডেস্কটপের ✏️ → "যে কম্পিউটার একে জাগাবে" = ল্যাপটপ। পরীক্ষা: ডেস্কটপ **স্লিপে** দিয়ে অ্যাপ থেকে "জাগান"।

## ধাপ ১১: Cortex Wake (ঐচ্ছিক, সবচেয়ে ঝামেলার)

`docs\cortex-wake\BUILD_GUIDE_BN.md` পড়ে যন্ত্রাংশ কিনুন, ল্যাপটপের পাওয়ার বোতাম কোন ধরনের দেখুন, ফার্মওয়্যার বানান (**কখনো কম্পাইল হয়নি**), ক্যালিব্রেট ও পরীক্ষা (সার্ভো ল্যাপটপে লাগানোর আগে টেবিলে)। তারপর গেটওয়ে ফোন সাজান (SMS ধাপের সাথে)।

## ধাপ ১২: SMS গেটওয়ে ও TOTP

এজেন্টের SMS: `python -m agent.main sms-setup --totp <আপনার নম্বর>` (সিক্রেট একবারই দেখায়)। **Cortex Wake-এর ওয়েক সিক্রেট আলাদা:** অ্যাপে "Cortex Wake গেটওয়ে" → "নতুন চাবি তৈরি করুন"। দুটি আলাদা এন্ট্রি অথেনটিকেটরে রাখুন।

## ধাপ ১৩: APK বানানো, সাইনিং, ইনস্টল, পেয়ারিং

`NEEDS_ME.md`-র (ক্ল) অংশ: কম মেমরির সেটিংয়ে `flutter build apk --release --split-per-abi --target-platform android-arm64`, `android\key.properties` (সাইনিং), ইনস্টল। ফোনে স্ক্রিন লক (পিন/আঙুলের ছাপ) **অবশ্যই** রাখুন; নইলে নিশ্চিতকরণ চলবে না। `python -m agent.main pair` (বা `--role viewer`) দিয়ে জোড়া লাগান।

## ধাপ ১৪: নোটিফায়ার ও ওয়াচ

`notifier_type`/`CORTEX_NOTIFY_TARGET` ও `watch_rules` (`NEEDS_ME.md` (ল))।

## ধাপ ১৫: ঐচ্ছিক বাড়তি

- **GUI মোড:** শেষে, কাছে বসে, নোটপ্যাডে ছোট সেশনে। `docs\USER_GUIDE_BN.md` §১৪।
- **লোকাল AI:** ডেস্কটপের স্পেক দেখে (৪ GB ল্যাপটপে কাজের মডেল চলে না)।
- **viewer ফোন:** পরিবারের কাউকে শুধু দেখতে দিতে।
- `token_ttl_days` (যেমন ৯০) বসাতে পারেন।

## শেষে

`.\scripts\check.ps1`, তারপর `git status` পরিষ্কার কিনা। ঝুঁকি ও যা অযাচাইকৃত তার তালিকা: `NEEDS_ME.md`-র শেষ অংশ ও `docs\THREAT_MODEL.md`।
