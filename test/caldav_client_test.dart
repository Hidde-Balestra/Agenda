import 'package:agenda/dav/caldav_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_caldav_server.dart';

void main() {
  digestTests();
  notFoundTests();

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

void digestTests() {
  group('Digest authentication (Baïkal default)', () {
    late FakeCalDavServer server;

    CalDavClient clientFor(String base, {String password = 'secret'}) => CalDavClient(
        baseUri: Uri.parse(base), username: 'alice', password: password, httpClient: server.client);

    setUp(() => server = FakeCalDavServer(authMode: FakeAuthMode.digest, davRoot: '/dav.php/'));

    test('answers the Digest challenge and finds /dav.php/ from just the host', () async {
      final calendars = await clientFor('http://baikal.local/').discoverCalendars();
      expect(calendars.map((c) => c.displayName), ['Persoonlijk', 'Feestdagen']);
      expect(server.requests.map((r) => r.url.path), contains('/dav.php/'));
    });

    test('never sends the password as Basic over plain HTTP', () async {
      await clientFor('http://baikal.local/').discoverCalendars();
      expect(server.requests.where((r) => (r.headers['Authorization'] ?? '').startsWith('Basic ')), isEmpty);
    });

    test('reuses the challenge: one 401 for the whole discovery', () async {
      await clientFor('https://baikal.local/dav.php/').discoverCalendars();
      final unauthorized = server.requests.where((r) => !(r.headers['Authorization'] ?? '').startsWith('Digest '));
      expect(unauthorized, hasLength(1)); // the first, preemptive Basic attempt over HTTPS
    });

    test('recovers from an expired (stale) nonce', () async {
      final client = clientFor('https://baikal.local/dav.php/');
      await client.discoverCalendars();
      server.nonce = 'nonce-2';
      final calendars = await client.discoverCalendars();
      expect(calendars, hasLength(2));
    });

    test('writes events with Digest', () async {
      final client = clientFor('https://baikal.local/dav.php/');
      final url = Uri.parse('https://baikal.local/calendars/alice/personal/d.ics');
      final etag = await client.putEvent(url, sampleEvent(uid: 'd'), create: true);
      expect(etag, isNotNull);
      expect(server.resources['/calendars/alice/personal/'], contains('d.ics'));
    });

    test('wrong password is an auth error without endless retries', () async {
      await expectLater(
        clientFor('https://baikal.local/dav.php/', password: 'fout').discoverCalendars(),
        throwsA(isA<DavException>().having((e) => e.isAuthError, 'isAuthError', isTrue)),
      );
      expect(server.requests.length, lessThanOrEqualTo(3));
    });
  });
}

void notFoundTests() {
  test('a web server without CalDAV gives a helpful message', () async {
    final client = CalDavClient(
      baseUri: Uri.parse('https://www.example.com/'),
      username: 'a',
      password: 'b',
      httpClient: MockClient((_) async => http.Response('<html></html>', 200)),
    );
    expect(
      () => client.discoverCalendars(),
      throwsA(isA<DavException>().having((e) => e.message, 'message', contains('Geen CalDAV-server'))),
    );
  });
}
