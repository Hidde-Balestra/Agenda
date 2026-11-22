import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../dav/caldav_client.dart';
import '../data/stores.dart';
import '../ical/event_codec.dart';
import '../ical/recurrence.dart';
import '../models/models.dart';

typedef CalDavClientFactory = CalDavClient Function(Uri baseUri, String username, String password);

/// Default colors for calendars without a server-provided color.
const calendarPalette = [
  0xFF3F51B5,
  0xFF009688,
  0xFFE91E63,
  0xFFFF9800,
  0xFF8BC34A,
  0xFF9C27B0,
  0xFF00BCD4,
  0xFFF44336,
];

/// Parses `#RRGGBB` or `#RRGGBBAA` into an opaque ARGB int.
int? parseDavColor(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^#?([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$').firstMatch(value.trim());
  if (m == null) return null;
  return 0xFF000000 | int.parse(m[1]!, radix: 16);
}

/// Normalizes user input like `cloud.example.com` to `https://cloud.example.com/`.
Uri normalizeServerUrl(String input) {
  var text = input.trim();
  if (!text.contains('://')) text = 'https://$text';
  var uri = Uri.parse(text);
  if (uri.path.isEmpty) uri = uri.replace(path: '/');
  return uri;
}

class AgendaController extends ChangeNotifier {
  AgendaController({
    required KeyValueStore store,
    required KeyValueStore secrets,
    CalDavClientFactory? clientFactory,
    DateTime Function()? clock,
  })  : _store = store,
        _secrets = secrets,
        _clientFactory = clientFactory ??
            ((uri, user, pass) => CalDavClient(baseUri: uri, username: user, password: pass)),
        _clock = clock ?? DateTime.now;

  static const _accountsKey = 'agenda.accounts';
  static const _calendarsKey = 'agenda.calendars';
  static const _eventsKey = 'agenda.events';
  static const _defaultCalendarKey = 'agenda.defaultCalendar';
  static const _uuid = Uuid();

  final KeyValueStore _store;
  final KeyValueStore _secrets;
  final CalDavClientFactory _clientFactory;
  final DateTime Function() _clock;

  List<DavAccount> _accounts = [];
  List<CalendarInfo> _calendars = [];
  List<CalendarEvent> _events = [];
  final Map<String, Map<int, List<EventOccurrence>>> _monthCache = {};

  bool _syncing = false;
  String? _lastError;
  DateTime? _lastSync;
  String? _defaultCalendarId;

  List<DavAccount> get accounts => List.unmodifiable(_accounts);
  List<CalendarInfo> get calendars => List.unmodifiable(_calendars);
  List<CalendarEvent> get events => List.unmodifiable(_events);
  List<CalendarInfo> get writableCalendars => _calendars.where((c) => !c.readOnly).toList();

  /// Calendar preselected for new events: the user's choice if it still
  /// exists and is writable, otherwise the first writable calendar.
  CalendarInfo get defaultCalendar {
    final writable = writableCalendars;
    return writable.where((c) => c.id == _defaultCalendarId).firstOrNull ??
        writable.firstOrNull ??
        calendarById(localCalendarId)!;
  }
  bool get syncing => _syncing;
  String? get lastError => _lastError;
  DateTime? get lastSync => _lastSync;

  CalendarInfo? calendarById(String id) {
    for (final c in _calendars) {
      if (c.id == id) return c;
    }
    return null;
  }

  String _passwordKey(String accountId) => 'dav.password.$accountId';

  // ---------------------------------------------------------------- loading

  Future<void> load() async {
    List<T> decode<T>(String? raw, T Function(Map<String, dynamic>) f) => raw == null
        ? <T>[]
        : [for (final e in jsonDecode(raw) as List) f(e as Map<String, dynamic>)];

    _accounts = decode(await _store.read(_accountsKey), DavAccount.fromJson);
    _calendars = decode(await _store.read(_calendarsKey), CalendarInfo.fromJson);
    _events = decode(await _store.read(_eventsKey), CalendarEvent.fromJson);
    _defaultCalendarId = await _store.read(_defaultCalendarKey);

    if (calendarById(localCalendarId) == null) {
      _calendars.insert(
        0,
        const CalendarInfo(id: localCalendarId, name: 'Mijn agenda', colorValue: 0xFF3F51B5),
      );
      await _persistCalendars();
    }
    _invalidate();
  }

  Future<void> _persistAccounts() =>
      _store.write(_accountsKey, jsonEncode(_accounts.map((a) => a.toJson()).toList()));

  Future<void> _persistCalendars() =>
      _store.write(_calendarsKey, jsonEncode(_calendars.map((c) => c.toJson()).toList()));

  Future<void> _persistEvents() =>
      _store.write(_eventsKey, jsonEncode(_events.map((e) => e.toJson()).toList()));

  void _invalidate() {
    _monthCache.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- occurrences

  /// All visible occurrences touching [day], all-day events first.
  List<EventOccurrence> occurrencesForDay(DateTime day) {
    final key = '${day.year}-${day.month}';
    final month = _monthCache.putIfAbsent(key, () => _buildMonth(day.year, day.month));
    return month[day.day] ?? const [];
  }

  Map<int, List<EventOccurrence>> _buildMonth(int year, int month) {
    final from = DateTime(year, month);
    final to = DateTime(year, month + 1);
    final visible = {for (final c in _calendars) if (c.visible) c.id};

    // Instances overridden by a RECURRENCE-ID component are hidden from the series.
    final overrides = <String, List<DateTime>>{};
    for (final e in _events) {
      if (e.recurrenceId != null) {
        overrides.putIfAbsent('${e.calendarId}|${e.uid}', () => []).add(e.recurrenceId!);
      }
    }

    final result = <int, List<EventOccurrence>>{};
    for (final e in _events) {
      if (!visible.contains(e.calendarId)) continue;
      final occurrences = expandEvent(e, from, to, excluded: overrides['${e.calendarId}|${e.uid}'] ?? const []);
      for (final o in occurrences) {
        for (var d = 1; d <= DateTime(year, month + 1, 0).day; d++) {
          if (o.overlapsDay(DateTime(year, month, d))) result.putIfAbsent(d, () => []).add(o);
        }
      }
    }
    for (final list in result.values) {
      list.sort((a, b) {
        if (a.event.allDay != b.event.allDay) return a.event.allDay ? -1 : 1;
        final c = a.start.compareTo(b.start);
        return c != 0 ? c : a.event.title.compareTo(b.event.title);
      });
    }
    return result;
  }

  // ---------------------------------------------------------------- editing

  String newUid() => '${_uuid.v4()}@agenda';

  Future<CalDavClient> _clientForCalendar(CalendarInfo calendar) async {
    final account = _accounts.firstWhere((a) => a.id == calendar.accountId);
    return _clientFor(account);
  }

  Future<CalDavClient> _clientFor(DavAccount account) async {
    final password = await _secrets.read(_passwordKey(account.id)) ?? '';
    return _clientFactory(normalizeServerUrl(account.serverUrl), account.username, password);
  }

  /// Creates or updates [event]. Pass [original] when editing an existing event.
  Future<void> saveEvent(CalendarEvent event, {CalendarEvent? original}) async {
    if (original != null && original.calendarId != event.calendarId) {
      await _write(event.copyWith(href: () => null, etag: () => null));
      await deleteEvent(original);
      return;
    }
    await _write(event);
  }

  Future<void> _write(CalendarEvent event) async {
    final calendar = calendarById(event.calendarId);
    if (calendar == null) throw StateError('Onbekende agenda ${event.calendarId}');
    if (calendar.readOnly) throw DavException('Deze agenda is alleen-lezen');

    if (calendar.isLocal) {
      _events.removeWhere((e) => e.key == event.key);
      _events.add(event.copyWith(rawIcs: () => eventToIcs(event, now: _clock())));
    } else {
      final client = await _clientForCalendar(calendar);
      try {
        final create = event.href == null;
        final href = event.href != null
            ? Uri.parse(event.href!)
            : Uri.parse(calendar.href!).resolve('${Uri.encodeComponent(event.uid)}.ics');
        final ics = eventToIcs(event, now: _clock());
        final etag = await client.putEvent(href, ics, etag: event.etag, create: create);
        final parsed = eventsFromIcs(ics, calendarId: calendar.id, href: href.toString(), etag: etag);
        _events.removeWhere((e) => e.calendarId == calendar.id && e.href == href.toString());
        _events.addAll(parsed);
      } finally {
        client.close();
      }
    }
    await _persistEvents();
    _invalidate();
  }

  /// Deletes [event]; for recurring events the whole series is removed.
  Future<void> deleteEvent(CalendarEvent event) async {
    final calendar = calendarById(event.calendarId);
    if (calendar != null && !calendar.isLocal && event.href != null) {
      final client = await _clientForCalendar(calendar);
      try {
        await client.deleteEvent(Uri.parse(event.href!), etag: event.etag);
      } finally {
        client.close();
      }
      _events.removeWhere((e) => e.calendarId == event.calendarId && e.href == event.href);
    } else {
      _events.removeWhere((e) => e.calendarId == event.calendarId && e.uid == event.uid);
    }
    await _persistEvents();
    _invalidate();
  }

  Future<void> setDefaultCalendar(String calendarId) async {
    final calendar = calendarById(calendarId);
    if (calendar == null) throw StateError('Onbekende agenda $calendarId');
    if (calendar.readOnly) throw StateError('Alleen-lezen-agenda kan geen standaard zijn');
    _defaultCalendarId = calendarId;
    notifyListeners();
    await _store.write(_defaultCalendarKey, calendarId);
  }

  Future<void> setCalendarVisible(String calendarId, bool visible) async {
    _calendars = [for (final c in _calendars) c.id == calendarId ? c.copyWith(visible: visible) : c];
    await _persistCalendars();
    _invalidate();
  }

  // --------------------------------------------------------------- accounts

  /// Checks credentials and returns the calendars found on the server.
  Future<List<DavCalendar>> testAccount(String serverUrl, String username, String password) async {
    final client = _clientFactory(normalizeServerUrl(serverUrl), username, password);
    try {
      return await client.discoverCalendars();
    } finally {
      client.close();
    }
  }

  Future<DavAccount> addAccount({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final found = await testAccount(serverUrl, username, password);
    if (found.isEmpty) throw DavException('Geen agenda\'s gevonden op deze server');
    final account = DavAccount(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? normalizeServerUrl(serverUrl).host : name.trim(),
      serverUrl: serverUrl.trim(),
      username: username,
    );
    await _secrets.write(_passwordKey(account.id), password);
    _accounts.add(account);
    await _persistAccounts();
    _mergeCalendars(account, found);
    await _persistCalendars();
    _invalidate();
    await sync();
    return account;
  }

  Future<void> removeAccount(String accountId) async {
    final ids = {for (final c in _calendars) if (c.accountId == accountId) c.id};
    _accounts.removeWhere((a) => a.id == accountId);
    _calendars.removeWhere((c) => ids.contains(c.id));
    _events.removeWhere((e) => ids.contains(e.calendarId));
    await _secrets.delete(_passwordKey(accountId));
    await Future.wait([_persistAccounts(), _persistCalendars(), _persistEvents()]);
    _invalidate();
  }

  /// Updates the stored calendars of [account] to match [found]. Returns the
  /// ids of calendars that were removed on the server.
  Set<String> _mergeCalendars(DavAccount account, List<DavCalendar> found) {
    final existing = {for (final c in _calendars) if (c.accountId == account.id) c.id: c};
    final keep = <String>{};
    var paletteIndex = _calendars.length;
    for (final f in found) {
      final id = '${account.id}:${f.url}';
      keep.add(id);
      final previous = existing[id];
      final color = parseDavColor(f.color) ??
          previous?.colorValue ??
          calendarPalette[paletteIndex++ % calendarPalette.length];
      final info = CalendarInfo(
        id: id,
        name: f.displayName,
        colorValue: color,
        accountId: account.id,
        href: f.url.toString(),
        ctag: previous?.ctag,
        readOnly: f.readOnly,
        visible: previous?.visible ?? true,
      );
      final index = _calendars.indexWhere((c) => c.id == id);
      if (index >= 0) {
        _calendars[index] = info;
      } else {
        _calendars.add(info);
      }
    }
    final removed = existing.keys.where((id) => !keep.contains(id)).toSet();
    _calendars.removeWhere((c) => removed.contains(c.id));
    _events.removeWhere((e) => removed.contains(e.calendarId));
    return removed;
  }

  // ------------------------------------------------------------------- sync

  /// Pulls calendars and events from all DAV accounts.
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    _lastError = null;
    notifyListeners();

    final now = _clock();
    final rangeStart = DateTime(now.year - 1, now.month, now.day);
    final rangeEnd = DateTime(now.year + 2, now.month, now.day);
    final errors = <String>[];

    for (final account in List.of(_accounts)) {
      final client = await _clientFor(account);
      try {
        final found = await client.discoverCalendars();
        _mergeCalendars(account, found);
        for (final f in found) {
          final id = '${account.id}:${f.url}';
          final stored = calendarById(id)!;
          // Unchanged collection: skip the (expensive) REPORT.
          if (f.ctag != null && f.ctag == stored.ctag) continue;

          final resources = await client.fetchEvents(f.url, rangeStart, rangeEnd);
          final fresh = <CalendarEvent>[];
          for (final r in resources) {
            try {
              fresh.addAll(eventsFromIcs(r.data, calendarId: id, href: r.url.toString(), etag: r.etag));
            } on Exception catch (e) {
              debugPrint('Kon ${r.url} niet lezen: $e');
            }
          }
          _events
            ..removeWhere((e) => e.calendarId == id)
            ..addAll(fresh);
          _calendars = [for (final c in _calendars) c.id == id ? c.copyWith(ctag: f.ctag) : c];
        }
      } on DavException catch (e) {
        errors.add('${account.name}: ${e.message}');
      } finally {
        client.close();
      }
    }

    await Future.wait([_persistCalendars(), _persistEvents()]);
    _syncing = false;
    _lastError = errors.isEmpty ? null : errors.join('\n');
    if (errors.isEmpty) _lastSync = now;
    _invalidate();
  }
}
