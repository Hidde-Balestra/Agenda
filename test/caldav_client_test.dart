import 'package:agenda/dav/caldav_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_caldav_server.dart';

void main() {
  late FakeCalDavServer server;

  CalDavClient clientFor({String password = 'secret', String base = 'https://dav.example.com/'}) =>
      CalDavClient(baseUri: Uri.parse(base), username: 'alice', password: password, httpClient: server.client);

  setUp(() => server = FakeCalDavServer());

  test('discovers calendars via principal and home set', () async {
    final calendars = await clientFor().discoverCalendars();
    expect(calendars.map((c) => c.displayName), ['Persoonlijk', 'Feestdagen']);
    final personal = calendars.first;
    expect(personal.url.toString(), 'https://dav.example.com/calendars/alice/personal/');
    expect(personal.color, '#FF2968FF');
    expect(personal.ctag, '1');
    expect(personal.readOnly, isFalse);
    expect(calendars.last.readOnly, isTrue);
    expect(server.requests.first.headers['Depth'], '0');
  });

  test('falls back to /.well-known/caldav and follows the redirect', () async {
    server = FakeCalDavServer(useWellKnown: true);
    final calendars = await clientFor().discoverCalendars();
    expect(calendars, hasLength(2));
    expect(server.requests.map((r) => r.url.path), containsAllInOrder(['/', '/.well-known/caldav', '/dav/']));
  });

  test('reports wrong credentials', () async {
    expect(
      () => clientFor(password: 'wrong').discoverCalendars(),
      throwsA(isA<DavException>().having((e) => e.isAuthError, 'isAuthError', isTrue)),
    );
  });

  test('fetches events with a time-range REPORT', () async {
    server.addEvent('/calendars/alice/personal/', 'a.ics', sampleEvent(summary: 'R&D <overleg>'));
    final client = clientFor();
    final url = Uri.parse('https://dav.example.com/calendars/alice/personal/');
    final events = await client.fetchEvents(url, DateTime.utc(2026), DateTime.utc(2027));

    expect(events, hasLength(1));
    expect(events.single.url.path, '/calendars/alice/personal/a.ics');
    expect(events.single.etag, '"e1"');
    expect(events.single.data, contains('SUMMARY:R&D <overleg>'));

    final report = server.requests.last;
    expect(report.method, 'REPORT');
    expect(report.headers['Depth'], '1');
    expect(report.body, contains('start="20260101T000000Z"'));
    expect(report.body, contains('end="20270101T000000Z"'));
  });

  test('creates, updates and deletes with ETag preconditions', () async {
    final client = clientFor();
    final url = Uri.parse('https://dav.example.com/calendars/alice/personal/n.ics');

    final etag1 = await client.putEvent(url, sampleEvent(uid: 'n'), create: true);
    expect(etag1, isNotNull);
    expect(server.requests.last.headers['If-None-Match'], '*');
    expect(server.requests.last.headers['Content-Type'], startsWith('text/calendar'));

    // Creating again must fail because the resource exists.
    expect(() => client.putEvent(url, sampleEvent(uid: 'n'), create: true),
        throwsA(isA<DavException>().having((e) => e.isConflict, 'conflict', isTrue)));

    final etag2 = await client.putEvent(url, sampleEvent(uid: 'n', summary: 'Nieuw'), etag: etag1);
    expect(server.requests.last.headers['If-Match'], etag1);
    expect(server.resources['/calendars/alice/personal/']!['n.ics'], contains('Nieuw'));

    // Stale ETag → conflict.
    expect(() => client.deleteEvent(url, etag: etag1), throwsA(isA<DavException>()));
    await client.deleteEvent(url, etag: etag2);
    expect(server.resources['/calendars/alice/personal/'], isEmpty);
  });

  test('returns the collection ctag', () async {
    final client = clientFor();
    expect(await client.getCtag(Uri.parse('https://dav.example.com/calendars/alice/personal/')), '1');
  });

  test('wraps network failures in DavException', () async {
    final client = CalDavClient(
      baseUri: Uri.parse('https://down.example.com/'),
      username: 'a',
      password: 'b',
      httpClient: MockClient((_) => throw http.ClientException('offline')),
    );
    expect(() => client.discoverCalendars(), throwsA(isA<DavException>()));
  });

  test('rejects non-XML multistatus bodies', () async {
    final client = CalDavClient(
      baseUri: Uri.parse('https://bad.example.com/'),
      username: 'a',
      password: 'b',
      httpClient: MockClient((_) async => http.Response('not xml', 207)),
    );
    expect(() => client.getCtag(Uri.parse('https://bad.example.com/c/')), throwsA(isA<DavException>()));
  });
}
