import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../widgets/settings_menu.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _server = TextEditingController();
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = AppScope.of(context);
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.pair(_server.text, _code.text.trim());
    } on InvalidServerAddress {
      if (mounted) setState(() => _error = app.s.t('server_invalid'));
    } catch (e) {
      if (mounted) setState(() => _error = app.s.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('pair_title')),
        actions: const [SettingsMenu(showUnpair: false)],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (app.notice != null)
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(s.t(app.notice!), key: const Key('pair_notice')),
                ),
              ),
            Text(
              s.t('pair_help'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            Form(
              key: _form,
              child: Column(
                children: [
                  TextFormField(
                    key: const Key('server_field'),
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: s.t('server_label'),
                      hintText: s.t('server_hint'),
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? s.t('server_invalid')
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('code_field'),
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 24, letterSpacing: 6),
                    decoration: InputDecoration(
                      labelText: s.t('code_label'),
                      counterText: '',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        RegExp(r'^\d{6}$').hasMatch((v ?? '').trim())
                        ? null
                        : s.t('code_invalid'),
                    onFieldSubmitted: (_) => _submit(),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('pair_error'),
                style: TextStyle(color: scheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('pair_button'),
              onPressed: _busy ? null : _submit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_busy ? s.t('pairing') : s.t('pair_button')),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              s.t('pair_privacy'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
