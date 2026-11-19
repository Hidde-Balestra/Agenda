import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../dav/caldav_client.dart';
import '../state/agenda_controller.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AgendaController>().addAccount(
            name: _name.text,
            serverUrl: _url.text,
            username: _username.text.trim(),
            password: _password.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on DavException catch (e) {
      setState(() => _error = e.message);
    } on FormatException {
      setState(() => _error = 'Ongeldige server-URL');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) => (v == null || v.trim().isEmpty) ? 'Verplicht' : null;
    return Scaffold(
      appBar: AppBar(title: const Text('CalDAV-account')),
      body: Form(
        key: _formKey,
        child: AutofillGroup(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Server-URL',
                  hintText: 'https://cloud.voorbeeld.nl/remote.php/dav',
                  helperText: 'Een hostnaam is vaak genoeg; de agenda\'s worden automatisch gevonden.',
                  helperMaxLines: 2,
                ),
                validator: required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _username,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Gebruikersnaam'),
                validator: required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Wachtwoord of app-wachtwoord',
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Tonen' : 'Verbergen',
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Naam (optioneel)', hintText: 'Bijv. Werk'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: const Text('Verbinden'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
