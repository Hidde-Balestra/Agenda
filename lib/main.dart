import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/stores.dart';
import 'state/agenda_controller.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('nl_NL');
  Intl.defaultLocale = 'nl_NL';

  final store = SharedPrefsStore(await SharedPreferences.getInstance());
  final settings = SettingsController(store);
  final agenda = AgendaController(store: store, secrets: SecureStore());
  await Future.wait([settings.load(), agenda.load()]);

  runApp(AgendaApp(settings: settings, agenda: agenda));

  // Refresh remote calendars in the background on start-up.
  if (agenda.accounts.isNotEmpty) agenda.sync();
}
