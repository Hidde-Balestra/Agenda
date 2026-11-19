import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/agenda_controller.dart';
import '../state/settings_controller.dart';
import 'account_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmRemove(BuildContext context, DavAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Account verwijderen?'),
        content: Text('${account.name} en de lokale kopie van de agenda\'s worden van dit apparaat '
            'verwijderd. Gegevens op de server blijven bestaan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuleren')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Verwijderen')),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<AgendaController>().removeAccount(account.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final agenda = context.watch<AgendaController>();
    final textTheme = Theme.of(context).textTheme;

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(text, style: textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );

    List<Widget> calendarTiles(String? accountId) => [
          for (final c in agenda.calendars.where((c) => c.accountId == accountId))
            CheckboxListTile(
              value: c.visible,
              onChanged: (v) => agenda.setCalendarVisible(c.id, v ?? true),
              secondary: Icon(Icons.circle, color: Color(c.colorValue)),
              title: Text(c.name),
              subtitle: c.readOnly ? const Text('Alleen-lezen') : null,
            ),
        ];

    return Scaffold(
      appBar: AppBar(title: const Text('Instellingen')),
      body: ListView(
        children: [
          header('Weergave'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('Systeem')),
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Licht')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Donker')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) => settings.setThemeMode(s.first),
            ),
          ),
          header('Op dit apparaat'),
          ...calendarTiles(null),
          for (final account in agenda.accounts) ...[
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(account.name),
              subtitle: Text('${account.username} · ${account.serverUrl}'),
              trailing: IconButton(
                tooltip: 'Account verwijderen',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmRemove(context, account),
              ),
            ),
            ...calendarTiles(account.id),
          ],
          header('CalDAV'),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('CalDAV-account toevoegen'),
            subtitle: const Text('Nextcloud, iCloud, Fastmail, Radicale, Baïkal, …'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
            ),
          ),
          if (agenda.accounts.isNotEmpty)
            ListTile(
              leading: agenda.syncing
                  ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              title: const Text('Nu synchroniseren'),
              subtitle: Text(agenda.lastError ??
                  (agenda.lastSync == null
                      ? 'Nog niet gesynchroniseerd in deze sessie'
                      : 'Laatst: ${DateFormat.Hm('nl_NL').format(agenda.lastSync!)}')),
              onTap: agenda.syncing ? null : agenda.sync,
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
