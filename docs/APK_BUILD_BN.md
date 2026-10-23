# ক্লাউডে APK বানানো (বাংলা)

ল্যাপটপে Flutter বসানোর দরকার নেই। GitHub নিজেই APK বানিয়ে দেবে।

1. GitHub-এ `shahriarsharif406/cortex-one` খুলুন → **Actions** ট্যাব।
2. বাঁ দিকে **Build Android APK (debug)** → **Run workflow** চাপুন (branch বেছে নিন)।
3. ১০–২০ মিনিট পরে সবুজ টিক এলে run খুলুন → নিচে **Artifacts** থেকে `cortex-one-debug-apk` নামান (zip, ভেতরে `app-debug.apk`)।
4. ফোনে APK নিয়ে ইনস্টল করুন (Settings-এ "unknown apps" অনুমতি দিতে হবে)।

নোট:
- এটা **debug** APK, শুধু আপনার নিজের ফোনের জন্য। কোনো পাসওয়ার্ড/কী লাগে না, repo-তে কোনো secret নেই।
- প্রতিবার নতুন debug key তৈরি হয়, তাই নতুন run-এর APK বসাতে হলে আগে পুরোনো অ্যাপ আনইনস্টল করুন।
- `flutter analyze` বা `flutter test` ফেল করলে APK তৈরি হবে না; তখন লগ আমাকে দেখান।
- Release (নিজের কী দিয়ে সই করা) বিল্ড ইচ্ছাকৃতভাবে `android/key.properties` ছাড়া বন্ধ আছে।
- ফোনের ভেতরের টোকেন/ঠিকানা শুধু ফোনের secure storage-এ থাকে; APK-তে কিছু নেই।
