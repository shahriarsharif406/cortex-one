import 'package:flutter/material.dart';

import '../state/app_state.dart';

const smsCommands = ['STATUS', 'LOCK', 'SHUTDOWN', 'RESTART', 'CANCEL', 'STOP'];

/// The sms: link for a command. The PIN is NOT included: the owner types it
/// in the SMS app, and this app never sees or stores it.
Uri smsUri(String number, String command) =>
    Uri.parse('sms:$number?body=${Uri.encodeComponent('$command ')}');

bool isValidPhoneNumber(String raw) =>
    RegExp(r'^\+?\d{6,15}$').hasMatch(raw.replaceAll(RegExp(r'[\s-]'), ''));

/// Offline help: how to command the laptop by SMS when there is no internet.
class SmsHelpScreen extends StatefulWidget {
  const SmsHelpScreen({super.key});

  @override
  State<SmsHelpScreen> createState() => _SmsHelpScreenState();
}

class _SmsHelpScreenState extends State<SmsHelpScreen> {
  final _number = TextEditingController();
  String _command = 'STATUS';
  String? _error;
  bool _loadedNumber = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedNumber) {
      _loadedNumber = true;
      // The gateway phone number is not a secret; it is the only thing remembered here.
      AppScope.of(context).prefs.get('sms_number').then((v) {
        if (v != null && mounted && _number.text.isEmpty) _number.text = v;
      });
    }
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final app = AppScope.of(context);
    final raw = _number.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!isValidPhoneNumber(raw)) {
      setState(() => _error = app.s.t('sms_number_invalid'));
      return;
    }
    setState(() => _error = null);
    await app.prefs.set('sms_number', raw);
    final ok = await app.launchUri(smsUri(raw, _command));
    if (!ok && mounted) setState(() => _error = app.s.t('sms_cannot_open'));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(s.t('sms_title'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(s.t('sms_intro')),
        const SizedBox(height: 8),
        Text(
          s.t('sms_format'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        for (final c in smsCommands)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sms_outlined),
            title: Text(
              '$c  <PIN>',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            subtitle: Text(s.t('c_$c')),
          ),
        const Divider(),
        TextField(
          key: const Key('sms_number_field'),
          controller: _number,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: s.t('sms_number_label'),
            hintText: s.t('sms_number_hint'),
            border: const OutlineInputBorder(),
            errorText: _error,
          ),
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: InputDecoration(
            labelText: s.t('sms_command'),
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const Key('sms_command_dropdown'),
              value: _command,
              isDense: true,
              isExpanded: true,
              items: [
                for (final c in smsCommands)
                  DropdownMenuItem(
                    value: c,
                    child: Text('$c — ${s.t('c_$c')}'),
                  ),
              ],
              onChanged: (v) => setState(() => _command = v ?? 'STATUS'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('sms_open_button'),
          onPressed: _open,
          icon: const Icon(Icons.sms),
          label: Text(s.t('sms_open')),
        ),
        const SizedBox(height: 12),
        Text(
          s.t('sms_pin_note'),
          key: const Key('sms_pin_note'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(s.t('sms_warn'), style: TextStyle(color: scheme.error)),
      ],
    );
  }
}
