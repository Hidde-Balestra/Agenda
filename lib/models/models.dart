/// Identifier of the built-in, device-only calendar.
const localCalendarId = 'local';

class DavAccount {
  const DavAccount({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
  });

  final String id;
  final String name;
  final String serverUrl;
  final String username;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'serverUrl': serverUrl,
        'username': username,
      };

  factory DavAccount.fromJson(Map<String, dynamic> json) => DavAccount(
        id: json['id'] as String,
        name: json['name'] as String,
        serverUrl: json['serverUrl'] as String,
        username: json['username'] as String,
      );
}

class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.name,
    required this.colorValue,
    this.accountId,
    this.href,
    this.ctag,
    this.readOnly = false,
    this.visible = true,
  });

  final String id;
  final String name;
  final int colorValue;
  final String? accountId;

  /// Absolute URL of the CalDAV collection; null for the local calendar.
  final String? href;
  final String? ctag;
  final bool readOnly;
  final bool visible;

  bool get isLocal => accountId == null;

  CalendarInfo copyWith({String? name, int? colorValue, String? ctag, bool? readOnly, bool? visible}) =>
      CalendarInfo(
        id: id,
        name: name ?? this.name,
        colorValue: colorValue ?? this.colorValue,
        accountId: accountId,
        href: href,
        ctag: ctag ?? this.ctag,
        readOnly: readOnly ?? this.readOnly,
        visible: visible ?? this.visible,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': colorValue,
        'accountId': accountId,
        'href': href,
        'ctag': ctag,
        'readOnly': readOnly,
        'visible': visible,
      };

  factory CalendarInfo.fromJson(Map<String, dynamic> json) => CalendarInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        colorValue: json['color'] as int,
        accountId: json['accountId'] as String?,
        href: json['href'] as String?,
        ctag: json['ctag'] as String?,
        readOnly: json['readOnly'] as bool? ?? false,
        visible: json['visible'] as bool? ?? true,
      );
}

/// Simple repeat options offered by the editor.
enum RepeatFrequency { none, daily, weekly, monthly, yearly }

class CalendarEvent {
  const CalendarEvent({
    required this.uid,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.description = '',
    this.location = '',
    this.rrule,
    this.exdates = const [],
    this.recurrenceId,
    this.href,
    this.etag,
    this.rawIcs,
  });

  final String uid;
  final String calendarId;
  final String title;
  final String description;
  final String location;

  /// Start (inclusive) in local time. For all-day events: midnight of the first day.
  final DateTime start;

  /// End (exclusive) in local time. For all-day events: midnight after the last day.
  final DateTime end;
  final bool allDay;

  /// Raw RRULE value (without the `RRULE:` prefix), if recurring.
  final String? rrule;
  final List<DateTime> exdates;

  /// Set when this event overrides a single occurrence of a recurring series.
  final DateTime? recurrenceId;

  /// Absolute URL of the CalDAV resource holding this event.
  final String? href;
  final String? etag;

  /// Original iCalendar text, kept so that unknown data (alarms, attendees…)
  /// survives an edit.
  final String? rawIcs;

  String get key => '$calendarId|$uid|${recurrenceId?.toIso8601String() ?? ''}';

  bool get isRecurring => rrule != null && rrule!.isNotEmpty;

  RepeatFrequency get repeatFrequency {
    if (!isRecurring) return RepeatFrequency.none;
    final freq = RegExp(r'FREQ=([A-Z]+)').firstMatch(rrule!.toUpperCase())?.group(1);
    return switch (freq) {
      'DAILY' => RepeatFrequency.daily,
      'WEEKLY' => RepeatFrequency.weekly,
      'MONTHLY' => RepeatFrequency.monthly,
      'YEARLY' => RepeatFrequency.yearly,
      _ => RepeatFrequency.none,
    };
  }

  CalendarEvent copyWith({
    String? uid,
    String? calendarId,
    String? title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? Function()? rrule,
    List<DateTime>? exdates,
    String? Function()? href,
    String? Function()? etag,
    String? Function()? rawIcs,
  }) =>
      CalendarEvent(
        uid: uid ?? this.uid,
        calendarId: calendarId ?? this.calendarId,
        title: title ?? this.title,
        description: description ?? this.description,
        location: location ?? this.location,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        rrule: rrule != null ? rrule() : this.rrule,
        exdates: exdates ?? this.exdates,
        recurrenceId: recurrenceId,
        href: href != null ? href() : this.href,
        etag: etag != null ? etag() : this.etag,
        rawIcs: rawIcs != null ? rawIcs() : this.rawIcs,
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'calendarId': calendarId,
        'title': title,
        'description': description,
        'location': location,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'allDay': allDay,
        'rrule': rrule,
        'exdates': exdates.map((d) => d.toIso8601String()).toList(),
        'recurrenceId': recurrenceId?.toIso8601String(),
        'href': href,
        'etag': etag,
        'rawIcs': rawIcs,
      };

  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
        uid: json['uid'] as String,
        calendarId: json['calendarId'] as String,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        location: json['location'] as String? ?? '',
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        allDay: json['allDay'] as bool? ?? false,
        rrule: json['rrule'] as String?,
        exdates: [for (final d in (json['exdates'] as List? ?? const [])) DateTime.parse(d as String)],
        recurrenceId: json['recurrenceId'] == null ? null : DateTime.parse(json['recurrenceId'] as String),
        href: json['href'] as String?,
        etag: json['etag'] as String?,
        rawIcs: json['rawIcs'] as String?,
      );
}

/// A concrete occurrence of an event (one instance of a recurring series).
class EventOccurrence {
  const EventOccurrence(this.event, this.start, this.end);
  final CalendarEvent event;
  final DateTime start;
  final DateTime end;

  bool overlapsDay(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    if (!end.isAfter(start)) {
      return !start.isBefore(dayStart) && start.isBefore(dayEnd);
    }
    return start.isBefore(dayEnd) && end.isAfter(dayStart);
  }
}
