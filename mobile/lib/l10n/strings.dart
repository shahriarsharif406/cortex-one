import '../api/api_client.dart';

/// Bangla-first strings with an English toggle. Missing keys fall back to the key
/// itself; a unit test checks both languages have exactly the same keys.
class S {
  const S(this.lang);

  final String lang; // 'bn' | 'en'

  bool get isBangla => lang != 'en';

  String t(String key) => (isBangla ? _bn[key] : _en[key]) ?? _en[key] ?? key;

  /// `{n}`-style placeholders.
  String tf(String key, Map<String, Object> values) {
    var text = t(key);
    values.forEach((k, v) => text = text.replaceAll('{$k}', '$v'));
    return text;
  }

  /// Clear, plain error text for the user (never a stack trace).
  String error(Object error) {
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
      // The agent's own message explains e.g. "ANTHROPIC_API_KEY is empty".
      return error.kind == ApiErrorKind.unavailable && error.detail.isNotEmpty
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
