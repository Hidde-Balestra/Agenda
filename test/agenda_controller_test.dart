import 'package:agenda/dav/caldav_client.dart';
import 'package:agenda/data/stores.dart';
import 'package:agenda/models/models.dart';
import 'package:agenda/state/agenda_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_caldav_server.dart';

void main() {
  late MemoryStore store;
  late MemoryStore secrets;
  late FakeCalDavServer server;

  AgendaController newController() => AgendaController(
        store: store,
        secrets: secrets,
        clock: () => DateTime(2026, 11, 19, 12),
        clientFactory: (uri, user, pass) =>
            CalDavClient(baseUri: uri, username: user, password: pass, httpClient: server.client),
      );

  setUp(() {
    store = MemoryStore();
    secrets = MemoryStore();
    server = FakeCalDavServer();
  });

  CalendarEvent localEvent(String title, DateTime start, {String? rrule}) => CalendarEvent(
        uid: 'uid-$title',
        calendarId: localCalendarId,
        title: title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        rrule: rrule,
      );

  group('helpers', () {
    test('parseDavColor', () {
      expect(parseDavColor('#FF2968FF'), 0xFFFF2968);
      expect(parseDavColor('#00ff00'), 0xFF00FF00);
      expect(parseDavColor('blue'), isNull);
      expect(parseDavColor(null), isNull);
    });

    test('normalizeServerUrl', () {
      expect(normalizeServerUrl('cloud.example.com').toString(), 'https://cloud.example.com/');
      expect(normalizeServerUrl(' http://h:8080/dav ').toString(), 'http://h:8080/dav');
    });
  });

  group('local calendar', () {
    test('creates the built-in calendar on first load', () async {
      final c = newController();
      await c.load();
      expect(c.calendars.single.id, localCalendarId);
      expect(c.calendars.single.isLocal, isTrue);
    });

    test('saves, lists, persists and deletes events', () async {
      final c = newController();
      await c.load();
      await c.saveEvent(localEvent('Lunch', DateTime(2026, 11, 19, 12)));
      await c.saveEvent(localEvent('Sport', DateTime(2026, 11, 19, 8)));

      expect(c.occurrencesForDay(DateTime(2026, 11, 19)).map((o) => o.event.title), ['Sport', 'Lunch']);
      expect(c.occurrencesForDay(DateTime(2026, 11, 20)), isEmpty);

      final reloaded = newController();
      await reloaded.load();
      expect(reloaded.events, hasLength(2));
      expect(reloaded.events.first.rawIcs, contains('BEGIN:VEVENT'));

      await reloaded.deleteEvent(reloaded.events.first);
      expect(reloaded.events, hasLength(1));
    });

    test('expands recurring events and sorts all-day first', () async {
      final c = newController();
      await c.load();
      await c.saveEvent(localEvent('Standup', DateTime(2026, 11, 2, 9), rrule: 'FREQ=WEEKLY;BYDAY=MO'));
      await c.saveEvent(CalendarEvent(
        uid: 'all',
        calendarId: localCalendarId,
        title: 'Vrij',
        start: DateTime(2026, 11, 23),
        end: DateTime(2026, 11, 24),
        allDay: true,
      ));
      expect(c.occurrencesForDay(DateTime(2026, 11, 23)).map((o) => o.event.title), ['Vrij', 'Standup']);
      expect(c.occurrencesForDay(DateTime(2026, 12, 28)).single.start, DateTime(2026, 12, 28, 9));
    });

    test('hidden calendars are not shown', () async {
      final c = newController();
      await c.load();
      await c.saveEvent(localEvent('Lunch', DateTime(2026, 11, 19, 12)));
      await c.setCalendarVisible(localCalendarId, false);
      expect(c.occurrencesForDay(DateTime(2026, 11, 19)), isEmpty);
    });
  });

  group('default calendar', () {
    test('falls back to the local calendar when nothing is chosen', () async {
      final c = newController();
      await c.load();
      expect(c.defaultCalendar.id, localCalendarId);
    });

    test('is persisted and survives a reload', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      final personal = c.calendars.firstWhere((x) => x.name == 'Persoonlijk');
      await c.setDefaultCalendar(personal.id);
      expect(c.defaultCalendar.id, personal.id);

      final reloaded = newController();
      await reloaded.load();
      expect(reloaded.defaultCalendar.id, personal.id);
    });

    test('read-only calendars cannot be the default', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      final holidays = c.calendars.firstWhere((x) => x.readOnly);
      expect(() => c.setDefaultCalendar(holidays.id), throwsStateError);
      expect(() => c.setDefaultCalendar('bestaat-niet'), throwsStateError);
      expect(c.defaultCalendar.id, localCalendarId);
    });

    test('falls back when the chosen calendar disappears', () async {
      final c = newController();
      await c.load();
      final account =
          await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      await c.setDefaultCalendar(c.calendars.firstWhere((x) => x.name == 'Persoonlijk').id);
      await c.removeAccount(account.id);
      expect(c.defaultCalendar.id, localCalendarId);
    });
  });

  group('CalDAV accounts', () {
    test('adding an account discovers calendars and syncs events', () async {
      server.addEvent('/calendars/alice/personal/', 'a.ics', sampleEvent());
      final c = newController();
      await c.load();
      await c.addAccount(name: 'Werk', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');

      expect(c.accounts.single.name, 'Werk');
      expect(c.calendars.map((x) => x.name), ['Mijn agenda', 'Persoonlijk', 'Feestdagen']);
      expect(c.calendars[1].colorValue, 0xFFFF2968);
      expect(c.calendars[2].readOnly, isTrue);
      expect(c.writableCalendars.map((x) => x.name), ['Mijn agenda', 'Persoonlijk']);
      expect(c.events.single.title, 'Tandarts');
      expect(c.lastError, isNull);

      // Password lives in the secret store only.
      expect(secrets.values.values, contains('secret'));
      expect(store.values.values.join(), isNot(contains('secret')));
    });

    test('wrong password does not add the account', () async {
      final c = newController();
      await c.load();
      await expectLater(
        c.addAccount(name: '', serverUrl: 'dav.example.com', username: 'alice', password: 'nope'),
        throwsA(isA<DavException>()),
      );
      expect(c.accounts, isEmpty);
    });

    test('unchanged ctag skips the REPORT', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      final reports = server.requestCount('REPORT');
      await c.sync();
      expect(server.requestCount('REPORT'), reports);

      server.addEvent('/calendars/alice/personal/', 'b.ics', sampleEvent(uid: 'b', summary: 'Nieuw'));
      await c.sync();
      expect(server.requestCount('REPORT'), reports + 1);
      expect(c.events.map((e) => e.title), contains('Nieuw'));
    });

    test('create, update and delete are written to the server', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      final personal = c.calendars.firstWhere((x) => x.name == 'Persoonlijk');

      await c.saveEvent(CalendarEvent(
        uid: 'x1',
        calendarId: personal.id,
        title: 'Kapper',
        start: DateTime(2026, 11, 21, 10),
        end: DateTime(2026, 11, 21, 11),
      ));
      final stored = server.resources['/calendars/alice/personal/']!;
      expect(stored.keys, ['x1.ics']);
      expect(stored['x1.ics'], contains('SUMMARY:Kapper'));

      final created = c.events.single;
      expect(created.href, endsWith('/calendars/alice/personal/x1.ics'));
      expect(created.etag, isNotNull);

      await c.saveEvent(created.copyWith(title: 'Kapper (verzet)'), original: created);
      expect(stored['x1.ics'], contains('SUMMARY:Kapper (verzet)'));
      expect(server.requests.last.headers['If-Match'], created.etag);

      await c.deleteEvent(c.events.single);
      expect(stored, isEmpty);
      expect(c.events, isEmpty);
    });

    test('moving an event to another calendar', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      final personal = c.calendars.firstWhere((x) => x.name == 'Persoonlijk');

      final local = localEvent('Etentje', DateTime(2026, 11, 22, 19));
      await c.saveEvent(local);
      final saved = c.events.single;
      await c.saveEvent(saved.copyWith(calendarId: personal.id), original: saved);

      expect(c.events.single.calendarId, personal.id);
      expect(server.resources['/calendars/alice/personal/'], hasLength(1));
    });

    test('read-only calendars reject writes', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      final holidays = c.calendars.firstWhere((x) => x.readOnly);
      expect(
        () => c.saveEvent(CalendarEvent(
          uid: 'h',
          calendarId: holidays.id,
          title: 'x',
          start: DateTime(2026, 12, 1),
          end: DateTime(2026, 12, 2),
          allDay: true,
        )),
        throwsA(isA<DavException>()),
      );
    });

    test('sync errors are reported, not thrown', () async {
      final c = newController();
      await c.load();
      await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      await secrets.write(secrets.values.keys.single, 'changed');
      await c.sync();
      expect(c.lastError, contains('W:'));
      expect(c.syncing, isFalse);
    });

    test('removing an account removes its calendars, events and password', () async {
      server.addEvent('/calendars/alice/personal/', 'a.ics', sampleEvent());
      final c = newController();
      await c.load();
      final account =
          await c.addAccount(name: 'W', serverUrl: 'dav.example.com', username: 'alice', password: 'secret');
      await c.removeAccount(account.id);
      expect(c.accounts, isEmpty);
      expect(c.calendars.single.id, localCalendarId);
      expect(c.events, isEmpty);
      expect(secrets.values, isEmpty);
    });
  });
}
