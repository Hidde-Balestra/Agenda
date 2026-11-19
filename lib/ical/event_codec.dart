import '../models/models.dart';
import 'ical.dart';

const _prodId = '-//Agenda//Agenda App//NL';

/// Properties that are owned by [CalendarEvent] and rewritten on save.
const _managedProps = {
  'UID',
  'SUMMARY',
  'DESCRIPTION',
  'LOCATION',
  'DTSTART',
  'DTEND',
  'DURATION',
  'RRULE',
  'EXDATE',
  'DTSTAMP',
  'LAST-MODIFIED',
};

/// Parses all VEVENTs in [ics] into [CalendarEvent]s.
List<CalendarEvent> eventsFromIcs(
  String ics, {
  required String calendarId,
  String? href,
  String? etag,
}) {
  final root = parseICalendar(ics);
  final result = <CalendarEvent>[];
  for (final vevent in root.childrenNamed('VEVENT')) {
    final event = _eventFromComponent(vevent, calendarId: calendarId, href: href, etag: etag, raw: ics);
    if (event != null) result.add(event);
  }
  return result;
}

CalendarEvent? _eventFromComponent(
  ICalComponent c, {
  required String calendarId,
  String? href,
  String? etag,
  required String raw,
}) {
  final dtStartProp = c.prop('DTSTART');
  final uid = c.prop('UID')?.value;
  if (dtStartProp == null || uid == null) return null;
  final start = parseDateProperty(dtStartProp);

  DateTime end;
  final dtEndProp = c.prop('DTEND');
  final durationProp = c.prop('DURATION');
  if (dtEndProp != null) {
    end = parseDateProperty(dtEndProp).value;
  } else if (durationProp != null) {
    final d = parseDuration(durationProp.value);
    end = start.isDate
        ? DateTime(start.value.year, start.value.month, start.value.day + d.inDays)
        : start.value.add(d);
  } else {
    end = start.isDate
        ? DateTime(start.value.year, start.value.month, start.value.day + 1)
        : start.value;
  }

  final exdates = <DateTime>[];
  for (final p in c.props('EXDATE')) {
    for (final part in p.value.split(',')) {
      if (part.trim().isEmpty) continue;
      exdates.add(parseDateValue(part, valueType: p.param('VALUE')).value);
    }
  }

  final recurrenceIdProp = c.prop('RECURRENCE-ID');

  return CalendarEvent(
    uid: uid,
    calendarId: calendarId,
    title: unescapeText(c.prop('SUMMARY')?.value ?? ''),
    description: unescapeText(c.prop('DESCRIPTION')?.value ?? ''),
    location: unescapeText(c.prop('LOCATION')?.value ?? ''),
    start: start.value,
    end: end,
    allDay: start.isDate,
    rrule: c.prop('RRULE')?.value,
    exdates: exdates,
    recurrenceId: recurrenceIdProp == null ? null : parseDateProperty(recurrenceIdProp).value,
    href: href,
    etag: etag,
    rawIcs: raw,
  );
}

/// Builds the iCalendar text for [event]. When the event has [CalendarEvent.rawIcs],
/// the original document is patched so unknown properties and components
/// (alarms, attendees, overrides, time zones) are preserved.
String eventToIcs(CalendarEvent event, {DateTime? now}) {
  final stamp = now ?? DateTime.now();
  ICalComponent root;
  ICalComponent? target;

  if (event.rawIcs != null) {
    root = parseICalendar(event.rawIcs!);
    for (final c in root.childrenNamed('VEVENT')) {
      if (c.prop('UID')?.value != event.uid) continue;
      final rid = c.prop('RECURRENCE-ID');
      final ridValue = rid == null ? null : parseDateProperty(rid).value;
      if (ridValue == event.recurrenceId) {
        target = c;
        break;
      }
    }
  } else {
    root = ICalComponent('VCALENDAR', properties: [
      ICalProperty('VERSION', '2.0'),
      ICalProperty('PRODID', _prodId),
      ICalProperty('CALSCALE', 'GREGORIAN'),
    ]);
  }

  if (target == null) {
    target = ICalComponent('VEVENT');
    root.children.add(target);
  }

  final kept = target.properties.where((p) => !_managedProps.contains(p.name)).toList();
  target.properties
    ..clear()
    ..add(ICalProperty('UID', event.uid))
    ..add(ICalProperty('DTSTAMP', formatDateTimeUtc(stamp)))
    ..add(ICalProperty('LAST-MODIFIED', formatDateTimeUtc(stamp)))
    ..add(dateProperty('DTSTART', event.start, allDay: event.allDay))
    ..add(dateProperty('DTEND', event.end, allDay: event.allDay))
    ..add(ICalProperty('SUMMARY', escapeText(event.title)));
  if (event.description.isNotEmpty) {
    target.properties.add(ICalProperty('DESCRIPTION', escapeText(event.description)));
  }
  if (event.location.isNotEmpty) {
    target.properties.add(ICalProperty('LOCATION', escapeText(event.location)));
  }
  if (event.isRecurring && event.recurrenceId == null) {
    target.properties.add(ICalProperty('RRULE', event.rrule!));
    for (final ex in event.exdates) {
      target.properties.add(dateProperty('EXDATE', ex, allDay: event.allDay));
    }
  }
  target.properties.addAll(kept);

  // Overrides of a series that no longer recurs make no sense; drop them.
  if (event.recurrenceId == null && !event.isRecurring) {
    root.children.removeWhere((c) =>
        c.name == 'VEVENT' && c.prop('UID')?.value == event.uid && c.prop('RECURRENCE-ID') != null);
  }

  return root.serialize();
}

/// Returns an RRULE for a simple [RepeatFrequency], or null for [RepeatFrequency.none].
String? rruleFor(RepeatFrequency frequency) => switch (frequency) {
      RepeatFrequency.none => null,
      RepeatFrequency.daily => 'FREQ=DAILY',
      RepeatFrequency.weekly => 'FREQ=WEEKLY',
      RepeatFrequency.monthly => 'FREQ=MONTHLY',
      RepeatFrequency.yearly => 'FREQ=YEARLY',
    };
