import 'package:agenda/ical/event_codec.dart';
import 'package:agenda/ical/ical.dart';
import 'package:agenda/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_caldav_server.dart';

void main() {
  group('content lines', () {
    test('unfolds continuation lines', () {
      expect(unfoldLines('SUMMARY:Lange\r\n  titel\r\nUID:1\r\n'), ['SUMMARY:Lange titel', 'UID:1']);
    });

    test('folds long lines at 75 octets and round-trips', () {
      final line = 'DESCRIPTION:${'é' * 100}';
      final folded = foldLine(line);
      for (final part in folded.split('\r\n')) {
        expect(part.codeUnits.length, lessThanOrEqualTo(75));
      }
      expect(unfoldLines(folded).single, line);
    });

    test('parses parameters including quoted values with colons', () {
      final p = parseContentLine('ATTENDEE;CN="Doe, John";ROLE=REQ-PARTICIPANT:mailto:john@example.com');
      expect(p.name, 'ATTENDEE');
      expect(p.param('cn'), 'Doe, John');
      expect(p.param('ROLE'), 'REQ-PARTICIPANT');
      expect(p.value, 'mailto:john@example.com');
      expect(parseContentLine(p.serialize()).param('CN'), 'Doe, John');
    });

    test('escapes and unescapes text', () {
      const text = 'Regel 1\nKomma, puntkomma; backslash \\';
      expect(escapeText(text), r'Regel 1\nKomma\, puntkomma\; backslash \\');
      expect(unescapeText(escapeText(text)), text);
    });

    test('rejects unbalanced components', () {
      expect(() => parseICalendar('BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VCALENDAR\n'),
          throwsA(isA<ICalFormatException>()));
    });
  });

  group('dates', () {
    test('parses DATE, floating and UTC values', () {
      final date = parseDateValue('20261224');
      expect(date.isDate, isTrue);
      expect(date.value, DateTime(2026, 12, 24));

      expect(parseDateValue('20261224T153000').value, DateTime(2026, 12, 24, 15, 30));
      final utc = parseDateValue('20261224T153000Z').value;
      expect(utc.isUtc, isFalse);
      expect(utc.toUtc(), DateTime.utc(2026, 12, 24, 15, 30));
    });

    test('parses durations', () {
      expect(parseDuration('PT1H30M'), const Duration(hours: 1, minutes: 30));
      expect(parseDuration('P1W2D'), const Duration(days: 9));
      expect(parseDuration('-PT15M'), const Duration(minutes: -15));
    });
  });

  group('event codec', () {
    test('reads a timed event', () {
      final events = eventsFromIcs(
        sampleEvent(extra: 'LOCATION:Kerkstraat 1\\, Utrecht\r\nDESCRIPTION:Controle\\nNiet vergeten\r\n'),
        calendarId: 'c',
        href: 'https://x/e.ics',
        etag: '"1"',
      );
      final e = events.single;
      expect(e.uid, 'evt-1');
      expect(e.title, 'Tandarts');
      expect(e.location, 'Kerkstraat 1, Utrecht');
      expect(e.description, 'Controle\nNiet vergeten');
      expect(e.start.toUtc(), DateTime.utc(2026, 11, 20, 9));
      expect(e.end.difference(e.start), const Duration(hours: 1));
      expect(e.allDay, isFalse);
      expect(e.href, 'https://x/e.ics');
      expect(e.etag, '"1"');
    });

    test('reads all-day events and DURATION', () {
      const ics = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20261225\nSUMMARY:Kerst\n'
          'END:VEVENT\nBEGIN:VEVENT\nUID:b\nDTSTART:20261201T100000\nDURATION:PT45M\nSUMMARY:Call\n'
          'END:VEVENT\nEND:VCALENDAR\n';
      final events = eventsFromIcs(ics, calendarId: 'c');
      expect(events[0].allDay, isTrue);
      expect(events[0].start, DateTime(2026, 12, 25));
      expect(events[0].end, DateTime(2026, 12, 26));
      expect(events[1].end, DateTime(2026, 12, 1, 10, 45));
    });

    test('reads recurrence rules, exdates and overrides', () {
      const ics = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:r\nDTSTART:20261102T090000\nDTEND:20261102T093000\n'
          'RRULE:FREQ=WEEKLY;BYDAY=MO\nEXDATE:20261109T090000,20261116T090000\nSUMMARY:Standup\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:r\nRECURRENCE-ID:20261123T090000\nDTSTART:20261123T110000\n'
          'DTEND:20261123T113000\nSUMMARY:Standup (later)\nEND:VEVENT\nEND:VCALENDAR\n';
      final events = eventsFromIcs(ics, calendarId: 'c');
      expect(events, hasLength(2));
      expect(events[0].rrule, 'FREQ=WEEKLY;BYDAY=MO');
      expect(events[0].exdates, [DateTime(2026, 11, 9, 9), DateTime(2026, 11, 16, 9)]);
      expect(events[1].recurrenceId, DateTime(2026, 11, 23, 9));
      expect(events[0].repeatFrequency, RepeatFrequency.weekly);
    });

    test('writes a new event that parses back identically', () {
      final event = CalendarEvent(
        uid: 'new-1',
        calendarId: 'c',
        title: 'Verjaardag; feest',
        description: 'Taart\nmeenemen',
        location: 'Thuis',
        start: DateTime(2026, 5, 4),
        end: DateTime(2026, 5, 5),
        allDay: true,
        rrule: 'FREQ=YEARLY',
      );
      final ics = eventToIcs(event, now: DateTime.utc(2026, 1, 1));
      expect(ics, contains('DTSTART;VALUE=DATE:20260504'));
      expect(ics, contains('RRULE:FREQ=YEARLY'));
      expect(ics, contains('PRODID:'));
      final back = eventsFromIcs(ics, calendarId: 'c').single;
      expect(back.title, event.title);
      expect(back.description, event.description);
      expect(back.location, event.location);
      expect(back.start, event.start);
      expect(back.end, event.end);
      expect(back.allDay, isTrue);
      expect(back.rrule, 'FREQ=YEARLY');
    });

    test('preserves alarms, attendees and time zones when editing', () {
      final raw = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Other//EN\r\n'
          'BEGIN:VTIMEZONE\r\nTZID:Europe/Amsterdam\r\nEND:VTIMEZONE\r\n'
          'BEGIN:VEVENT\r\nUID:keep\r\nDTSTART:20261120T090000Z\r\nDTEND:20261120T100000Z\r\n'
          'SUMMARY:Oud\r\nATTENDEE;CN=Bob:mailto:bob@example.com\r\n'
          'BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT10M\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      final event = eventsFromIcs(raw, calendarId: 'c').single;
      final ics = eventToIcs(event.copyWith(title: 'Nieuw'));
      expect(ics, contains('SUMMARY:Nieuw'));
      expect(ics, isNot(contains('SUMMARY:Oud')));
      expect(ics, contains('ATTENDEE;CN=Bob:mailto:bob@example.com'));
      expect(ics, contains('TRIGGER:-PT10M'));
      expect(ics, contains('TZID:Europe/Amsterdam'));
      expect(ics, contains('PRODID:-//Other//EN'));
      expect(RegExp('BEGIN:VEVENT').allMatches(ics), hasLength(1));
    });

    test('removing recurrence drops overrides', () {
      const raw = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:r\nDTSTART:20261102T090000\nDTEND:20261102T093000\n'
          'RRULE:FREQ=DAILY\nSUMMARY:S\nEND:VEVENT\nBEGIN:VEVENT\nUID:r\nRECURRENCE-ID:20261103T090000\n'
          'DTSTART:20261103T100000\nDTEND:20261103T103000\nSUMMARY:S2\nEND:VEVENT\nEND:VCALENDAR\n';
      final master = eventsFromIcs(raw, calendarId: 'c').first;
      final ics = eventToIcs(master.copyWith(rrule: () => null));
      expect(ics, isNot(contains('RECURRENCE-ID')));
      expect(ics, isNot(contains('RRULE')));
    });

    test('rruleFor maps simple frequencies', () {
      expect(rruleFor(RepeatFrequency.none), isNull);
      expect(rruleFor(RepeatFrequency.monthly), 'FREQ=MONTHLY');
    });
  });
}
