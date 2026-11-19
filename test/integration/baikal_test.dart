// Integration tests against a real Baïkal server.
//
// Skipped unless BAIKAL_URL is set, e.g.:
//   BAIKAL_URL=http://127.0.0.1:8765 BAIKAL_USER=alice BAIKAL_PASSWORD=secret \
//     flutter test test/integration
//
// CI starts Baïkal with tool/baikal/setup.php (see .github/workflows/test.yml).
@Tags(['integration'])
library;

import 'dart:io';

import 'package:agenda/dav/caldav_client.dart';
import 'package:agenda/data/stores.dart';
import 'package:agenda/models/models.dart';
import 'package:agenda/state/agenda_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Platform.environment['BAIKAL_URL'];
  final user = Platform.environment['BAIKAL_USER'] ?? 'alice';
  final password = Platform.environment['BAIKAL_PASSWORD'] ?? 'secret';
  final skip = url == null ? 'BAIKAL_URL niet gezet' : null;

  CalDavClient client([String? pass]) =>
      CalDavClient(baseUri: normalizeServerUrl(url!), username: user, password: pass ?? password);

  test('discovers calendars from just the host name', () async {
    final c = client();
    addTearDown(c.close);
    final calendars = await c.discoverCalendars();
    expect(calendars, isNotEmpty);
    expect(calendars.first.url.path, contains('/calendars/$user/'));
    expect(calendars.first.readOnly, isFalse);
  }, skip: skip);

  test('wrong password is reported as an authentication error', () async {
    final c = client('verkeerd');
    addTearDown(c.close);
    await expectLater(
      c.discoverCalendars(),
      throwsA(isA<DavException>().having((e) => e.isAuthError, 'isAuthError', isTrue)),
    );
  }, skip: skip);

  test('full round trip through AgendaController', () async {
    final agenda = AgendaController(store: MemoryStore(), secrets: MemoryStore());
    await agenda.load();
    await agenda.addAccount(name: 'Baïkal', serverUrl: url!, username: user, password: password);
    expect(agenda.lastError, isNull);

    final calendar = agenda.writableCalendars.firstWhere((c) => !c.isLocal);
    final uid = 'it-${DateTime.now().microsecondsSinceEpoch}';
    final start = DateTime.now().add(const Duration(days: 1));
    await agenda.saveEvent(CalendarEvent(
      uid: uid,
      calendarId: calendar.id,
      title: 'Integratietest, één',
      location: 'Utrecht',
      start: start,
      end: start.add(const Duration(hours: 1)),
      rrule: 'FREQ=WEEKLY;COUNT=3',
    ));

    // A second controller must see the event after syncing from the server.
    final other = AgendaController(store: MemoryStore(), secrets: MemoryStore());
    await other.load();
    await other.addAccount(name: 'B', serverUrl: url, username: user, password: password);
    final fetched = other.events.singleWhere((e) => e.uid == uid);
    expect(fetched.title, 'Integratietest, één');
    expect(fetched.location, 'Utrecht');
    expect(fetched.rrule, 'FREQ=WEEKLY;COUNT=3');
    expect(fetched.etag, isNotNull);

    await other.saveEvent(fetched.copyWith(title: 'Bijgewerkt'), original: fetched);
    await agenda.sync();
    expect(agenda.events.singleWhere((e) => e.uid == uid).title, 'Bijgewerkt');

    // After syncing, the first controller has the current ETag and can delete.
    await agenda.deleteEvent(agenda.events.singleWhere((e) => e.uid == uid));
    await other.sync();
    expect(other.events.where((e) => e.uid == uid), isEmpty);
  }, skip: skip);
}
