import '../models/models.dart';
import 'ical.dart';

const _maxIterations = 10000;

const _weekdays = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

class ByDayRule {
  const ByDayRule(this.weekday, this.ordinal);
  final int weekday;
  final int? ordinal;
}

class RecurrenceRule {
  RecurrenceRule({
    required this.freq,
    this.interval = 1,
    this.count,
    this.until,
    this.byDay = const [],
    this.byMonthDay = const [],
    this.byMonth = const [],
  });

  final String freq;
  final int interval;
  final int? count;
  final DateTime? until;
  final List<ByDayRule> byDay;
  final List<int> byMonthDay;
  final List<int> byMonth;

  static RecurrenceRule parse(String rrule) {
    final parts = <String, String>{};
    for (final part in rrule.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) parts[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1);
    }
    final freq = parts['FREQ']?.toUpperCase();
    if (freq == null) throw ICalFormatException('RRULE zonder FREQ');
    final byDay = <ByDayRule>[];
    for (final d in (parts['BYDAY'] ?? '').split(',')) {
      final m = RegExp(r'^([+-]?\d+)?([A-Z]{2})$').firstMatch(d.trim().toUpperCase());
      if (m == null || !_weekdays.containsKey(m[2])) continue;
      byDay.add(ByDayRule(_weekdays[m[2]]!, m[1] == null ? null : int.parse(m[1]!)));
    }
    List<int> ints(String? v) =>
        [for (final s in (v ?? '').split(',')) if (int.tryParse(s.trim()) != null) int.parse(s.trim())];
    return RecurrenceRule(
      freq: freq,
      interval: int.tryParse(parts['INTERVAL'] ?? '') ?? 1,
      count: int.tryParse(parts['COUNT'] ?? ''),
      until: parts['UNTIL'] == null ? null : parseDateValue(parts['UNTIL']!).value,
      byDay: byDay,
      byMonthDay: ints(parts['BYMONTHDAY']),
      byMonth: ints(parts['BYMONTH']),
    );
  }
}

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

DateTime _withTime(DateTime date, DateTime time) =>
    DateTime(date.year, date.month, date.day, time.hour, time.minute, time.second);

/// Candidates for the [n]th period, sorted, all with the time of [start].
List<DateTime> _periodCandidates(RecurrenceRule rule, DateTime start, int n) {
  final step = n * rule.interval;
  switch (rule.freq) {
    case 'DAILY':
      final d = DateTime(start.year, start.month, start.day + step, start.hour, start.minute, start.second);
      if (rule.byMonth.isNotEmpty && !rule.byMonth.contains(d.month)) return const [];
      if (rule.byDay.isNotEmpty && !rule.byDay.any((b) => b.weekday == d.weekday)) return const [];
      return [d];
    case 'WEEKLY':
      final weekStart = DateTime(start.year, start.month, start.day - (start.weekday - 1) + step * 7);
      final days = rule.byDay.isEmpty ? [start.weekday] : rule.byDay.map((b) => b.weekday).toSet().toList()
        ..sort();
      return [
        for (final wd in days)
          _withTime(DateTime(weekStart.year, weekStart.month, weekStart.day + wd - 1), start),
      ];
    case 'MONTHLY':
      final month = DateTime(start.year, start.month + step);
      return _monthCandidates(rule, start, month.year, month.month);
    case 'YEARLY':
      final year = start.year + step;
      final months = rule.byMonth.isEmpty ? [start.month] : rule.byMonth;
      final result = <DateTime>[];
      for (final m in months) {
        if (rule.byDay.isEmpty && rule.byMonthDay.isEmpty) {
          if (start.day <= _daysInMonth(year, m)) {
            result.add(DateTime(year, m, start.day, start.hour, start.minute, start.second));
          }
        } else {
          result.addAll(_monthCandidates(rule, start, year, m));
        }
      }
      return result..sort();
    default:
      return const [];
  }
}

List<DateTime> _monthCandidates(RecurrenceRule rule, DateTime start, int year, int month) {
  final dim = _daysInMonth(year, month);
  final days = <int>{};
  if (rule.byDay.isNotEmpty) {
    for (final b in rule.byDay) {
      final matching = [
        for (var d = 1; d <= dim; d++)
          if (DateTime(year, month, d).weekday == b.weekday) d,
      ];
      if (b.ordinal == null) {
        days.addAll(matching);
      } else {
        final idx = b.ordinal! > 0 ? b.ordinal! - 1 : matching.length + b.ordinal!;
        if (idx >= 0 && idx < matching.length) days.add(matching[idx]);
      }
    }
    if (rule.byMonthDay.isNotEmpty) {
      days.retainWhere((d) => rule.byMonthDay.any((md) => (md > 0 ? md : dim + md + 1) == d));
    }
  } else {
    final wanted = rule.byMonthDay.isEmpty ? [start.day] : rule.byMonthDay;
    for (final md in wanted) {
      final d = md > 0 ? md : dim + md + 1;
      if (d >= 1 && d <= dim) days.add(d);
    }
  }
  final sorted = days.toList()..sort();
  return [for (final d in sorted) DateTime(year, month, d, start.hour, start.minute, start.second)];
}

bool _sameInstant(DateTime a, DateTime b, bool allDay) => allDay
    ? a.year == b.year && a.month == b.month && a.day == b.day
    : a.isAtSameMomentAs(b);

/// Expands [event] into occurrences overlapping [from]..[to].
///
/// [excluded] contains recurrence-ids of overridden instances.
List<EventOccurrence> expandEvent(
  CalendarEvent event,
  DateTime from,
  DateTime to, {
  Iterable<DateTime> excluded = const [],
}) {
  final duration = event.end.difference(event.start);
  final allDayDays = event.allDay
      ? DateTime.utc(event.end.year, event.end.month, event.end.day)
          .difference(DateTime.utc(event.start.year, event.start.month, event.start.day))
          .inDays
      : 0;

  EventOccurrence make(DateTime s) => EventOccurrence(
        event,
        s,
        event.allDay ? DateTime(s.year, s.month, s.day + allDayDays) : s.add(duration),
      );

  bool overlaps(EventOccurrence o) =>
      o.start.isBefore(to) && (o.end.isAfter(from) || (!o.end.isAfter(o.start) && !o.start.isBefore(from)));

  if (!event.isRecurring || event.recurrenceId != null) {
    final o = make(event.start);
    return overlaps(o) ? [o] : const [];
  }

  RecurrenceRule rule;
  try {
    rule = RecurrenceRule.parse(event.rrule!);
  } on ICalFormatException {
    final o = make(event.start);
    return overlaps(o) ? [o] : const [];
  }

  final skip = [...event.exdates, ...excluded];
  final result = <EventOccurrence>[];
  var produced = 0;
  for (var n = 0; n < _maxIterations; n++) {
    final candidates = _periodCandidates(rule, event.start, n);
    var periodStart = candidates.isEmpty ? null : candidates.first;
    for (final c in candidates) {
      if (c.isBefore(event.start)) continue;
      if (rule.until != null && c.isAfter(rule.until!)) return result;
      produced++;
      if (rule.count != null && produced > rule.count!) return result;
      if (skip.any((s) => _sameInstant(s, c, event.allDay))) continue;
      final o = make(c);
      if (!o.start.isBefore(to)) return result;
      if (overlaps(o)) result.add(o);
    }
    // Guard against rules that never produce candidates in range.
    if (periodStart != null && !periodStart.isBefore(to) && rule.count == null) return result;
  }
  return result;
}
