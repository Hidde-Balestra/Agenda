import 'package:agenda/ical/recurrence.dart';
import 'package:agenda/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarEvent _event(DateTime start, {Duration length = const Duration(hours: 1), String? rrule, bool allDay = false,
        List<DateTime> exdates = const []}) =>
    CalendarEvent(
      uid: 'u',
      calendarId: 'c',
      title: 't',
      start: start,
      end: allDay ? DateTime(start.year, start.month, start.day + 1) : start.add(length),
      allDay: allDay,
      rrule: rrule,
      exdates: exdates,
    );

List<DateTime> _starts(CalendarEvent e, DateTime from, DateTime to, {List<DateTime> excluded = const []}) =>
    expandEvent(e, from, to, excluded: excluded).map((o) => o.start).toList();

void main() {
  final jan = DateTime(2026, 1);
  final dec = DateTime(2027, 1);

  test('non-recurring event inside and outside the range', () {
    final e = _event(DateTime(2026, 3, 10, 9));
    expect(_starts(e, jan, dec), [DateTime(2026, 3, 10, 9)]);
    expect(_starts(e, DateTime(2026, 4), dec), isEmpty);
  });

  test('event spanning the range start is included', () {
    final e = _event(DateTime(2026, 3, 31, 22), length: const Duration(hours: 4));
    expect(expandEvent(e, DateTime(2026, 4), DateTime(2026, 5)), hasLength(1));
  });

  test('daily with COUNT', () {
    final e = _event(DateTime(2026, 1, 30, 8), rrule: 'FREQ=DAILY;COUNT=4');
    expect(_starts(e, jan, dec), [
      DateTime(2026, 1, 30, 8),
      DateTime(2026, 1, 31, 8),
      DateTime(2026, 2, 1, 8),
      DateTime(2026, 2, 2, 8),
    ]);
  });

  test('COUNT is respected when the range starts later', () {
    final e = _event(DateTime(2026, 1, 1, 8), rrule: 'FREQ=DAILY;COUNT=10');
    expect(_starts(e, DateTime(2026, 1, 9), dec), [DateTime(2026, 1, 9, 8), DateTime(2026, 1, 10, 8)]);
  });

  test('weekly on several days with interval and UNTIL', () {
    // 2026-01-05 is a Monday.
    final e = _event(DateTime(2026, 1, 5, 18), rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;UNTIL=20260131T235959Z');
    expect(_starts(e, jan, dec), [
      DateTime(2026, 1, 5, 18),
      DateTime(2026, 1, 8, 18),
      DateTime(2026, 1, 19, 18),
      DateTime(2026, 1, 22, 18),
    ]);
  });

  test('weekly BYDAY before DTSTART weekday is skipped in the first week', () {
    // 2026-01-07 is a Wednesday; Monday of that week precedes DTSTART.
    final e = _event(DateTime(2026, 1, 7, 9), rrule: 'FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3');
    expect(_starts(e, jan, dec), [DateTime(2026, 1, 7, 9), DateTime(2026, 1, 12, 9), DateTime(2026, 1, 14, 9)]);
  });

  test('monthly on the 31st skips short months', () {
    final e = _event(DateTime(2026, 1, 31, 12), rrule: 'FREQ=MONTHLY;COUNT=4');
    expect(_starts(e, jan, dec), [
      DateTime(2026, 1, 31, 12),
      DateTime(2026, 3, 31, 12),
      DateTime(2026, 5, 31, 12),
      DateTime(2026, 7, 31, 12),
    ]);
  });

  test('monthly on the last Friday', () {
    final e = _event(DateTime(2026, 1, 30, 16), rrule: 'FREQ=MONTHLY;BYDAY=-1FR;COUNT=3');
    expect(_starts(e, jan, dec), [DateTime(2026, 1, 30, 16), DateTime(2026, 2, 27, 16), DateTime(2026, 3, 27, 16)]);
  });

  test('monthly on the second Tuesday', () {
    final e = _event(DateTime(2026, 1, 13, 19), rrule: 'FREQ=MONTHLY;BYDAY=2TU;COUNT=2');
    expect(_starts(e, jan, dec), [DateTime(2026, 1, 13, 19), DateTime(2026, 2, 10, 19)]);
  });

  test('yearly all-day birthday keeps its length', () {
    final e = _event(DateTime(2020, 5, 4), rrule: 'FREQ=YEARLY', allDay: true);
    final o = expandEvent(e, jan, dec).single;
    expect(o.start, DateTime(2026, 5, 4));
    expect(o.end, DateTime(2026, 5, 5));
  });

  test('yearly on Feb 29 only occurs in leap years', () {
    final e = _event(DateTime(2024, 2, 29), rrule: 'FREQ=YEARLY', allDay: true);
    expect(_starts(e, DateTime(2025), DateTime(2029)), [DateTime(2028, 2, 29)]);
  });

  test('EXDATE and overridden instances are excluded', () {
    final e = _event(DateTime(2026, 2, 2, 9),
        rrule: 'FREQ=DAILY;COUNT=5', exdates: [DateTime(2026, 2, 3, 9)]);
    expect(_starts(e, jan, dec, excluded: [DateTime(2026, 2, 5, 9)]), [
      DateTime(2026, 2, 2, 9),
      DateTime(2026, 2, 4, 9),
      DateTime(2026, 2, 6, 9),
    ]);
  });

  test('infinite rules stop at the range end', () {
    final e = _event(DateTime(2000, 1, 1, 9), rrule: 'FREQ=DAILY');
    final result = expandEvent(e, DateTime(2026, 6), DateTime(2026, 7));
    expect(result, hasLength(30));
  });

  test('invalid rules fall back to the single first instance', () {
    final e = _event(DateTime(2026, 3, 1, 9), rrule: 'INTERVAL=2');
    expect(_starts(e, jan, dec), [DateTime(2026, 3, 1, 9)]);
  });

  test('overlapsDay handles multi-day and zero-length events', () {
    final multi = EventOccurrence(_event(DateTime(2026, 1, 1)), DateTime(2026, 1, 1, 22), DateTime(2026, 1, 2, 2));
    expect(multi.overlapsDay(DateTime(2026, 1, 1)), isTrue);
    expect(multi.overlapsDay(DateTime(2026, 1, 2)), isTrue);
    expect(multi.overlapsDay(DateTime(2026, 1, 3)), isFalse);

    final point = EventOccurrence(_event(DateTime(2026, 1, 1)), DateTime(2026, 1, 1, 12), DateTime(2026, 1, 1, 12));
    expect(point.overlapsDay(DateTime(2026, 1, 1)), isTrue);
  });
}
