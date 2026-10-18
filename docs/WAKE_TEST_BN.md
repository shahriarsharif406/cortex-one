# ঘুম (Sleep) থেকে জাগানোর পরীক্ষা: ধাপে ধাপে

লক্ষ্য: জানা যে ফোন থেকে "ম্যাজিক প্যাকেট" পাঠালে ল্যাপটপ Sleep থেকে জাগে কি না। এই পরীক্ষা এখনও করা হয়নি; ফলাফল না জানা পর্যন্ত কিছু ধরে নেবেন না।

প্রস্তুতি (একবার): PowerShell-এ চালান, এটি কিছু বদলায় না, শুধু দেখায়:

```
powershell -ExecutionPolicy Bypass -File scripts\wake-test-prep.ps1
.venv\Scripts\python -m agent.main doctor
```

`doctor` লাইনে "Wi-Fi wake: armed (untested)" দেখলে বুঝবেন Windows অনুমতি দিয়েছে; এর মানে এই নয় যে বাস্তবে কাজ করবে।

## ধাপ

**(ক) কাজ সেভ করুন।** খোলা সব ফাইল সেভ করুন। চার্জার লাগান, ব্যাটারিতে চার্জ থাকতে হবে।

**(খ) Sleep করুন।** Start মেনু → Power → **Sleep**। *Shut down* বা *Hibernate* নয়। ল্যাপটপের LED ধীরে জ্বলা-নেভা করলে সেটা Sleep।

**(গ) ফোন থেকে পাঠান।** ফোনে যেকোনো Wake-on-LAN অ্যাপ (Play Store থেকে) নিন। ফোন ও ল্যাপটপ **একই Wi-Fi**-তে থাকতে হবে। অ্যাপে ল্যাপটপের **Wi-Fi MAC** দিন (ল্যাপটপে `Get-NetAdapter` চালিয়ে দেখুন; MAC কাউকে পাঠাবেন না, কোনো ফাইলে বা চ্যাটে লিখবেন না)। Broadcast `255.255.255.255`, পোর্ট 9। পাঠিয়ে **৩০ সেকেন্ড** অপেক্ষা করুন।

**(ঘ) না জাগলে।** Ethernet ক্যাবল লাগান (রাউটারের সাথে), ক্যাবল লাগানো অবস্থায় আবার Sleep করুন, এবার **Ethernet MAC** দিয়ে (গ) পুনরায় করুন। Ethernet সাধারণত Wi-Fi-র চেয়ে নির্ভরযোগ্য।

**(ঙ) ফল কী বোঝায়।**
- Sleep থেকে জাগলে: Sleep-এর জন্য বাড়তি যন্ত্র লাগবে না। "বন্ধ" করার বদলে Sleep ব্যবহার করুন।
- না জাগলে: Cortex Wake হার্ডওয়্যার (docs\cortex-wake\BUILD_GUIDE_BN.md) বা একটি সবসময়-চালু সহায়ক কম্পিউটার লাগবে।

**(চ) না জাগলে BIOS ও Device Manager দেখুন।**
- BIOS: ল্যাপটপ চালুর সময় F10 → Advanced/Power Management অংশে *Wake on LAN* / *Wake on WLAN* চালু করুন।
- Device Manager → Network adapters → আপনার অ্যাডাপ্টার → Properties → Power Management: "Allow this device to wake the computer" এবং "Only allow a magic packet to wake the computer" টিক দিন।

**(ছ) সৎ সীমা।**
- পুরোপুরি Shut down করলে, বা ব্যাটারি শেষ হলে কিছুই জাগাতে পারবে না।
- Wi-Fi চালু থাকতে হবে। বিদ্যুৎ গেলে রাউটারও বন্ধ হয়, তখন Wi-Fi দিয়ে জাগানো যাবে না।
- Hibernate থেকে জাগানো সাধারণত শুধু তারযুক্ত (Ethernet) অ্যাডাপ্টার ও BIOS সাপোর্ট থাকলে হয়।
- আপনার ল্যাপটপে Wi-Fi: Intel Wireless-N 7260 (Wi-Fi ম্যাজিক প্যাকেট প্রায়ই অনির্ভরযোগ্য), Ethernet: Intel I218-LM (ভালো সম্ভাবনা, তবে ক্যাবল লাগানো থাকতে হবে)।

ফল জানলে `NEEDS_ME.md`-এর সংশ্লিষ্ট ধাপে টিক দিন।
