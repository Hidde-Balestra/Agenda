import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory CalDAV server for tests. Layout:
///
/// * `/principals/alice/`          – principal
/// * `/calendars/alice/`           – calendar home
/// * `/calendars/alice/personal/`  – VEVENT calendar (writable)
/// * `/calendars/alice/holidays/`  – VEVENT calendar (read-only)
/// * `/calendars/alice/tasks/`     – VTODO-only list (must be ignored)
enum FakeAuthMode { basic, digest }

class FakeCalDavServer {
  FakeCalDavServer({
    this.username = 'alice',
    this.password = 'secret',
    this.useWellKnown = false,
    this.authMode = FakeAuthMode.basic,
    this.davRoot = '/',
  });

  final String username;
  final String password;
  final FakeAuthMode authMode;
  final String realm = 'BaikalDAV';

  /// Current Digest nonce; change it to simulate nonce expiry.
  String nonce = 'nonce-1';

  /// Path that answers `current-user-principal`, e.g. `/dav.php/` like Baïkal.
  final String davRoot;

  /// When true the root does not answer PROPFIND; only `/.well-known/caldav` redirects.
  final bool useWellKnown;

  final Map<String, Map<String, String>> resources = {
    '/calendars/alice/personal/': {},
    '/calendars/alice/holidays/': {},
  };
  final Map<String, String> etags = {};
  final Map<String, int> ctags = {'/calendars/alice/personal/': 1, '/calendars/alice/holidays/': 1};
  final List<http.Request> requests = [];
  int _etagCounter = 0;

  int requestCount(String method, [String? path]) =>
      requests.where((r) => r.method == method && (path == null || r.url.path == path)).length;

  MockClient get client => MockClient(_handle);

  void addEvent(String calendarPath, String name, String ics) {
    resources[calendarPath]![name] = ics;
    etags['$calendarPath$name'] = '"e${++_etagCounter}"';
    ctags[calendarPath] = ctags[calendarPath]! + 1;
  }

  String _md5(String s) => md5.convert(utf8.encode(s)).toString();

  /// Independent server-side Digest check (RFC 2617, MD5, qop=auth).
  bool _digestValid(String header, String method) {
    final p = {
      for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))').allMatches(header.substring(7)))
        m[1]!: m[2] ?? m[3]!,
    };
    if (p['username'] != username || p['nonce'] != nonce || p['realm'] != realm) return false;
    final ha1 = _md5('$username:$realm:$password');
    final ha2 = _md5('$method:${p['uri']}');
    return p['response'] == _md5('$ha1:$nonce:${p['nc']}:${p['cnonce']}:${p['qop']}:$ha2');
  }

  http.Response _challenge({bool stale = false}) => http.Response('', 401, headers: {
        'www-authenticate': authMode == FakeAuthMode.digest
            ? 'Digest realm="$realm",qop="auth",nonce="$nonce",opaque="abc"${stale ? ',stale=TRUE' : ''}'
            : 'Basic realm="$realm", charset="UTF-8"',
      });

  bool _authorized(http.Request request) {
    final header = request.headers['Authorization'] ?? '';
    if (authMode == FakeAuthMode.basic) {
      return header == 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }
    return header.startsWith('Digest ') && _digestValid(header, request.method);
  }

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    if (!_authorized(request)) {
      final header = request.headers['Authorization'] ?? '';
      // A Digest answer for an old nonce is "stale", not wrong.
      final stale = header.startsWith('Digest ') && !header.contains('nonce="$nonce"');
      return _challenge(stale: stale);
    }
    final path = request.url.path;
    switch (request.method) {
      case 'PROPFIND':
        return _propfind(path, request.body);
      case 'REPORT':
        return _report(path);
      case 'PUT':
        return _put(request);
      case 'DELETE':
        return _delete(request);
      default:
        return http.Response('', 405);
    }
  }

  http.Response _multistatus(String body) => http.Response.bytes(
        utf8.encode('<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
            'xmlns:a="http://apple.com/ns/ical/" xmlns:cs="http://calendarserver.org/ns/">'
            '$body</d:multistatus>'),
        207,
        headers: {'content-type': 'application/xml; charset=utf-8'},
      );

  String _ok(String href, String props) =>
      '<d:response><d:href>$href</d:href><d:propstat><d:prop>$props</d:prop>'
      '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';

  http.Response _propfind(String path, String body) {
    if (path == '/.well-known/caldav' && useWellKnown) {
      return http.Response('', 301, headers: {'location': '/dav/'});
    }
    // Like Baïkal behind a plain web server: the root serves an HTML page.
    if (path == '/' && davRoot != '/') return http.Response('<html>Baïkal</html>', 200);
    if ((path == davRoot && !useWellKnown) || (path == '/dav/' && useWellKnown)) {
      return _multistatus(_ok(path, '<d:current-user-principal><d:href>/principals/alice/</d:href>'
          '</d:current-user-principal>'));
    }
    if (path == '/') return http.Response('', 404);
    if (path == '/principals/alice/') {
      return _multistatus(_ok(path, '<c:calendar-home-set><d:href>/calendars/alice/</d:href></c:calendar-home-set>'));
    }
    if (path == '/calendars/alice/') {
      const write = '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege>'
          '<d:privilege><d:write/></d:privilege></d:current-user-privilege-set>';
      const readOnly = '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege>'
          '</d:current-user-privilege-set>';
      return _multistatus([
        _ok(path, '<d:resourcetype><d:collection/></d:resourcetype><d:displayname>alice</d:displayname>'),
        _ok('/calendars/alice/personal/',
            '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
            '<d:displayname>Persoonlijk</d:displayname><a:calendar-color>#FF2968FF</a:calendar-color>'
            '<cs:getctag>${ctags['/calendars/alice/personal/']}</cs:getctag>'
            '<c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>'
            '$write'),
        _ok('/calendars/alice/holidays/',
            '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
            '<d:displayname>Feestdagen</d:displayname>'
            '<cs:getctag>${ctags['/calendars/alice/holidays/']}</cs:getctag>'
            '<c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>'
            '$readOnly'),
        _ok('/calendars/alice/tasks/',
            '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Taken</d:displayname>'
            '<c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>'),
      ].join());
    }
    if (ctags.containsKey(path)) {
      return _multistatus(_ok(path, '<cs:getctag>${ctags[path]}</cs:getctag>'));
    }
    return http.Response('', 404);
  }

  String _xmlEscape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  http.Response _report(String path) {
    final calendar = resources[path];
    if (calendar == null) return http.Response('', 404);
    return _multistatus([
      for (final entry in calendar.entries)
        _ok('$path${entry.key}',
            '<d:getetag>${_xmlEscape(etags['$path${entry.key}']!)}</d:getetag>'
            '<c:calendar-data>${_xmlEscape(entry.value)}</c:calendar-data>'),
    ].join());
  }

  (String, String)? _split(String path) {
    final i = path.lastIndexOf('/');
    final calendar = path.substring(0, i + 1);
    if (!resources.containsKey(calendar)) return null;
    return (calendar, path.substring(i + 1));
  }

  http.Response _put(http.Request request) {
    final parts = _split(request.url.path);
    if (parts == null) return http.Response('', 409);
    final (calendar, name) = parts;
    if (calendar == '/calendars/alice/holidays/') return http.Response('', 403);
    final key = '$calendar$name';
    final exists = resources[calendar]!.containsKey(name);
    if (request.headers['If-None-Match'] == '*' && exists) return http.Response('', 412);
    final ifMatch = request.headers['If-Match'];
    if (ifMatch != null && etags[key] != ifMatch) return http.Response('', 412);
    resources[calendar]![name] = request.body;
    etags[key] = '"e${++_etagCounter}"';
    ctags[calendar] = ctags[calendar]! + 1;
    return http.Response('', exists ? 204 : 201, headers: {'etag': etags[key]!});
  }

  http.Response _delete(http.Request request) {
    final parts = _split(request.url.path);
    if (parts == null) return http.Response('', 404);
    final (calendar, name) = parts;
    final key = '$calendar$name';
    if (!resources[calendar]!.containsKey(name)) return http.Response('', 404);
    final ifMatch = request.headers['If-Match'];
    if (ifMatch != null && etags[key] != ifMatch) return http.Response('', 412);
    resources[calendar]!.remove(name);
    etags.remove(key);
    ctags[calendar] = ctags[calendar]! + 1;
    return http.Response('', 204);
  }
}

String sampleEvent({
  String uid = 'evt-1',
  String summary = 'Tandarts',
  String start = '20261120T090000Z',
  String end = '20261120T100000Z',
  String extra = '',
}) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nBEGIN:VEVENT\r\n'
    'UID:$uid\r\nDTSTAMP:20261101T000000Z\r\nDTSTART:$start\r\nDTEND:$end\r\n'
    'SUMMARY:$summary\r\n${extra}END:VEVENT\r\nEND:VCALENDAR\r\n';
