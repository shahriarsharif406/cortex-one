# প্রথম দিন: আজকের অবস্থা থেকে ফোনে প্রথম কমান্ড (সর্বোচ্চ ১০ ধাপ)

> সব কমান্ড PowerShell-এ, `cd D:\cortex-one` করে। এই ধাপগুলো আপনি নিজে চালাবেন। বিস্তারিত ক্রম: `docs\SETUP_ORDER_BN.md`।

1. **সব ঠিক আছে কিনা দেখুন:** `.\scripts\check.ps1` (শেষে `ALL CHECKS PASSED`; doctor-এর WARN স্বাভাবিক)।
2. **API key:** Anthropic কনসোলে ক্রেডিট ও মাসিক খরচের সীমা দিন, তারপর
   ```powershell
   $s = Read-Host "ANTHROPIC_API_KEY" -AsSecureString
   $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
   [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b), "User")
   ```
   নতুন PowerShell খুলুন। (key কোথাও লিখবেন না, চ্যাটে দেবেন না।)
3. **প্রথম `ask`:** `.\.venv\Scripts\python -m agent.main ask --dry-run "অবস্থা বলো"` (কিছু পাঠায় না), তারপর `.\.venv\Scripts\python -m agent.main ask "ল্যাপটপের অবস্থা বলো"`।
4. **এজেন্ট চালু:** `.\scripts\run-agent.ps1` (বা অটো-স্টার্টের জন্য আগে `.\scripts\install-startup.ps1 -WhatIf`, তারপর ছাড়া)।
5. **Tailscale:** ল্যাপটপ ও ফোনে Tailscale ইনস্টল, একই অ্যাকাউন্টে লগইন। ল্যাপটপের `100.x.y.z` ঠিকানা লিখে রাখুন এবং `config.json`-এ `"hosts": ["100.x.y.z"]` দিন (কখনো `0.0.0.0` নয়), এজেন্ট আবার চালু করুন।
6. **জোড়া লাগানোর কোড:** `.\.venv\Scripts\python -m agent.main pair` (৫ মিনিট চলে, একবারই)।
7. **ফোন অ্যাপ:** APK বানানো আপনার কাজ (`NEEDS_ME.md` (ম))। বানিয়ে ফোনে ইনস্টল করুন। (APK না হওয়া পর্যন্ত SMS পথ বা `curl` দিয়ে পরীক্ষা করা যায়।)
8. **অ্যাপে:** সার্ভার ঠিকানা `http://100.x.y.z:8765` (Tailscale ঠিকানা), পেয়ারিং কোড দিন।
9. **প্রথম অবস্থা:** হোমে "অবস্থা" দেখুন (ব্যাটারি, সিস্টেম)। এটাই প্রথম সফল কমান্ড।
10. **নিরাপত্তা পরীক্ষা:** ফোনে লাল জরুরি-বন্ধ বোতামটি সব ট্যাবে আছে কিনা দেখুন। এরপর `.\.venv\Scripts\python -m agent.main devices` দিয়ে ফোনটি তালিকায় দেখুন।

**এখনও যা যাচাই হয়নি:** আসল Anthropic কল, আসল শাটডাউন/স্লিপ/ওয়েক, আসল ফোন, আসল SMS, Cortex Wake হার্ডওয়্যার, APK বিল্ড। সেগুলো `NEEDS_ME.md`-তে আছে।
