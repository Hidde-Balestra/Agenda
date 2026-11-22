import 'dart:convert';

import 'package:agenda/app.dart';
import 'package:agenda/data/stores.dart';
import 'package:agenda/models/models.dart';
import 'package:agenda/state/agenda_controller.dart';
import 'package:agenda/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  late MemoryStore store;
  late SettingsController settings;
  late AgendaController agenda;

  setUpAll(() => initializeDateFormatting('nl_NL'));

  setUp(() async {
    store = MemoryStore();
    settings = SettingsController(store);
    agenda = AgendaController(store: store, secrets: MemoryStore());
    await settings.load();
    await agenda.load();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AgendaApp(settings: settings, agenda: agenda));
    await tester.pumpAndSettle();
  }

  ThemeMode currentThemeMode(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  testWidgets('shows the agenda with an empty day', (tester) async {
    await pumpApp(tester);
    expect(find.text('Agenda'), findsOneWidget);
    expect(find.text('Geen afspraken'), findsOneWidget);
    expect(find.byTooltip('Nieuwe afspraak'), findsOneWidget);
    // No DAV account yet → no sync button.
    expect(find.byTooltip('Synchroniseren'), findsNothing);
  });

  testWidgets('shows events of today', (tester) async {
    final now = DateTime.now();
    await agenda.saveEvent(CalendarEvent(
      uid: 'w1',
      calendarId: localCalendarId,
      title: 'Werkoverleg',
      location: 'Kantoor',
      start: DateTime(now.year, now.month, now.day, 10),
      end: DateTime(now.year, now.month, now.day, 11),
    ));
    await pumpApp(tester);
    expect(find.text('Werkoverleg'), findsOneWidget);
    expect(find.text('10:00 – 11:00 · Kantoor'), findsOneWidget);
  });

  testWidgets('dark mode can be selected and is persisted', (tester) async {
    await pumpApp(tester);
    expect(currentThemeMode(tester), ThemeMode.system);

    await tester.tap(find.byTooltip('Instellingen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Donker'));
    await tester.pumpAndSettle();

    expect(currentThemeMode(tester), ThemeMode.dark);
    expect(Theme.of(tester.element(find.text('Instellingen'))).brightness, Brightness.dark);
    expect(store.values['settings.themeMode'], 'dark');

    await tester.tap(find.text('Licht'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Instellingen'))).brightness, Brightness.light);
  });

  testWidgets('creating an event via the editor', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Nieuwe afspraak'));
    await tester.pumpAndSettle();
    expect(find.text('Nieuwe afspraak'), findsOneWidget);

    // Saving without a title shows a validation error.
    await tester.tap(find.text('Opslaan'));
    await tester.pumpAndSettle();
    expect(find.text('Vul een titel in'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('titleField')), 'Boodschappen');
    await tester.tap(find.text('Hele dag'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opslaan'));
    await tester.pumpAndSettle();

    expect(find.text('Boodschappen'), findsOneWidget);
    expect(find.text('Hele dag'), findsOneWidget);
    expect(agenda.events.single.allDay, isTrue);
  });

  testWidgets('deleting an event asks for confirmation', (tester) async {
    final now = DateTime.now();
    await agenda.saveEvent(CalendarEvent(
      uid: 'd1',
      calendarId: localCalendarId,
      title: 'Weg ermee',
      start: DateTime(now.year, now.month, now.day, 15),
      end: DateTime(now.year, now.month, now.day, 16),
    ));
    await pumpApp(tester);
    await tester.tap(find.text('Weg ermee'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Verwijderen'));
    await tester.pumpAndSettle();
    expect(find.text('Afspraak verwijderen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Verwijderen'));
    await tester.pumpAndSettle();

    expect(find.text('Weg ermee'), findsNothing);
    expect(agenda.events, isEmpty);
  });

  testWidgets('chosen default calendar is preselected for new events', (tester) async {
    store.values['agenda.accounts'] = jsonEncode([
      const DavAccount(id: 'acc', name: 'Kantoor', serverUrl: 'https://dav.example.com', username: 'a').toJson(),
    ]);
    store.values['agenda.calendars'] = jsonEncode([
      const CalendarInfo(id: localCalendarId, name: 'Mijn agenda', colorValue: 0xFF3F51B5).toJson(),
      const CalendarInfo(id: 'werk', name: 'Werk', colorValue: 0xFF009688, accountId: 'acc', href: 'https://x/werk/')
          .toJson(),
      const CalendarInfo(
              id: 'fd', name: 'Feestdagen', colorValue: 0xFFE91E63, accountId: 'acc', href: 'https://x/fd/', readOnly: true)
          .toJson(),
    ]);
    await agenda.load();
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.text('Standaardagenda'), findsOneWidget);

    await tester.tap(find.text('Mijn agenda').first);
    await tester.pumpAndSettle();
    // Read-only calendars are not offered as default.
    expect(find.text('Feestdagen · Kantoor'), findsNothing);
    await tester.tap(find.text('Werk · Kantoor').last);
    await tester.pumpAndSettle();
    expect(agenda.defaultCalendar.id, 'werk');
    expect(store.values['agenda.defaultCalendar'], 'werk');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Nieuwe afspraak'));
    await tester.pumpAndSettle();

    final field = find.byWidgetPredicate((w) => w is DropdownButtonFormField<String>);
    expect(find.descendant(of: field, matching: find.text('Werk')), findsOneWidget);
  });

  testWidgets('account screen validates required fields', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Instellingen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CalDAV-account toevoegen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verbinden'));
    await tester.pumpAndSettle();
    expect(find.text('Verplicht'), findsNWidgets(3));
  });
}
