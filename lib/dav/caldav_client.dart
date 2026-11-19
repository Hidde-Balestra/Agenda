import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../ical/ical.dart';
import 'http_auth.dart';

const davNs = 'DAV:';
const calDavNs = 'urn:ietf:params:xml:ns:caldav';
const appleNs = 'http://apple.com/ns/ical/';
const calServerNs = 'http://calendarserver.org/ns/';

class DavException implements Exception {
  DavException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  bool get isAuthError => statusCode == 401 || statusCode == 403;
  bool get isConflict => statusCode == 412;

  @override
  String toString() => statusCode == null ? message : '$message (HTTP $statusCode)';
}

class DavCalendar {
  const DavCalendar({
    required this.url,
    required this.displayName,
    this.color,
    this.ctag,
    this.readOnly = false,
  });

  final Uri url;
  final String displayName;

  /// Color as sent by the server, e.g. `#FF2968FF`.
  final String? color;
  final String? ctag;
  final bool readOnly;
}

class DavEventResource {
  const DavEventResource({required this.url, required this.etag, required this.data});
  final Uri url;
  final String? etag;
  final String data;
}

class _DavResponse {
  _DavResponse(this.href, this.props);
  final String href;
  final Map<String, XmlElement> props; // key: '{namespace}localName'
  XmlElement? prop(String ns, String name) => props['{$ns}$name'];
}

/// Minimal CalDAV (RFC 4791) client supporting HTTP Basic and Digest
/// authentication (Baïkal uses Digest by default).
class CalDavClient {
  CalDavClient({
    required this.baseUri,
    required this.username,
    required this.password,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Paths tried when neither the given URL nor `/.well-known/caldav` leads to
  /// a principal (common Baïkal, Nextcloud and Radicale layouts).
  static const fallbackPaths = ['/dav.php/', '/baikal/html/dav.php/', '/baikal/dav.php/', '/remote.php/dav/'];

  final Uri baseUri;
  final String username;
  final String password;
  final http.Client _http;

  /// Set once the server sent a Digest challenge; reused for later requests.
  DigestAuth? _digest;

  /// Whether the server rejected (or never asked for) Basic auth.
  bool _basicRejected = false;

  void close() => _http.close();

  String? _authorization(String method, Uri uri) {
    if (_digest != null) return _digest!.authorize(method, uri);
    // Only send Basic credentials unasked over TLS; over plain HTTP wait for
    // the challenge so Digest servers never see the password.
    if (_basicRejected || uri.scheme != 'https') return null;
    return _basic;
  }

  String get _basic => 'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    var current = uri;
    var authRetries = 0;
    String? sentAuth;
    for (var attempt = 0; attempt < 8; attempt++) {
      final auth = sentAuth ?? _authorization(method, current);
      sentAuth = null;
      final request = http.Request(method, current)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (auth != null) request.headers['Authorization'] = auth;
      if (body != null) request.bodyBytes = utf8.encode(body);
      http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request));
      } on Exception catch (e) {
        throw DavException('Server niet bereikbaar: $e');
      }
      final location = response.headers['location'];
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode) && location != null) {
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode == 401) {
        final next = authRetries++ < 2 ? _answerChallenge(response, auth, method, current) : null;
        if (next == null) {
          throw DavException('Onjuiste gebruikersnaam of wachtwoord', statusCode: 401);
        }
        sentAuth = next;
        continue;
      }
      return response;
    }
    throw DavException('Te veel redirects');
  }

  /// Picks credentials for a 401 response, or null if retrying is pointless.
  String? _answerChallenge(http.Response response, String? sent, String method, Uri uri) {
    final challenges = parseAuthChallenges(response.headers['www-authenticate'] ?? '');
    final digest = challenges.where(DigestAuth.supports).firstOrNull;
    if (digest != null) {
      final stale = digest.params['stale']?.toLowerCase() == 'true';
      final sentDigest = sent != null && sent.startsWith('Digest ');
      // A rejected Digest answer that is not merely a stale nonce means wrong credentials.
      if (sentDigest && !stale) return null;
      _digest = DigestAuth(username, password, digest);
      _basicRejected = true;
      return _digest!.authorize(method, uri);
    }
    final basic = challenges.any((c) => c.scheme == 'basic');
    if ((basic || challenges.isEmpty) && sent == null) return _basic;
    if (sent != null && sent.startsWith('Basic ')) _basicRejected = true;
    return null;
  }

  String _decode(http.Response r) => utf8.decode(r.bodyBytes, allowMalformed: true);

  Future<List<_DavResponse>> _multistatus(
    String method,
    Uri uri,
    String body, {
    required int depth,
  }) async {
    final response = await _send(method, uri, headers: {
      'Depth': '$depth',
      'Content-Type': 'application/xml; charset=utf-8',
    }, body: body);
    if (response.statusCode != 207) {
      throw DavException('$method $uri mislukt', statusCode: response.statusCode);
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(_decode(response));
    } on XmlException catch (e) {
      throw DavException('Ongeldig XML-antwoord: ${e.message}');
    }
    final results = <_DavResponse>[];
    for (final r in doc.findAllElements('response', namespaceUri: davNs)) {
      final href = r.findElements('href', namespaceUri: davNs).firstOrNull?.innerText.trim();
      if (href == null) continue;
      final props = <String, XmlElement>{};
      for (final ps in r.findElements('propstat', namespaceUri: davNs)) {
        final status = ps.findElements('status', namespaceUri: davNs).firstOrNull?.innerText ?? '';
        if (!status.contains(' 200')) continue;
        for (final prop in ps.findElements('prop', namespaceUri: davNs)) {
          for (final el in prop.childElements) {
            props['{${el.namespaceUri}}${el.localName}'] = el;
          }
        }
      }
      results.add(_DavResponse(href, props));
    }
    return results;
  }

  Uri? _hrefIn(XmlElement? el) {
    final href = el?.findElements('href', namespaceUri: davNs).firstOrNull?.innerText.trim();
    return href == null || href.isEmpty ? null : baseUri.resolve(href);
  }

  Future<Uri?> _currentUserPrincipal(Uri uri) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>';
    try {
      final responses = await _multistatus('PROPFIND', uri, body, depth: 0);
      for (final r in responses) {
        final href = _hrefIn(r.prop(davNs, 'current-user-principal'));
        if (href != null) return href;
      }
    } on DavException catch (e) {
      if (e.isAuthError) rethrow;
    }
    return null;
  }

  /// URLs probed for `current-user-principal`, in order: the URL as entered,
  /// `/.well-known/caldav` (RFC 6764), then common server layouts.
  List<Uri> _discoveryCandidates() {
    final dir = baseUri.path.endsWith('/') ? baseUri : baseUri.replace(path: '${baseUri.path}/');
    final candidates = <Uri>[
      baseUri,
      baseUri.resolve('/.well-known/caldav'),
      if (dir.path != '/') ...[dir.resolve('dav.php/'), dir.resolve('html/dav.php/')],
      for (final p in fallbackPaths) baseUri.resolve(p),
    ];
    final seen = <String>{};
    return [for (final c in candidates) if (seen.add(c.toString())) c];
  }

  /// Finds the calendar home collection via the principal (RFC 6764 / RFC 4791).
  Future<Uri> discoverCalendarHome() async {
    Uri? principal;
    for (final candidate in _discoveryCandidates()) {
      principal = await _currentUserPrincipal(candidate);
      if (principal != null) break;
    }
    if (principal == null) {
      // The URL may already point at a calendar home or collection.
      return baseUri;
    }
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><c:calendar-home-set/></d:prop></d:propfind>';
    final responses = await _multistatus('PROPFIND', principal, body, depth: 0);
    for (final r in responses) {
      final home = _hrefIn(r.prop(calDavNs, 'calendar-home-set'));
      if (home != null) return home;
    }
    return principal;
  }

  /// Lists the calendars (collections supporting VEVENT) of this account.
  Future<List<DavCalendar>> discoverCalendars() async {
    final home = await discoverCalendarHome();
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
        'xmlns:a="http://apple.com/ns/ical/" xmlns:cs="http://calendarserver.org/ns/">'
        '<d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><cs:getctag/>'
        '<c:supported-calendar-component-set/><d:current-user-privilege-set/></d:prop>'
        '</d:propfind>';
    List<_DavResponse> responses;
    try {
      responses = await _multistatus('PROPFIND', home, body, depth: 1);
    } on DavException catch (e) {
      if (e.isAuthError || e.statusCode == null) rethrow;
      throw DavException(
        'Geen CalDAV-server gevonden op dit adres. Probeer het volledige pad, '
        'bijv. https://server/dav.php (Baïkal) of https://server/remote.php/dav (Nextcloud).',
        statusCode: e.statusCode,
      );
    }
    final calendars = <DavCalendar>[];
    final seen = <String>{};
    for (final r in responses) {
      final type = r.prop(davNs, 'resourcetype');
      if (type == null || type.findElements('calendar', namespaceUri: calDavNs).isEmpty) continue;

      final components = r.prop(calDavNs, 'supported-calendar-component-set');
      if (components != null) {
        final names = components
            .findElements('comp', namespaceUri: calDavNs)
            .map((c) => c.getAttribute('name')?.toUpperCase())
            .toSet();
        if (!names.contains('VEVENT')) continue;
      }

      final privileges = r.prop(davNs, 'current-user-privilege-set');
      var readOnly = false;
      if (privileges != null) {
        final names = privileges.descendantElements
            .where((e) => e.namespaceUri == davNs)
            .map((e) => e.localName)
            .toSet();
        readOnly = !(names.contains('write') || names.contains('write-content') || names.contains('all'));
      }

      final url = home.resolve(r.href);
      if (!seen.add(url.toString())) continue;
      final name = r.prop(davNs, 'displayname')?.innerText.trim();
      calendars.add(DavCalendar(
        url: url,
        displayName: name == null || name.isEmpty ? _lastSegment(url) : name,
        color: r.prop(appleNs, 'calendar-color')?.innerText.trim(),
        ctag: r.prop(calServerNs, 'getctag')?.innerText.trim(),
        readOnly: readOnly,
      ));
    }
    return calendars;
  }

  String _lastSegment(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url.host : Uri.decodeComponent(segments.last);
  }

  /// Returns the collection's ctag, used to skip unchanged calendars.
  Future<String?> getCtag(Uri calendarUrl) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">'
        '<d:prop><cs:getctag/></d:prop></d:propfind>';
    final responses = await _multistatus('PROPFIND', calendarUrl, body, depth: 0);
    for (final r in responses) {
      final ctag = r.prop(calServerNs, 'getctag')?.innerText.trim();
      if (ctag != null && ctag.isNotEmpty) return ctag;
    }
    return null;
  }

  /// Fetches all events overlapping [start]..[end] using a calendar-query REPORT.
  Future<List<DavEventResource>> fetchEvents(Uri calendarUrl, DateTime start, DateTime end) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
        '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
        '<c:time-range start="${formatDateTimeUtc(start)}" end="${formatDateTimeUtc(end)}"/>'
        '</c:comp-filter></c:comp-filter></c:filter>'
        '</c:calendar-query>';
    final responses = await _multistatus('REPORT', calendarUrl, body, depth: 1);
    return [
      for (final r in responses)
        if (r.prop(calDavNs, 'calendar-data') != null)
          DavEventResource(
            url: calendarUrl.resolve(r.href),
            etag: r.prop(davNs, 'getetag')?.innerText.trim(),
            data: r.prop(calDavNs, 'calendar-data')!.innerText,
          ),
    ];
  }

  /// Creates ([create] = true) or updates an event. Returns the new ETag, if sent.
  Future<String?> putEvent(Uri resourceUrl, String ics, {String? etag, bool create = false}) async {
    final response = await _send('PUT', resourceUrl, headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      if (create) 'If-None-Match': '*' else 'If-Match': ?etag,
    }, body: ics);
    if (response.statusCode == 412) {
      throw DavException('De afspraak is op de server gewijzigd; synchroniseer eerst', statusCode: 412);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DavException('Opslaan op server mislukt', statusCode: response.statusCode);
    }
    return response.headers['etag'];
  }

  Future<void> deleteEvent(Uri resourceUrl, {String? etag}) async {
    final response = await _send('DELETE', resourceUrl, headers: {
      'If-Match': ?etag,
    });
    if (response.statusCode == 404) return;
    if (response.statusCode == 412) {
      throw DavException('De afspraak is op de server gewijzigd; synchroniseer eerst', statusCode: 412);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DavException('Verwijderen op server mislukt', statusCode: response.statusCode);
    }
  }
}
