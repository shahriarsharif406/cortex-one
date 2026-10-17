import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../state/computer.dart';
import '../state/power_state.dart';
import 'pairing_screen.dart';

/// All computers this phone controls: pick one, edit its addresses and wake options, add a
/// new one (pairing code), or remove one.
class ComputersScreen extends StatelessWidget {
  const ComputersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('computers_title'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('computer_add'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const PairingScreen(addingMore: true),
          ),
        ),
        icon: const Icon(Icons.add),
        label: Text(s.t('computers_add')),
      ),
      body: app.computers.isEmpty
          ? Center(child: Text(s.t('computers_empty')))
          : ListView(
              padding: const EdgeInsets.only(bottom: 90),
              children: [
                for (var i = 0; i < app.computers.length; i++)
                  _tile(context, app, i),
              ],
            ),
    );
  }

  Widget _tile(BuildContext context, AppState app, int i) {
    final c = app.computers[i];
    final s = app.s;
    final monitor = app.monitorFor(c);
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final st = monitor.status.state;
        final (label, color) = switch (st) {
          PowerState.online => (s.t('state_online'), Colors.green),
          PowerState.sleeping => (s.t('state_sleeping'), Colors.amber.shade800),
          PowerState.offline => (s.t('state_offline'), Theme.of(context).colorScheme.error),
          PowerState.unknown => (s.t('state_unknown'), Theme.of(context).colorScheme.outline),
        };
        return ListTile(
          key: Key('computer_tile_${c.id}'),
          selected: app.current?.id == c.id,
          leading: Icon(Icons.computer, color: color),
          title: Text(c.name),
          subtitle: Text('$label · ${c.endpoints.join(' | ')}'),
          onTap: () {
            app.selectComputer(i);
            Navigator.of(context).maybePop();
          },
          trailing: IconButton(
            key: Key('computer_edit_${c.id}'),
            tooltip: s.t('computer_edit'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ComputerEditDialog(computer: c),
            ),
          ),
        );
      },
    );
  }
}

class ComputerEditDialog extends StatefulWidget {
  const ComputerEditDialog({super.key, required this.computer});

  final Computer computer;

  @override
  State<ComputerEditDialog> createState() => _ComputerEditDialogState();
}

class _ComputerEditDialogState extends State<ComputerEditDialog> {
  late final _name = TextEditingController(text: widget.computer.name);
  late final _endpoints = TextEditingController(
    text: widget.computer.endpoints.join('\n'),
  );
  late final _gwAddr = TextEditingController(
    text: widget.computer.wakeGateway?.address ?? '',
  );
  late final _gwToken = TextEditingController(
    text: widget.computer.wakeGateway?.token ?? '',
  );
  late final _rustdesk = TextEditingController(
    text: widget.computer.rustdeskId ?? '',
  );
  late bool _lanOk = widget.computer.allowLanHttp;
  late String? _via = widget.computer.wakeVia;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _endpoints, _gwAddr, _gwToken, _rustdesk]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final endpoints = <String>[];
    for (final line in _endpoints.text.split(RegExp(r'[\n,]'))) {
      if (line.trim().isEmpty) continue;
      final n = normalizeServerAddress(line, allowLan: _lanOk);
      if (n == null) {
        setState(() => _error = app.s.t(
              isPrivateLanHost(
                    Uri.tryParse(
                          line.contains('://') ? line.trim() : 'http://${line.trim()}',
                        )?.host ??
                        '',
                  )
                  ? 'server_lan_needs_ok'
                  : 'server_not_private',
            ));
        return;
      }
      if (!endpoints.contains(n)) endpoints.add(n);
    }
    if (endpoints.isEmpty) {
      setState(() => _error = app.s.t('server_invalid'));
      return;
    }
    WakeGateway? gateway;
    if (_gwAddr.text.trim().isNotEmpty && _gwToken.text.trim().isNotEmpty) {
      final a = normalizeServerAddress(_gwAddr.text, allowLan: _lanOk);
      if (a == null) {
        setState(() => _error = app.s.t('server_not_private'));
        return;
      }
      gateway = WakeGateway(address: a, token: _gwToken.text.trim());
    }
    final rd = _rustdesk.text.trim();
    if (rd.isNotEmpty && !RegExp(r'^[0-9A-Za-z]{6,20}$').hasMatch(rd)) {
      setState(() => _error = app.s.t('server_invalid'));
      return;
    }
    final name = _name.text.trim().isEmpty
        ? widget.computer.name
        : _name.text.trim();
    try {
      await app.updateComputer(
        widget.computer.copyWith(
          name: name,
          endpoints: endpoints,
          allowLanHttp: _lanOk,
          wakeVia: _via,
          wakeGateway: gateway,
          rustdeskId: rd.isEmpty ? null : rd,
        ),
      );
    } on InvalidServerAddress catch (e) {
      setState(() => _error = app.s.t(e.messageKey));
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    final app = AppScope.read(context);
    final s = app.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('computer_remove_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('no')),
          ),
          TextButton(
            key: const Key('computer_remove_yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('yes')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.removeComputer(widget.computer);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final others = [
      for (final c in app.computers)
        if (c.id != widget.computer.id) c,
    ];
    return AlertDialog(
      title: Text(s.t('computer_edit')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('edit_name'),
              controller: _name,
              decoration: InputDecoration(labelText: s.t('computer_name')),
            ),
            const SizedBox(height: 12),
            Text(s.t('computer_endpoints'),
                style: Theme.of(context).textTheme.labelMedium),
            TextField(
              key: const Key('edit_endpoints'),
              controller: _endpoints,
              minLines: 2,
              maxLines: 4,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(hintText: s.t('computer_endpoints_hint')),
            ),
            CheckboxListTile(
              key: const Key('edit_lan_ok'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _lanOk,
              onChanged: (v) => setState(() => _lanOk = v ?? false),
              title: Text(s.t('computer_lan_ok'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            DropdownButtonFormField<String?>(
              key: const Key('edit_wake_via'),
              initialValue: others.any((c) => c.name == _via) ? _via : null,
              decoration: InputDecoration(labelText: s.t('computer_wake_via')),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(s.t('computer_wake_via_none')),
                ),
                for (final c in others)
                  DropdownMenuItem<String?>(value: c.name, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _via = v),
            ),
            TextField(
              key: const Key('edit_gw_addr'),
              controller: _gwAddr,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: s.t('computer_gateway_addr')),
            ),
            TextField(
              key: const Key('edit_gw_token'),
              controller: _gwToken,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: s.t('computer_gateway_token')),
            ),
            TextField(
              key: const Key('edit_rustdesk'),
              controller: _rustdesk,
              autocorrect: false,
              decoration: InputDecoration(labelText: s.t('computer_rustdesk_id')),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('edit_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('edit_remove'),
          onPressed: _remove,
          child: Text(s.t('unpair')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('cancel')),
        ),
        FilledButton(
          key: const Key('edit_save'),
          onPressed: _save,
          child: Text(s.t('save')),
        ),
      ],
    );
  }
}
