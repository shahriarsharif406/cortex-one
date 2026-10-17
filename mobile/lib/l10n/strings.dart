import '../api/api_client.dart';
import '../images/image_prep.dart' show ImagePrepError;

/// Bangla-first strings with an English toggle. Missing keys fall back to the key
/// itself; a unit test checks both languages have exactly the same keys.
class S {
  const S(this.lang);

  final String lang; // 'bn' | 'en'

  bool get isBangla => lang != 'en';

  bool has(String key) => (isBangla ? _bn : _en).containsKey(key);

  String t(String key) => (isBangla ? _bn[key] : _en[key]) ?? _en[key] ?? key;

  /// `{n}`-style placeholders.
  String tf(String key, Map<String, Object> values) {
    var text = t(key);
    values.forEach((k, v) => text = text.replaceAll('{$k}', '$v'));
    return text;
  }

  /// Clear, plain error text for the user (never a stack trace).
  String error(Object error) {
    if (error is AuthDeclined) return t('auth_failed');
    if (error is ImagePrepError) return t(error.messageKey);
    if (error is ApiException) {
      final base = switch (error.kind) {
        ApiErrorKind.network => t('err_network'),
        ApiErrorKind.timeout => t('err_timeout'),
        ApiErrorKind.unauthorized => t('err_unauthorized'),
        ApiErrorKind.forbidden => t('err_forbidden'),
        ApiErrorKind.notFound => t('err_notfound'),
        ApiErrorKind.invalid => t('err_invalid'),
        ApiErrorKind.rateLimited => t('err_rate'),
        ApiErrorKind.unavailable => t('err_unavailable'),
        ApiErrorKind.server => t('err_server'),
        ApiErrorKind.badResponse => t('err_bad'),
      };
      // The agent's own message explains e.g. "ANTHROPIC_API_KEY is empty" or a refused picture.
      return (error.kind == ApiErrorKind.unavailable ||
                  error.kind == ApiErrorKind.invalid) &&
              error.detail.isNotEmpty
          ? '$base\n(${error.detail})'
          : base;
    }
    return t('err_unknown');
  }

  /// Errors while pairing, where the likely cause differs from later requests.
  String pairError(Object e) {
    if (e is ApiException) {
      switch (e.kind) {
        case ApiErrorKind.network:
        case ApiErrorKind.timeout:
          return t('err_pair_offline');
        case ApiErrorKind.notFound:
        case ApiErrorKind.badResponse:
        case ApiErrorKind.server:
          return t('err_pair_wrong_address');
        case ApiErrorKind.forbidden:
          return t('err_pair_code');
        case ApiErrorKind.rateLimited:
          return t('err_pair_locked');
        case ApiErrorKind.invalid:
          return t('code_invalid');
        default:
          break;
      }
    }
    return error(e);
  }

  static List<String> get keys => _bn.keys.toList();
  static Set<String> get bnKeys => _bn.keys.toSet();
  static Set<String> get enKeys => _en.keys.toSet();
}

const Map<String, String> _bn = {
  'answered_by':
      'উত্তর দিয়েছে: {m}',
  'answered_local':
      'ইন্টারনেট নেই, তাই কম্পিউটারের লোকাল মডেল ({m}) উত্তর দিয়েছে। এটা শুধু পড়ার কাজ পারে, ছোট মডেল তাই ভুল হতে পারে।',
  'gui_title':
      'GUI সেশন (AI মাউস-কিবোর্ড চালাবে)',
  'gui_note':
      'অপরীক্ষিত: আসল পর্দায় এটা কখনো চালানো হয়নি। AI শুধু আপনার অনুমোদিত সীমিত সময়ের সেশনে, অনুমোদিত অ্যাপ সামনে থাকলে ক্লিক/টাইপ করতে পারে। ব্যাংক, পাসওয়ার্ড, লগইন জাতীয় উইন্ডো আটকানো হয়, কিন্তু সেই তালিকা দুর্বল সুরক্ষা। পর্দার লেখা AI-এর কাছে শুধু তথ্য, আদেশ নয়।',
  'gui_off':
      'GUI মোড বন্ধ আছে (ল্যাপটপের config.json-এ gui_agent.enabled)।',
  'gui_minutes':
      'কত মিনিট',
  'gui_start':
      'GUI সেশন চালু করুন',
  'will_gui_start':
      'AI {n} মিনিটের জন্য এই কম্পিউটারের মাউস ও কিবোর্ড চালাতে পারবে, শুধু অনুমোদিত অ্যাপ সামনে থাকলে। যেকোনো সময় STOP চাপুন; জরুরি স্টপও এটা শেষ করে। অপরীক্ষিত।',
  'gui_open':
      'চলমান সেশন দেখুন',
  'gui_screen_title':
      'GUI সেশন',
  'gui_stop':
      'STOP',
  'gui_active':
      'সেশন চলছে',
  'gui_ended':
      'সেশন শেষ',
  'gui_remaining':
      'বাকি সময়: {t}',
  'gui_actions_used':
      'কাজ: {n}/{m}',
  'gui_no_shot':
      'এখনো কোনো ছবি নেই',
  'gui_actions_title':
      'সাম্প্রতিক কাজ',
  'gui_reason':
      'শেষ হওয়ার কারণ: {r}',
  'act_gui_session_start':
      'GUI সেশন চালু',
  'confirm_gui_session_start':
      'GUI সেশন চালু নিশ্চিত করুন',
  'tools_title':
      'কোডিং সেশন ও রিমোট ডেস্কটপ',
  'coding_title':
      'কোডিং সেশন',
  'coding_refresh':
      'তালিকা দেখুন',
  'coding_none':
      'কোনো কোডিং প্রজেক্ট সেট করা নেই (config.json-এর coding_projects)।',
  'coding_start':
      'চালু',
  'coding_stop':
      'বন্ধ',
  'coding_state_running':
      'চলছে',
  'coding_state_exited':
      'শেষ হয়েছে (কোড {c})',
  'coding_state_not started':
      'চালু হয়নি',
  'will_coding_start':
      'প্রজেক্ট "{name}" চালু হবে: মালিকের ঠিক করা প্রোগ্রাম সেই ফোল্ডারে খুলবে। কী চলবে তা ল্যাপটপের config.json-এ ঠিক করা; এখান থেকে বদলানো যায় না।',
  'will_coding_stop':
      'প্রজেক্ট "{name}"-এর সেশন (এবং তার চালানো প্রোগ্রাম) বন্ধ হবে। অসেভ কাজ হারাতে পারে।',
  'rd_title':
      'রিমোট ডেস্কটপ (RustDesk)',
  'rd_note':
      'RustDesk আলাদা অ্যাপ: পর্দা ও টাচ ওটাই দেখায়। Cortex One শুধু চালু আছে কিনা দেখে, চালু করে, আর অ্যাপ খুলে দেয়। RustDesk-এর পাসওয়ার্ড কখনো পড়া বা রাখা হয় না। SIM ডেটায় ছবি অনেক ডেটা খায়।',
  'rd_open':
      'RustDesk খুলুন',
  'rd_status':
      'কম্পিউটারে চলছে কিনা',
  'rd_start':
      'কম্পিউটারে RustDesk চালু করুন',
  'rd_need_id':
      'আগে কম্পিউটারের তথ্যে RustDesk ID লিখুন।',
  'rd_open_failed':
      'RustDesk অ্যাপ খোলা যায়নি। ফোনে RustDesk ইনস্টল আছে কিনা দেখুন।',
  'will_remote_start':
      'কম্পিউটারে RustDesk চালু হবে। চালু থাকলে আপনার RustDesk পাসওয়ার্ড জানা যে কেউ এতে ঢুকতে পারবে, তাই শক্ত স্থায়ী পাসওয়ার্ড ও 2FA রাখুন।',
  'p_remote_start':
      'RustDesk চালু',
  'confirm_coding_start':
      'কোডিং সেশন চালু নিশ্চিত করুন',
  'act_coding_session_start':
      'কোডিং সেশন চালু',
  'confirm_coding_session_start':
      'কোডিং সেশন চালু নিশ্চিত করুন',
  'act_coding_session_stop':
      'কোডিং সেশন বন্ধ',
  'confirm_coding_session_stop':
      'কোডিং সেশন বন্ধ নিশ্চিত করুন',
  'act_remote_desktop_start':
      'RustDesk চালু',
  'confirm_remote_desktop_start':
      'RustDesk চালু নিশ্চিত করুন',
  'attach_gallery':
      'গ্যালারি থেকে ছবি',
  'attach_camera':
      'ক্যামেরা',
  'attach_count':
      'ছবি: {n}/৩',
  'attach_note':
      'ছবি পাঠানোর আগে ছোট করা হয় এবং লোকেশন/ক্যামেরার তথ্য (EXIF) মুছে ফেলা হয়। ছবির ভেতরের লেখা শুধু পড়া হয়, তার আদেশ মানা হয় না।',
  'image_failed':
      'ছবিটি পড়া বা তৈরি করা যায়নি। অন্য ছবি দিন।',
  'image_too_big':
      'ছবিটি ছোট করেও ১.৫ MB-এর বেশি থেকে যায়। অন্য বা সরল ছবি দিন।',
  'gw_menu':
      'Cortex Wake গেটওয়ে (এই ফোন পাওয়ার-বোতাম রোবটের সাথে)',
  'gw_title':
      'Cortex Wake গেটওয়ে',
  'gw_why':
      'এই মোডে এই ফোনটি (SIM সহ, সবসময় চার্জে) আপনার অনুমোদিত নম্বর থেকে আসা "ON <কোড>" SMS শুনবে এবং ব্লুটুথে ESP32-কে পাওয়ার বোতাম চাপতে বলবে। তাই অ্যাপের দরকার: SMS পড়া (RECEIVE_SMS), একটি ছোট উত্তর SMS পাঠানো (SEND_SMS), ব্লুটুথ, এবং চলমান থাকার নোটিফিকেশন। অনুমোদিত নম্বর ছাড়া কারও SMS-এর উত্তর দেওয়া হয় না, SMS-এর লেখা কোথাও জমানো হয় না। যা অসম্পূর্ণ: হার্ডওয়্যার পরীক্ষা করা হয়নি; ফোনের ব্যাটারি/ব্যালেন্স/সিগন্যাল না থাকলে বা ল্যাপটপের ব্যাটারি শেষ হলে কাজ করবে না।',
  'gw_perm_btn':
      'অনুমতি দিন',
  'gw_perm_ok':
      'সব অনুমতি দেওয়া আছে',
  'gw_perm_missing':
      'অনুমতি বাকি আছে',
  'gw_perm_denied':
      'অনুমতি দেওয়া হয়নি, তাই গেটওয়ে চালু করা যাবে না।',
  'gw_numbers_label':
      'অনুমোদিত নম্বর (প্রতি লাইনে একটি)',
  'gw_numbers_invalid':
      'একটি নম্বর ঠিক নয়। যেমন: 01711111111 বা +8801711111111',
  'gw_bind_label':
      'এই ফোনের Tailscale ঠিকানা (ইন্টারনেট থেকে চালাতে; ঐচ্ছিক)',
  'gw_bind_invalid':
      'শুধু 127.x, Tailscale (100.64-127.x) বা বাসার LAN ঠিকানা চলবে; 0.0.0.0 কখনো নয়।',
  'gw_create':
      'নতুন চাবি তৈরি করুন',
  'gw_create_warn':
      'নতুন চাবি পুরনোগুলো বাতিল করে। ESP32-তে নতুন চাবি বসিয়ে আবার ফ্ল্যাশ করতে হবে এবং অথেনটিকেটরে নতুন সিক্রেট দিতে হবে।',
  'gw_secrets_title':
      'এই চাবিগুলো শুধু এখনই একবার দেখানো হচ্ছে',
  'gw_secrets_once':
      'কোথাও কপি করে রাখুন (কাগজে লিখুন)। অ্যাপ এগুলো আর দেখাবে না, লগে/SMS-এ পাঠাবে না।',
  'gw_secret_wake':
      'ওয়েক সিক্রেট (অথেনটিকেটর অ্যাপে টাইম-ভিত্তিক কী হিসেবে দিন; ল্যাপটপ এজেন্টের SMS সিক্রেট থেকে আলাদা)',
  'gw_secret_fw':
      'ফার্মওয়্যারের চাবি (firmware/cortex-wake/include/secrets.h-এ বসান)',
  'gw_secret_token':
      'HTTP টোকেন (অ্যাপে "গেটওয়ে টোকেন" ঘরে দিন)',
  'gw_done':
      'আমি লিখে রেখেছি',
  'gw_start':
      'গেটওয়ে চালু করুন',
  'gw_stop':
      'গেটওয়ে বন্ধ করুন',
  'gw_running':
      'গেটওয়ে চলছে',
  'gw_stopped':
      'গেটওয়ে বন্ধ',
  'gw_need_setup':
      'আগে নম্বর দিন এবং চাবি তৈরি করুন।',
  'gw_save':
      'সেভ করুন',
  'gw_saved':
      'সেভ হয়েছে',
  'gw_log_title':
      'সাম্প্রতিক ঘটনা (কোড, SMS-এর লেখা বা পূর্ণ নম্বর ছাড়া)',
  'gw_log_empty':
      'এখনো কিছু ঘটেনি',
  'state_online':
      'অনলাইন',
  'state_sleeping':
      'ঘুমিয়ে আছে (সম্ভবত)',
  'state_offline':
      'অফলাইন',
  'state_unknown':
      'অজানা',
  'reason_sleep':
      'আপনি {t}-এ স্লিপ দিয়েছিলেন, তারপর আর সাড়া দেয়নি। ফোন বলতে পারে না এটা স্লিপে নাকি নেটওয়ার্ক নেই।',
  'reason_hibernate':
      'আপনি {t}-এ হাইবারনেট দিয়েছিলেন, তারপর আর সাড়া দেয়নি।',
  'reason_shutdown':
      'আপনি {t}-এ শাটডাউন দিয়েছিলেন। বন্ধ থাকলে ফোন থেকে সরাসরি জাগানো যায় না।',
  'reason_restart':
      'রিস্টার্ট চলছে হতে পারে ({t})। কয়েক মিনিট অপেক্ষা করুন।',
  'reason_battery':
      'শেষবার ব্যাটারি খুব কম ছিল এবং চার্জে ছিল না: সম্ভবত ব্যাটারি শেষ হয়ে বন্ধ হয়েছে।',
  'reason_noanswer':
      'সাড়া দিচ্ছে না: স্লিপ, বন্ধ, বা নেটওয়ার্ক/Tailscale সমস্যা: ফোন বলতে পারে না।',
  'reason_never':
      'এই ফোন থেকে এখনো একবারও সাড়া পায়নি।',
  'last_seen':
      'শেষ সাড়া: {t}',
  'seen_never':
      'কখনো সাড়া পায়নি',
  'battery_line':
      'ব্যাটারি {p}% ({c})',
  'link_tailscale':
      'লিংক: Tailscale',
  'link_lan':
      'লিংক: বাসার Wi-Fi (LAN)',
  'link_sim':
      'লিংক: SIM মোবাইল ডেটা (ডেটা-সেভার)',
  'link_none':
      'লিংক: এখনো সংযোগ হয়নি',
  'power_title':
      'পাওয়ার',
  'power_note':
      'ঝুঁকিপূর্ণ বোতামে চাপলে কী হবে দেখাবে, তারপর ফোনের আঙুলের ছাপ/পিন লাগবে।',
  'p_wake':
      'জাগান',
  'p_sleep':
      'স্লিপ',
  'p_hibernate':
      'হাইবারনেট',
  'p_shutdown':
      'শাটডাউন',
  'p_restart':
      'রিস্টার্ট',
  'p_lock':
      'লক',
  'will_sleep':
      'কম্পিউটার এখনই স্লিপে যাবে। আবার জাগাতে লাগবে: অন্য কম্পিউটার থেকে Wake-on-LAN, Cortex Wake, অথবা পাওয়ার বোতাম। Wi-Fi দিয়ে জাগানো সব কম্পিউটারে চলে না।',
  'will_hibernate':
      'কম্পিউটার সেশন সেভ করে বন্ধ হবে (হাইবারনেট)। জাগাতে সাধারণত পাওয়ার বোতাম লাগে; নেটওয়ার্ক দিয়ে জাগানো প্রায় চলে না।',
  'will_shutdown':
      'কম্পিউটার কিছুক্ষণ পরে (ডিফল্ট ৩০ সেকেন্ড) সম্পূর্ণ বন্ধ হবে। পরে ফোন থেকে জাগানো যাবে না (Wake-on-LAN বা Cortex Wake না থাকলে)। অসেভ কাজ হারাবে।',
  'will_restart':
      'কম্পিউটার কিছুক্ষণ পরে (ডিফল্ট ৩০ সেকেন্ড) রিস্টার্ট হবে। অসেভ কাজ হারাবে।',
  'power_confirm_btn':
      'হ্যাঁ, করুন',
  'auth_reason_power':
      'কম্পিউটারের পাওয়ার কমান্ড নিশ্চিত করতে আপনার পরিচয় যাচাই করুন',
  'auth_reason_pending':
      'অনুরোধটি নিশ্চিত করতে আপনার পরিচয় যাচাই করুন',
  'auth_failed':
      'পরিচয় যাচাই হয়নি, তাই কিছু করা হয়নি। ফোনে স্ক্রিন লক (পিন/ফিঙ্গারপ্রিন্ট) চালু আছে কিনা দেখুন।',
  'power_done':
      'পাঠানো হয়েছে',
  'act_sleep':
      'স্লিপ',
  'confirm_sleep':
      'স্লিপ নিশ্চিত করুন',
  'act_hibernate':
      'হাইবারনেট',
  'confirm_hibernate':
      'হাইবারনেট নিশ্চিত করুন',
  'wake_title':
      'কম্পিউটার জাগানোর উপায়',
  'wake_intro':
      'বন্ধ কম্পিউটার ফোনের কথা শুনতে পায় না। নিচের উপায়গুলো আলাদা সাহায্যকারী লাগে; কোনোটাই "জেগেছে" বলে নিশ্চিত করতে পারে না।',
  'wake_via':
      '{name}-এর মাধ্যমে জাগান',
  'wake_via_needs':
      'লাগবে: {name} চালু ও অনলাইন, একই বাসার নেটওয়ার্কে; এই কম্পিউটারের BIOS/ড্রাইভারে Wake-on-LAN চালু। স্লিপ থেকে মাঝে মাঝে চলে; পুরো বন্ধ বা হাইবারনেট থেকে সাধারণত শুধু তারের (Ethernet) সংযোগে।',
  'wake_gateway':
      'Cortex Wake (পাওয়ার বোতাম রোবট)',
  'wake_gateway_needs':
      'লাগবে: গেটওয়ে ফোনে ব্যাটারি, SIM-এ ব্যালেন্স ও সিগন্যাল, ESP32 + সার্ভো ঠিকমতো বসানো, ল্যাপটপে চার্জ। হার্ডওয়্যার পরীক্ষা করা হয়নি। টাচ বোতামে সার্ভো কাজ নাও করতে পারে।',
  'wake_sms':
      'SMS পাঠান',
  'wake_sms_needs':
      'লাগবে: গেটওয়ে ফোনের নম্বর (SMS ট্যাবে দিন)। SMS অ্যাপ খুলবে "ON " লেখা অবস্থায়; আপনি শেষে অথেনটিকেটরের ৬ অঙ্কের কোড নিজে লিখে পাঠাবেন। অ্যাপ কোডটি কখনো জানে না।',
  'wake_none':
      'কোনো জাগানোর উপায় সেট করা নেই। কম্পিউটারের তথ্য বদলে "যে কম্পিউটার জাগাবে" বা Cortex Wake দিন।',
  'wake_sent':
      'জাগানোর সংকেত পাঠানো হয়েছে। এক মিনিট পরে অবস্থা দেখুন; এটা নিশ্চিত করে না যে জেগেছে।',
  'wake_failed':
      'জাগানোর সংকেত যায়নি',
  'wake_online_already':
      'কম্পিউটার তো অনলাইনই আছে।',
  'wake_no_sms':
      'আগে SMS ট্যাবে গেটওয়ে ফোনের নম্বর দিন।',
  'wake_laptop_on':
      'সেন্সর বলছে ল্যাপটপ চালু আছে, তাই বোতাম চাপা হয়নি।',
  'wake_force_q':
      'ল্যাপটপের অবস্থা জানা নেই। তবুও পাওয়ার বোতাম চাপবেন? চালু ল্যাপটপে চাপলে স্লিপ বা শাটডাউন হতে পারে।',
  'computers_title':
      'আমার কম্পিউটার',
  'computers_add':
      'কম্পিউটার যোগ করুন',
  'computers_empty':
      'কোনো কম্পিউটার নেই',
  'computer_edit':
      'কম্পিউটারের তথ্য',
  'computer_name':
      'নাম',
  'computer_endpoints':
      'ঠিকানা (প্রথমটি আগে চেষ্টা হবে): Tailscale, তারপর LAN',
  'computer_endpoints_hint':
      'প্রতি লাইনে একটি, যেমন 100.64.0.9:8765',
  'computer_lan_ok':
      'এটা আমার নিজের বাসার নেটওয়ার্ক (LAN ঠিকানায় টোকেন এনক্রিপ্ট ছাড়া যায়, বুঝেছি)',
  'computer_wake_via':
      'যে কম্পিউটার একে জাগাবে',
  'computer_wake_via_none':
      'কেউ না',
  'computer_gateway_addr':
      'Cortex Wake গেটওয়ের ঠিকানা (ঐচ্ছিক)',
  'computer_gateway_token':
      'গেটওয়ের টোকেন (ঐচ্ছিক)',
  'computer_rustdesk_id':
      'RustDesk ID (পাসওয়ার্ড নয়)',
  'computer_remove_confirm':
      'এই কম্পিউটারটি এই ফোন থেকে সরাবেন?',
  'save':
      'সেভ',
  'server_lan_needs_ok':
      'এটি বাসার LAN ঠিকানা। সাধারণ http এনক্রিপ্ট করা নয়; নিজের বাসার নেটওয়ার্ক হলে নিচের ঘরে টিক দিন।',
  'pair_name_label':
      'কম্পিউটারের নাম (ঐচ্ছিক)',
  'pair_lan_label':
      'দ্বিতীয় ঠিকানা: বাসার LAN IP (ঐচ্ছিক)',
  'pair_more':
      'আরও অপশন',
  'switch_computer':
      'কম্পিউটার বদলান',
  'ds_title':
      'ডেটা-সেভার',
  'ds_auto':
      'স্বয়ংক্রিয়',
  'ds_on':
      'চালু',
  'ds_off':
      'বন্ধ',
  'ds_note':
      'চালু থাকলে স্ক্রিনশট ছোট (কম মান) আসে এবং নিজে নিজে রিফ্রেশ বন্ধ থাকে। স্বয়ংক্রিয় মানে ফোন SIM ডেটায় থাকলে চালু।',
  'ds_active':
      'ডেটা-সেভার এখন চালু',
  'voice_offline_title':
      'ইন্টারনেট ছাড়া ভয়েস',
  'voice_offline_body':
      'ইন্টারনেট না থাকলে ফোনের নিজস্ব স্পিচ রিকগনিশন লাগে। বাংলা অফলাইন প্যাক নামাতে: ফোনের Settings → Google → Settings for Google apps → Search, Assistant & Voice → Voice → Offline speech recognition → বাংলা (বাংলাদেশ) ডাউনলোড করুন। (মেনুর নাম ফোনভেদে একটু আলাদা হতে পারে।) বলা কথা বাক্সে আসবে; আপনি ঠিক করে নিজে "পাঠান" চাপবেন।',
  'voice_offline_pref':
      'অফলাইন স্পিচ ব্যবহার করুন',
  'voice_offline_help':
      'অফলাইন ভয়েস সেটআপ',
  'app_title': 'Cortex One',
  // pairing
  'pair_title': 'ল্যাপটপের সাথে যুক্ত করুন',
  'pair_help':
      'ল্যাপটপে PowerShell খুলে এই কমান্ড চালান:\npython -m agent.main pair\nযে ৬ অঙ্কের কোড আসবে সেটি নিচে লিখুন (৫ মিনিট বৈধ, একবারই চলে)।',
  'server_label': 'ল্যাপটপের ঠিকানা (Tailscale IP)',
  'server_hint': '100.x.y.z:8765',
  'code_label': '৬ অঙ্কের কোড',
  'pair_button': 'যুক্ত করুন',
  'pairing': 'যুক্ত হচ্ছে…',
  'server_invalid': 'ঠিকানা সঠিক নয়। উদাহরণ: 100.64.1.2:8765',
  'code_invalid': 'কোড অবশ্যই ৬টি অঙ্ক হতে হবে।',
  'pair_privacy': 'টোকেন শুধু এই ফোনের সুরক্ষিত স্টোরেজে (Keystore) থাকে।',
  // navigation
  'nav_home': 'হোম',
  'nav_pending': 'নিশ্চিতকরণ',
  'nav_audit': 'লগ',
  'nav_sms': 'SMS',
  // emergency
  'emergency_stop': 'জরুরি বন্ধ',
  'emergency_sub': 'চলমান সব কাজ থামান',
  'emergency_done': 'থামানো হয়েছে',
  // status
  'status_title': 'ল্যাপটপের অবস্থা',
  'status_refresh': 'রিফ্রেশ',
  'cpu': 'সিপিইউ',
  'ram': 'র‍্যাম',
  'disk': 'ডিস্ক',
  'battery': 'ব্যাটারি',
  'plugged': 'চার্জে আছে',
  'on_battery': 'ব্যাটারিতে',
  'uptime': 'চালু আছে',
  'free': 'ফাঁকা',
  'status_loading': 'অবস্থা দেখা হচ্ছে…',
  'hours_short': 'ঘণ্টা',
  'minutes_short': 'মিনিট',
  // command box
  'command_title': 'আদেশ দিন',
  'command_hint': 'যেমন: Downloads-এর PDF ফাইলগুলো দেখাও',
  'send': 'পাঠান',
  'mic_start': 'বলুন',
  'mic_stop': 'থামান',
  'listening': 'শুনছি…',
  'voice_unavailable':
      'এই ফোনে ভয়েস টাইপিং চালু করা যায়নি। মাইক্রোফোনের অনুমতি ও স্পিচ সার্ভিস দেখুন।',
  'voice_hint': 'বলা শেষ হলে লেখাটি ঠিক করে নিন, তারপর "পাঠান" চাপুন।',
  'voice_lang': 'ভয়েসের ভাষা',
  'steps': 'ধাপসমূহ',
  'reply': 'উত্তর',
  'task_running': 'কাজ চলছে…',
  'task_stopped': 'কাজ থেমে গেছে',
  'task_timeout': 'অনেক সময় লাগছে। পরে "লগ" দেখুন।',
  'waiting_confirm': 'আপনার নিশ্চিতকরণের অপেক্ষায়। অনুমতি ছাড়া কিছু চলবে না।',
  'go_pending': 'দেখুন',
  // quick actions
  'quick_title': 'দ্রুত কাজ',
  'q_lock': 'স্ক্রিন লক',
  'q_status': 'অবস্থা',
  'q_downloads': 'Downloads ফাইল',
  'q_apps': 'অ্যাপ খুলুন',
  'no_downloads': 'Downloads ফোল্ডার অনুমোদিত তালিকায় নেই।',
  'no_apps': 'কোনো অ্যাপ অনুমোদিত নেই।',
  'items_count': '{n}টি আইটেম',
  'folder_label': 'ফোল্ডার',
  'file_label': 'ফাইল',
  'ok': 'ঠিক আছে',
  // pending confirmations
  'pending_title': 'নিশ্চিতকরণের অপেক্ষায়',
  'pending_empty': 'এখন কোনো অনুরোধ অপেক্ষায় নেই।',
  'pending_note':
      'AI নিজে এগুলো চালাতে পারে না। আপনি নিশ্চিত না করলে কিছুই হবে না।',
  'act_shutdown': 'ল্যাপটপ বন্ধ করা',
  'act_restart': 'ল্যাপটপ রিস্টার্ট করা',
  'act_run_script': 'স্ক্রিপ্ট চালানো',
  'act_other': 'অনুরোধ',
  'will_run': 'ঠিক যা চালানো হবে:',
  'script_label': 'স্ক্রিপ্ট',
  'save_work_note':
      'আগে খোলা কাজ সেভ করুন। কনফার্মের পর কিছুক্ষণের মধ্যে কাজ শুরু হবে।',
  'confirm_shutdown': 'হ্যাঁ, বন্ধ করুন',
  'confirm_restart': 'হ্যাঁ, রিস্টার্ট করুন',
  'confirm_run_script': 'হ্যাঁ, স্ক্রিপ্ট চালান',
  'confirm_default': 'নিশ্চিত করুন',
  'cancel': 'বাতিল',
  'expires_in': 'মেয়াদ বাকি: {n} সেকেন্ড',
  'expired': 'মেয়াদ শেষ',
  'confirmed_msg': 'নিশ্চিত করা হয়েছে',
  'cancelled_msg': 'বাতিল করা হয়েছে',
  // audit
  'audit_title': 'কাজের লগ (শুধু দেখা যায়)',
  'audit_empty': 'এখনো কোনো লগ নেই।',
  // SMS help
  'sms_title': 'ইন্টারনেট ছাড়া (SMS)',
  'sms_intro':
      'ইন্টারনেট বা Tailscale না থাকলে ল্যাপটপের গেটওয়ে ফোনে SMS পাঠিয়ে ছোট কমান্ড দিতে পারেন। প্রথমে STATUS দিয়ে পরীক্ষা করুন।',
  'sms_format': 'ফরম্যাট: কমান্ড, স্পেস, পিন। যেমন: STATUS 1234',
  'sms_number_label': 'গেটওয়ে ফোনের নম্বর',
  'sms_number_hint': '+8801XXXXXXXXX',
  'sms_number_invalid': 'নম্বর সঠিক নয়।',
  'sms_command': 'কমান্ড',
  'sms_open': 'SMS অ্যাপ খুলুন',
  'sms_pin_note': 'পিন আপনি নিজে টাইপ করবেন। অ্যাপ পিন কোথাও জমা রাখে না।',
  'sms_warn':
      'সতর্কতা: SMS-এ পুরনো মেসেজ আবার পাঠানো ঠেকানো যায় না। পিন গোপন রাখুন।',
  'sms_cannot_open': 'SMS অ্যাপ খোলা যায়নি।',
  'c_STATUS': 'অবস্থা জানুন',
  'c_LOCK': 'স্ক্রিন লক',
  'c_SHUTDOWN': 'বন্ধ করুন',
  'c_RESTART': 'রিস্টার্ট',
  'c_CANCEL': 'বন্ধ/রিস্টার্ট বাতিল',
  'c_STOP': 'জরুরি বন্ধ',
  // settings
  'language': 'ভাষা',
  'theme': 'থিম',
  'theme_system': 'ফোনের মতো',
  'theme_light': 'আলো',
  'theme_dark': 'অন্ধকার',
  'unpair': 'এই ফোন সরান',
  'unpair_confirm':
      'এই ফোনের পেয়ারিং মুছবেন? ল্যাপটপ থেকেও পুরোপুরি বাতিল করতে সেখানে "revoke" কমান্ড চালান।',
  'yes': 'হ্যাঁ',
  'no': 'না',
  // errors
  'err_network':
      'ল্যাপটপের সাথে যোগাযোগ হয়নি। ল্যাপটপ চালু আছে কিনা, এজেন্ট চলছে কিনা এবং দুই জায়গাতেই Tailscale চালু আছে কিনা দেখুন।',
  'err_timeout':
      'ল্যাপটপ সাড়া দিচ্ছে না (সময় শেষ)। একটু পরে আবার চেষ্টা করুন।',
  'err_unauthorized':
      'এই ফোনের অনুমতি নেই, মেয়াদ শেষ বা বাতিল হয়ে গেছে। আবার যুক্ত করুন।',
  'err_forbidden': 'কোড বা নিশ্চিতকরণ ভুল, মেয়াদ শেষ, বা আগেই ব্যবহার হয়েছে।',
  'err_notfound': 'এটি আর পাওয়া যাচ্ছে না (হয়তো মেয়াদ শেষ)।',
  'err_invalid': 'পাঠানো তথ্য ঠিক নয়। লেখাটি ছোট করে আবার চেষ্টা করুন।',
  'err_rate':
      'অনেক বেশি অনুরোধ হয়েছে বা কিছুক্ষণের জন্য আটকানো হয়েছে। কিছুক্ষণ পরে চেষ্টা করুন।',
  'err_unavailable': 'এই মুহূর্তে কাজটি করা যাচ্ছে না।',
  'err_server': 'ল্যাপটপের এজেন্টে সমস্যা হয়েছে। লগ দেখুন।',
  'err_bad':
      'ল্যাপটপ থেকে অদ্ভুত উত্তর এসেছে। অ্যাপ ও এজেন্টের ভার্সন মিলিয়ে দেখুন।',
  'err_unknown': 'কিছু একটা ভুল হয়েছে। আবার চেষ্টা করুন।',
  // screen viewer
  'nav_screen': 'স্ক্রিন',
  'screen_title': 'ল্যাপটপের স্ক্রিন (শুধু দেখা)',
  'screen_refresh': 'রিফ্রেশ',
  'screen_taking': 'স্ক্রিনশট নেওয়া হচ্ছে…',
  'screen_empty': 'এখনো কোনো ছবি নেই। "রিফ্রেশ" চাপুন।',
  'screen_auto': 'নিজে নিজে রিফ্রেশ',
  'screen_auto_every': 'প্রতি',
  'screen_seconds': 'সেকেন্ড',
  'screen_data_note':
      'প্রতিবার একটি ছোট ছবি ডাউনলোড হয় (সাধারণত ২০০–৮০০ KB)। অটো-রিফ্রেশ চালু থাকলে মোবাইল ডেটা খরচ হবে; Wi-Fi ছাড়া দরকার না হলে বন্ধ রাখুন।',
  'screen_view_only': 'শুধু দেখা যায়; স্পর্শ বা কন্ট্রোল নেই। দুই আঙুলে জুম করুন।',
  'screen_taken_at': 'তোলা হয়েছে',
  'screen_compressed': 'ছোট করা ছবি (দ্রুত)',
  'screen_original': 'আসল ছবি (Pillow নেই)',
  // watch
  'watch_title': 'কোডিং এজেন্ট ওয়াচ',
  'watch_open': 'ওয়াচ',
  'watch_empty': 'কোনো ওয়াচ রুল নেই। config.json-এ watch_rules যোগ করুন।',
  'watch_problems': 'কনফিগে সমস্যা আছে (doctor চালান)',
  'watch_recent': 'সাম্প্রতিক সতর্কতা',
  'watch_no_alerts': 'এখনো কোনো সতর্কতা নেই।',
  'watch_kind_process_exit': 'প্রোগ্রাম বন্ধ হলে',
  'watch_kind_log_stalled': 'লগ থেমে গেলে ({n} মিনিট)',
  'watch_kind_log_pattern': 'লগে নির্দিষ্ট লেখা এলে',
  'watch_state_running': 'চলছে',
  'watch_state_waiting': 'অপেক্ষায়',
  'watch_state_exited': 'বন্ধ হয়েছে',
  'watch_state_active': 'সক্রিয়',
  'watch_state_stalled': 'থেমে আছে',
  'watch_state_clear': 'ঠিক আছে',
  'watch_state_matched': 'লেখা পাওয়া গেছে',
  'watch_state_missing': 'ফাইল নেই',
  'watch_state_error': 'ত্রুটি',
  // alerts
  'alerts_title': 'বিদ্যুৎ ও ব্যাটারি সতর্কতা',
  'alerts_empty': 'এখনো কোনো সতর্কতা নেই।',
  'alerts_open': 'সতর্কতা দেখুন',
  'alert_ac_lost': 'কারেন্ট গেছে, ব্যাটারিতে চলছে',
  'alert_ac_restored': 'কারেন্ট ফিরেছে, চার্জ হচ্ছে',
  'alert_battery_warn': 'ব্যাটারি কমে গেছে',
  'alert_battery_critical': 'ব্যাটারি খুবই কম',
  'alert_critical_action': 'ব্যাটারি শেষের দিকে: নিরাপত্তা-পদক্ষেপ নেওয়া হয়েছে',
  'alert_banner_hint': 'ল্যাপটপ কারেন্ট ছাড়া চলছে বা ব্যাটারি কম।',
  // clearer connection errors
  'server_not_private':
      'http শুধু Tailscale ঠিকানায় (100.x বা *.ts.net) চলবে; অন্য Wi-Fi-তে কেউ টোকেন দেখে ফেলতে পারে। অন্য ঠিকানায় https লাগবে।',
  'err_pair_wrong_address':
      'এই ঠিকানায় Cortex One এজেন্ট পাওয়া যায়নি। IP ও পোর্ট (ডিফল্ট 8765) আবার দেখুন; ল্যাপটপে `tailscale ip -4` চালান।',
  'err_pair_offline':
      'ল্যাপটপ পর্যন্ত পৌঁছানো যায়নি। ঠিকানা ঠিক আছে কিনা, ল্যাপটপ চালু ও এজেন্ট চলছে কিনা, আর দুই জায়গাতেই Tailscale চালু কিনা দেখুন।',
  'err_pair_code':
      'পেয়ারিং কোড ভুল বা মেয়াদ শেষ। ল্যাপটপে আবার `python -m agent.main pair` চালিয়ে নতুন কোড নিন।',
  'err_pair_locked':
      'ভুল কোড বেশি বার দেওয়ায় পেয়ারিং ৫ মিনিটের জন্য আটকানো। একটু পরে নতুন কোড নিয়ে চেষ্টা করুন।',
};

const Map<String, String> _en = {
  'answered_by':
      'Answered by: {m}',
  'answered_local':
      'No internet, so the computer\'s local model ({m}) answered. It can only read, and a small model can be wrong.',
  'gui_title':
      'GUI session (the AI operates the mouse and keyboard)',
  'gui_note':
      'UNVERIFIED: this has never been run on a real screen. The AI can click and type only in a time-limited session you approve, and only while an approved app is in front. Bank, password and login windows are blocked, but that list is weak protection. Text on the screen is data to the AI, never instructions.',
  'gui_off':
      'GUI mode is off (gui_agent.enabled in the laptop\'s config.json).',
  'gui_minutes':
      'Minutes',
  'gui_start':
      'Start a GUI session',
  'will_gui_start':
      'The AI will be able to operate this computer\'s mouse and keyboard for {n} minute(s), only while an approved app is in front. Press STOP any time; emergency stop also ends it. Unverified.',
  'gui_open':
      'View the running session',
  'gui_screen_title':
      'GUI session',
  'gui_stop':
      'STOP',
  'gui_active':
      'Session is running',
  'gui_ended':
      'Session ended',
  'gui_remaining':
      'Time left: {t}',
  'gui_actions_used':
      'Actions: {n}/{m}',
  'gui_no_shot':
      'No picture yet',
  'gui_actions_title':
      'Recent actions',
  'gui_reason':
      'Why it ended: {r}',
  'act_gui_session_start':
      'Start GUI session',
  'confirm_gui_session_start':
      'Confirm GUI session start',
  'tools_title':
      'Coding sessions and remote desktop',
  'coding_title':
      'Coding sessions',
  'coding_refresh':
      'Show the list',
  'coding_none':
      'No coding projects are set up (coding_projects in config.json).',
  'coding_start':
      'Start',
  'coding_stop':
      'Stop',
  'coding_state_running':
      'running',
  'coding_state_exited':
      'ended (code {c})',
  'coding_state_not started':
      'not started',
  'will_coding_start':
      'Project "{name}" will start: the program the owner chose opens in that folder. What runs is fixed in the laptop\'s config.json and cannot be changed from here.',
  'will_coding_stop':
      'The session of project "{name}" (and the programs it started) will be stopped. Unsaved work may be lost.',
  'rd_title':
      'Remote desktop (RustDesk)',
  'rd_note':
      'RustDesk is a separate app: it shows the screen and takes touch. Cortex One only checks whether it is running, starts it, and opens the app. The RustDesk password is never read or stored. Pictures use a lot of data on a SIM.',
  'rd_open':
      'Open RustDesk',
  'rd_status':
      'Is it running on the computer?',
  'rd_start':
      'Start RustDesk on the computer',
  'rd_need_id':
      'First enter the RustDesk ID in the computer details.',
  'rd_open_failed':
      'Could not open the RustDesk app. Check that RustDesk is installed on this phone.',
  'will_remote_start':
      'RustDesk will start on the computer. While it runs, anyone who knows your RustDesk password can get in, so keep a strong permanent password and 2FA.',
  'p_remote_start':
      'Start RustDesk',
  'confirm_coding_start':
      'Confirm coding session start',
  'act_coding_session_start':
      'Start coding session',
  'confirm_coding_session_start':
      'Confirm coding session start',
  'act_coding_session_stop':
      'Stop coding session',
  'confirm_coding_session_stop':
      'Confirm coding session stop',
  'act_remote_desktop_start':
      'Start RustDesk',
  'confirm_remote_desktop_start':
      'Confirm RustDesk start',
  'attach_gallery':
      'Picture from gallery',
  'attach_camera':
      'Camera',
  'attach_count':
      'Pictures: {n}/3',
  'attach_note':
      'Pictures are shrunk and cleaned of location/camera data (EXIF) before sending. Text inside a picture is only read, never obeyed.',
  'image_failed':
      'The picture could not be read or prepared. Try another one.',
  'image_too_big':
      'The picture is still over 1.5 MB after shrinking. Try another or a simpler one.',
  'gw_menu':
      'Cortex Wake gateway (this phone with the power-button robot)',
  'gw_title':
      'Cortex Wake gateway',
  'gw_why':
      'In this mode this phone (with a SIM, kept on a charger) listens for "ON <code>" SMS from your allowed numbers and tells the ESP32 over Bluetooth to press the power button. So the app needs: read SMS (RECEIVE_SMS), send one short reply (SEND_SMS), Bluetooth, and a visible notification to keep running. SMS from numbers not on your list get no reply, and SMS text is never stored. Not proven: the hardware is untested; it will not work if this phone has no battery, balance or signal, or if the laptop battery is empty.',
  'gw_perm_btn':
      'Grant permissions',
  'gw_perm_ok':
      'All permissions granted',
  'gw_perm_missing':
      'Permissions missing',
  'gw_perm_denied':
      'Permissions were not granted, so the gateway cannot start.',
  'gw_numbers_label':
      'Allowed numbers (one per line)',
  'gw_numbers_invalid':
      'A number is not valid. Example: 01711111111 or +8801711111111',
  'gw_bind_label':
      'This phone\'s Tailscale address (to use it over the internet; optional)',
  'gw_bind_invalid':
      'Only 127.x, Tailscale (100.64-127.x) or a home LAN address; never 0.0.0.0.',
  'gw_create':
      'Create new keys',
  'gw_create_warn':
      'New keys replace the old ones. You must put the new key into the ESP32 and flash it again, and enter the new secret in your authenticator.',
  'gw_secrets_title':
      'These keys are shown only now, once',
  'gw_secrets_once':
      'Write them down (on paper). The app will not show them again and never logs or sends them.',
  'gw_secret_wake':
      'Wake secret (add to an authenticator app as a time-based key; different from the laptop agent\'s SMS secret)',
  'gw_secret_fw':
      'Firmware key (put into firmware/cortex-wake/include/secrets.h)',
  'gw_secret_token':
      'HTTP token (enter it as "gateway token" in the computer settings)',
  'gw_done':
      'I wrote them down',
  'gw_start':
      'Start gateway',
  'gw_stop':
      'Stop gateway',
  'gw_running':
      'Gateway is running',
  'gw_stopped':
      'Gateway is off',
  'gw_need_setup':
      'First enter numbers and create the keys.',
  'gw_save':
      'Save',
  'gw_saved':
      'Saved',
  'gw_log_title':
      'Recent events (no codes, SMS text or full numbers)',
  'gw_log_empty':
      'Nothing yet',
  'state_online':
      'Online',
  'state_sleeping':
      'Probably asleep',
  'state_offline':
      'Offline',
  'state_unknown':
      'Unknown',
  'reason_sleep':
      'You put it to sleep at {t}, and it has not answered since. The phone cannot tell sleep from a dead network.',
  'reason_hibernate':
      'You hibernated it at {t}, and it has not answered since.',
  'reason_shutdown':
      'You shut it down at {t}. A computer that is off cannot be woken from the phone alone.',
  'reason_restart':
      'It may be restarting ({t}). Wait a few minutes.',
  'reason_battery':
      'Last time its battery was very low and not charging: it has probably run out and switched off.',
  'reason_noanswer':
      'Not answering: asleep, off, or a network/Tailscale problem. The phone cannot tell which.',
  'reason_never':
      'This phone has never heard from it yet.',
  'last_seen':
      'Last seen: {t}',
  'seen_never':
      'Never seen',
  'battery_line':
      'Battery {p}% ({c})',
  'link_tailscale':
      'Link: Tailscale',
  'link_lan':
      'Link: home Wi-Fi (LAN)',
  'link_sim':
      'Link: SIM mobile data (data-saver)',
  'link_none':
      'Link: not connected yet',
  'power_title':
      'Power',
  'power_note':
      'Risky buttons first show exactly what will happen, then ask for your fingerprint or phone PIN.',
  'p_wake':
      'Wake',
  'p_sleep':
      'Sleep',
  'p_hibernate':
      'Hibernate',
  'p_shutdown':
      'Shut down',
  'p_restart':
      'Restart',
  'p_lock':
      'Lock',
  'will_sleep':
      'The computer goes to sleep right now. To wake it again you need: Wake-on-LAN from another computer, Cortex Wake, or its power button. Waking over Wi-Fi does not work on every computer.',
  'will_hibernate':
      'The computer saves its session and powers down (hibernate). Waking it normally needs the power button; waking over the network almost never works.',
  'will_shutdown':
      'The computer shuts down completely after a short delay (30 seconds by default). You cannot wake it from the phone afterwards (unless you have Wake-on-LAN or Cortex Wake). Unsaved work is lost.',
  'will_restart':
      'The computer restarts after a short delay (30 seconds by default). Unsaved work is lost.',
  'power_confirm_btn':
      'Yes, do it',
  'auth_reason_power':
      'Verify it is you to confirm this power command',
  'auth_reason_pending':
      'Verify it is you to confirm this request',
  'auth_failed':
      'Identity was not verified, so nothing was done. Check that the phone has a screen lock (PIN/fingerprint).',
  'power_done':
      'Sent',
  'act_sleep':
      'Sleep',
  'confirm_sleep':
      'Confirm sleep',
  'act_hibernate':
      'Hibernate',
  'confirm_hibernate':
      'Confirm hibernate',
  'wake_title':
      'Ways to wake the computer',
  'wake_intro':
      'A computer that is off cannot hear the phone. Each way below needs a separate helper, and none can confirm that it really woke up.',
  'wake_via':
      'Wake via {name}',
  'wake_via_needs':
      'Needs: {name} is on and online, on the same home network; Wake-on-LAN enabled in this computer\'s BIOS/driver. It sometimes works from Sleep; from full shutdown or hibernate it usually only works on a wired (Ethernet) connection.',
  'wake_gateway':
      'Cortex Wake (power-button robot)',
  'wake_gateway_needs':
      'Needs: the gateway phone has battery, the SIM has balance and signal, the ESP32 + servo are mounted correctly, and the laptop battery has charge. Untested hardware. A touch power button may not work with a servo.',
  'wake_sms':
      'Send an SMS',
  'wake_sms_needs':
      'Needs: the gateway phone\'s number (set it on the SMS tab). The SMS app opens with "ON " typed; you add the 6-digit authenticator code yourself and send. The app never knows the code.',
  'wake_none':
      'No wake method is set up. Edit the computer and add "wake via" or Cortex Wake.',
  'wake_sent':
      'Wake signal sent. Check the status in a minute; this does not prove it woke up.',
  'wake_failed':
      'The wake signal did not go through',
  'wake_online_already':
      'The computer is already online.',
  'wake_no_sms':
      'First enter the gateway phone number on the SMS tab.',
  'wake_laptop_on':
      'The sensor says the laptop is ON, so the button was not pressed.',
  'wake_force_q':
      'The laptop state is unknown. Press the power button anyway? On a running laptop this may sleep or shut it down.',
  'computers_title':
      'My computers',
  'computers_add':
      'Add a computer',
  'computers_empty':
      'No computers yet',
  'computer_edit':
      'Computer details',
  'computer_name':
      'Name',
  'computer_endpoints':
      'Addresses (tried in order): Tailscale first, then LAN',
  'computer_endpoints_hint':
      'one per line, e.g. 100.64.0.9:8765',
  'computer_lan_ok':
      'This is my own home network (a LAN address sends the token unencrypted; I understand)',
  'computer_wake_via':
      'Computer that wakes this one',
  'computer_wake_via_none':
      'None',
  'computer_gateway_addr':
      'Cortex Wake gateway address (optional)',
  'computer_gateway_token':
      'Gateway token (optional)',
  'computer_rustdesk_id':
      'RustDesk ID (never the password)',
  'computer_remove_confirm':
      'Remove this computer from this phone?',
  'save':
      'Save',
  'server_lan_needs_ok':
      'That is a home-LAN address. Plain http is not encrypted: tick the box below only if it is your own network.',
  'pair_name_label':
      'Computer name (optional)',
  'pair_lan_label':
      'Second address: home LAN IP (optional)',
  'pair_more':
      'More options',
  'switch_computer':
      'Switch computer',
  'ds_title':
      'Data saver',
  'ds_auto':
      'Auto',
  'ds_on':
      'On',
  'ds_off':
      'Off',
  'ds_note':
      'When on, screenshots arrive small (low quality) and automatic refresh stops. Auto means on while the phone is on SIM mobile data.',
  'ds_active':
      'Data saver is on',
  'voice_offline_title':
      'Voice without internet',
  'voice_offline_body':
      'Without internet the phone\'s own speech recognition is needed. To get the Bangla offline pack: phone Settings → Google → Settings for Google apps → Search, Assistant & Voice → Voice → Offline speech recognition → download Bengali (Bangladesh). (Menu names differ a little between phones.) Spoken words appear in the box; you edit them and press Send yourself.',
  'voice_offline_pref':
      'Use offline speech',
  'voice_offline_help':
      'Offline voice setup',
  'app_title': 'Cortex One',
  'pair_title': 'Connect to your laptop',
  'pair_help':
      'On the laptop, open PowerShell and run:\npython -m agent.main pair\nEnter the 6-digit code below (valid 5 minutes, one use).',
  'server_label': 'Laptop address (Tailscale IP)',
  'server_hint': '100.x.y.z:8765',
  'code_label': '6-digit code',
  'pair_button': 'Connect',
  'pairing': 'Connecting…',
  'server_invalid': 'That address is not valid. Example: 100.64.1.2:8765',
  'code_invalid': 'The code must be exactly 6 digits.',
  'pair_privacy':
      'The token is kept only in this phone\'s secure storage (Keystore).',
  'nav_home': 'Home',
  'nav_pending': 'Confirm',
  'nav_audit': 'Log',
  'nav_sms': 'SMS',
  'emergency_stop': 'EMERGENCY STOP',
  'emergency_sub': 'Stop everything that is running',
  'emergency_done': 'Stopped',
  'status_title': 'Laptop status',
  'status_refresh': 'Refresh',
  'cpu': 'CPU',
  'ram': 'RAM',
  'disk': 'Disk',
  'battery': 'Battery',
  'plugged': 'plugged in',
  'on_battery': 'on battery',
  'uptime': 'Up for',
  'free': 'free',
  'status_loading': 'Checking status…',
  'hours_short': 'h',
  'minutes_short': 'min',
  'command_title': 'Give a command',
  'command_hint': 'e.g. Show the PDF files in Downloads',
  'send': 'Send',
  'mic_start': 'Speak',
  'mic_stop': 'Stop',
  'listening': 'Listening…',
  'voice_unavailable':
      'Voice typing could not be started on this phone. Check the microphone permission and speech service.',
  'voice_hint':
      'When you finish speaking, fix the text if needed, then press "Send".',
  'voice_lang': 'Voice language',
  'steps': 'Steps',
  'reply': 'Reply',
  'task_running': 'Working…',
  'task_stopped': 'Task stopped',
  'task_timeout': 'This is taking long. Check the "Log" tab later.',
  'waiting_confirm': 'Waiting for your confirmation. Nothing runs without it.',
  'go_pending': 'Open',
  'quick_title': 'Quick actions',
  'q_lock': 'Lock screen',
  'q_status': 'Status',
  'q_downloads': 'Downloads files',
  'q_apps': 'Open an app',
  'no_downloads': 'The Downloads folder is not in the allowed list.',
  'no_apps': 'No apps are approved.',
  'items_count': '{n} item(s)',
  'folder_label': 'folder',
  'file_label': 'file',
  'ok': 'OK',
  'pending_title': 'Waiting for confirmation',
  'pending_empty': 'Nothing is waiting right now.',
  'pending_note':
      'The AI cannot run these itself. Nothing happens unless you confirm.',
  'act_shutdown': 'Shut down the laptop',
  'act_restart': 'Restart the laptop',
  'act_run_script': 'Run a script',
  'act_other': 'Request',
  'will_run': 'Exactly what will run:',
  'script_label': 'Script',
  'save_work_note':
      'Save your open work first. It starts shortly after you confirm.',
  'confirm_shutdown': 'Yes, shut down',
  'confirm_restart': 'Yes, restart',
  'confirm_run_script': 'Yes, run the script',
  'confirm_default': 'Confirm',
  'cancel': 'Cancel',
  'expires_in': 'Expires in {n} s',
  'expired': 'Expired',
  'confirmed_msg': 'Confirmed',
  'cancelled_msg': 'Cancelled',
  'audit_title': 'Activity log (read-only)',
  'audit_empty': 'No entries yet.',
  'sms_title': 'Offline (SMS)',
  'sms_intro':
      'Without internet or Tailscale you can text short commands to the laptop\'s gateway phone. Test with STATUS first.',
  'sms_format': 'Format: command, space, PIN. Example: STATUS 1234',
  'sms_number_label': 'Gateway phone number',
  'sms_number_hint': '+8801XXXXXXXXX',
  'sms_number_invalid': 'That number is not valid.',
  'sms_command': 'Command',
  'sms_open': 'Open SMS app',
  'sms_pin_note': 'You type the PIN yourself. This app never stores it.',
  'sms_warn':
      'Warning: SMS cannot stop an old message from being replayed. Keep the PIN secret.',
  'sms_cannot_open': 'Could not open the SMS app.',
  'c_STATUS': 'Get status',
  'c_LOCK': 'Lock screen',
  'c_SHUTDOWN': 'Shut down',
  'c_RESTART': 'Restart',
  'c_CANCEL': 'Cancel shutdown/restart',
  'c_STOP': 'Emergency stop',
  'language': 'Language',
  'theme': 'Theme',
  'theme_system': 'Like phone',
  'theme_light': 'Light',
  'theme_dark': 'Dark',
  'unpair': 'Remove this phone',
  'unpair_confirm':
      'Remove pairing from this phone? To fully revoke it, also run "revoke" on the laptop.',
  'yes': 'Yes',
  'no': 'No',
  'err_network':
      'Could not reach the laptop. Check that it is on, the agent is running, and Tailscale is on for both.',
  'err_timeout': 'The laptop is not answering (timed out). Try again shortly.',
  'err_unauthorized':
      'This phone is not authorised, or its permission expired or was revoked. Pair it again.',
  'err_forbidden':
      'The code or confirmation is wrong, expired, or already used.',
  'err_notfound': 'That is no longer available (it may have expired).',
  'err_invalid':
      'The request was not accepted. Shorten the text and try again.',
  'err_rate':
      'Too many requests, or temporarily blocked. Try again in a little while.',
  'err_unavailable': 'This cannot be done right now.',
  'err_server': 'The laptop agent had a problem. Check the log.',
  'err_bad':
      'The laptop sent an unexpected answer. Check app and agent versions match.',
  'err_unknown': 'Something went wrong. Please try again.',
  // screen viewer
  'nav_screen': 'Screen',
  'screen_title': 'Laptop screen (view only)',
  'screen_refresh': 'Refresh',
  'screen_taking': 'Taking a screenshot…',
  'screen_empty': 'No picture yet. Tap "Refresh".',
  'screen_auto': 'Auto-refresh',
  'screen_auto_every': 'Every',
  'screen_seconds': 'seconds',
  'screen_data_note':
      'Each refresh downloads one small picture (usually 200–800 KB). With auto-refresh on this uses mobile data; keep it off away from Wi-Fi unless you need it.',
  'screen_view_only': 'View only; no touch or control. Pinch with two fingers to zoom.',
  'screen_taken_at': 'Taken at',
  'screen_compressed': 'Compressed picture (fast)',
  'screen_original': 'Original picture (Pillow not installed)',
  // watch
  'watch_title': 'Coding agent watch',
  'watch_open': 'Watch',
  'watch_empty': 'No watch rules. Add watch_rules to config.json.',
  'watch_problems': 'The config has problems (run doctor)',
  'watch_recent': 'Recent alerts',
  'watch_no_alerts': 'No alerts yet.',
  'watch_kind_process_exit': 'When the program exits',
  'watch_kind_log_stalled': 'When the log is silent ({n} min)',
  'watch_kind_log_pattern': 'When the log shows watched text',
  'watch_state_running': 'Running',
  'watch_state_waiting': 'Waiting',
  'watch_state_exited': 'Exited',
  'watch_state_active': 'Active',
  'watch_state_stalled': 'Stalled',
  'watch_state_clear': 'OK',
  'watch_state_matched': 'Text found',
  'watch_state_missing': 'File missing',
  'watch_state_error': 'Error',
  // alerts
  'alerts_title': 'Power & battery alerts',
  'alerts_empty': 'No alerts yet.',
  'alerts_open': 'See alerts',
  'alert_ac_lost': 'Power cut: running on battery',
  'alert_ac_restored': 'Power is back: charging',
  'alert_battery_warn': 'Battery is getting low',
  'alert_battery_critical': 'Battery is critically low',
  'alert_critical_action': 'Battery nearly empty: a safety step was taken',
  'alert_banner_hint': 'The laptop is off mains power or the battery is low.',
  // clearer connection errors
  'server_not_private':
      'Plain http is only accepted for Tailscale addresses (100.x or *.ts.net); on other Wi-Fi someone could read the token. Any other address needs https.',
  'err_pair_wrong_address':
      'No Cortex One agent answered at this address. Check the IP and port (default 8765); run `tailscale ip -4` on the laptop.',
  'err_pair_offline':
      'Could not reach the laptop. Check the address, that the laptop is on and the agent is running, and that Tailscale is on for both.',
  'err_pair_code':
      'The pairing code is wrong or expired. Run `python -m agent.main pair` on the laptop again for a fresh code.',
  'err_pair_locked':
      'Too many wrong codes, so pairing is blocked for 5 minutes. Wait a little, then try with a new code.',
};
