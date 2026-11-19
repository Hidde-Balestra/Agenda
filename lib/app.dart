import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'state/agenda_controller.dart';
import 'state/settings_controller.dart';
import 'theme.dart';

class AgendaApp extends StatelessWidget {
  const AgendaApp({super.key, required this.settings, required this.agenda});

  final SettingsController settings;
  final AgendaController agenda;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: agenda),
      ],
      child: Consumer<SettingsController>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Agenda',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: settings.themeMode,
          locale: const Locale('nl', 'NL'),
          supportedLocales: const [Locale('nl', 'NL'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
