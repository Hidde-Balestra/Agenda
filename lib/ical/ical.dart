import 'dart:convert';

/// A single iCalendar content line: `NAME;PARAM=VALUE:value`.
class ICalProperty {
  ICalProperty(String name, this.value, [Map<String, String>? params])
      : name = name.toUpperCase(),
        params = {
          for (final e in (params ?? const {}).entries) e.key.toUpperCase(): e.value,
        };

  final String name;
  final Map<String, String> params;
  String value;

  String? param(String key) => params[key.toUpperCase()];

  String serialize() {
    final buffer = StringBuffer(name);
    params.forEach((key, value) {
      final needsQuotes = value.contains(RegExp(r'[;:,]'));
      buffer
        ..write(';')
        ..write(key)
        ..write('=')
        ..write(needsQuotes ? '"$value"' : value);
    });
    buffer
      ..write(':')
      ..write(value);
    return buffer.toString();
  }
}

/// A component such as VCALENDAR, VEVENT or VALARM.
class ICalComponent {
  ICalComponent(String name, {List<ICalProperty>? properties, List<ICalComponent>? children})
      : name = name.toUpperCase(),
        properties = properties ?? [],
        children = children ?? [];

  final String name;
  final List<ICalProperty> properties;
  final List<ICalComponent> children;

  ICalProperty? prop(String name) {
    final upper = name.toUpperCase();
    for (final p in properties) {
      if (p.name == upper) return p;
    }
    return null;
  }

  List<ICalProperty> props(String name) {
    final upper = name.toUpperCase();
    return properties.where((p) => p.name == upper).toList();
  }

  void removeProps(String name) {
    final upper = name.toUpperCase();
    properties.removeWhere((p) => p.name == upper);
  }

  /// Replaces every property with the same name by [property], keeping the
  /// position of the first existing occurrence.
  void setProp(ICalProperty property) {
    final index = properties.indexWhere((p) => p.name == property.name);
    removeProps(property.name);
    if (index < 0 || index > properties.length) {
      properties.add(property);
    } else {
      properties.insert(index, property);
    }
  }

  Iterable<ICalComponent> childrenNamed(String name) {
    final upper = name.toUpperCase();
    return children.where((c) => c.name == upper);
  }

  String serialize() {
    final lines = <String>[];
    _writeLines(lines);
    return '${lines.map(foldLine).join('\r\n')}\r\n';
  }

  void _writeLines(List<String> lines) {
    lines.add('BEGIN:$name');
    for (final p in properties) {
      lines.add(p.serialize());
    }
    for (final c in children) {
      c._writeLines(lines);
    }
    lines.add('END:$name');
  }
}

class ICalFormatException implements Exception {
  ICalFormatException(this.message);
  final String message;
  @override
  String toString() => 'ICalFormatException: $message';
}

/// Unfolds content lines (RFC 5545 §3.1).
List<String> unfoldLines(String text) {
  final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final result = <String>[];
  for (final line in raw) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && result.isNotEmpty) {
      result[result.length - 1] += line.substring(1);
    } else if (line.isNotEmpty) {
      result.add(line);
    }
  }
  return result;
}

/// Folds a content line so that no line exceeds 75 octets.
String foldLine(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final buffer = StringBuffer();
  var current = 0;
  var limit = 75;
  for (final rune in line.runes) {
    final char = String.fromCharCode(rune);
    final size = utf8.encode(char).length;
    if (current + size > limit) {
      buffer.write('\r\n ');
      current = 0;
      limit = 74; // the leading space counts as one octet
    }
    buffer.write(char);
    current += size;
  }
  return buffer.toString();
}

ICalProperty parseContentLine(String line) {
  var i = 0;
  var inQuotes = false;
  int? colon;
  final separators = <int>[];
  for (; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      inQuotes = !inQuotes;
    } else if (!inQuotes && c == ';') {
      separators.add(i);
    } else if (!inQuotes && c == ':') {
      colon = i;
      break;
    }
  }
  if (colon == null) {
    throw ICalFormatException('Ongeldige regel: $line');
  }
  final head = line.substring(0, colon);
  final value = line.substring(colon + 1);
  final nameEnd = separators.isEmpty ? head.length : separators.first;
  final name = head.substring(0, nameEnd);
  final params = <String, String>{};
  for (var s = 0; s < separators.length; s++) {
    final start = separators[s] + 1;
    final end = s + 1 < separators.length ? separators[s + 1] : head.length;
    final part = head.substring(start, end);
    final eq = part.indexOf('=');
    if (eq < 0) continue;
    var paramValue = part.substring(eq + 1);
    if (paramValue.length >= 2 && paramValue.startsWith('"') && paramValue.endsWith('"')) {
      paramValue = paramValue.substring(1, paramValue.length - 1);
    }
    params[part.substring(0, eq)] = paramValue;
  }
  return ICalProperty(name, value, params);
}

/// Parses iCalendar text and returns the root component (normally VCALENDAR).
ICalComponent parseICalendar(String text) {
  final stack = <ICalComponent>[];
  ICalComponent? root;
  for (final line in unfoldLines(text)) {
    final prop = parseContentLine(line);
    if (prop.name == 'BEGIN') {
      final component = ICalComponent(prop.value);
      if (stack.isNotEmpty) {
        stack.last.children.add(component);
      } else {
        root ??= component;
      }
      stack.add(component);
    } else if (prop.name == 'END') {
      if (stack.isEmpty || stack.last.name != prop.value.toUpperCase()) {
        throw ICalFormatException('Onverwacht END:${prop.value}');
      }
      stack.removeLast();
    } else if (stack.isNotEmpty) {
      stack.last.properties.add(prop);
    }
  }
  if (root == null) throw ICalFormatException('Geen BEGIN-component gevonden');
  if (stack.isNotEmpty) throw ICalFormatException('Component ${stack.last.name} niet afgesloten');
  return root;
}

String escapeText(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\r\n', '\n')
    .replaceAll('\n', '\\n');

String unescapeText(String text) {
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\\' && i + 1 < text.length) {
      final next = text[++i];
      switch (next) {
        case 'n':
        case 'N':
          buffer.write('\n');
        default:
          buffer.write(next);
      }
    } else {
      buffer.write(c);
    }
  }
  return buffer.toString();
}

/// A parsed DATE or DATE-TIME value. Times are converted to local time.
///
/// Values with a TZID are interpreted as device-local time (no tz database).
class ICalDateValue {
  ICalDateValue(this.value, {required this.isDate});
  final DateTime value;
  final bool isDate;
}

final _dateRe = RegExp(r'^(\d{4})(\d{2})(\d{2})$');
final _dateTimeRe = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$');

ICalDateValue parseDateValue(String raw, {String? valueType}) {
  final text = raw.trim();
  final dateMatch = _dateRe.firstMatch(text);
  if (dateMatch != null) {
    return ICalDateValue(
      DateTime(int.parse(dateMatch[1]!), int.parse(dateMatch[2]!), int.parse(dateMatch[3]!)),
      isDate: true,
    );
  }
  final m = _dateTimeRe.firstMatch(text);
  if (m == null) throw ICalFormatException('Ongeldige datum: $raw');
  final parts = [for (var g = 1; g <= 6; g++) int.parse(m[g]!)];
  final dt = m[7] == 'Z'
      ? DateTime.utc(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).toLocal()
      : DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  return ICalDateValue(dt, isDate: valueType?.toUpperCase() == 'DATE');
}

ICalDateValue parseDateProperty(ICalProperty p) => parseDateValue(p.value, valueType: p.param('VALUE'));

String _two(int v) => v.toString().padLeft(2, '0');

String formatDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';

String formatDateTimeUtc(DateTime d) {
  final u = d.toUtc();
  return '${formatDate(u)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
}

ICalProperty dateProperty(String name, DateTime value, {required bool allDay}) => allDay
    ? ICalProperty(name, formatDate(value), {'VALUE': 'DATE'})
    : ICalProperty(name, formatDateTimeUtc(value));

final _durationRe = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$');

Duration parseDuration(String raw) {
  final m = _durationRe.firstMatch(raw.trim());
  if (m == null) throw ICalFormatException('Ongeldige duur: $raw');
  int g(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(days: g(2) * 7 + g(3), hours: g(4), minutes: g(5), seconds: g(6));
  return m[1] == '-' ? -d : d;
}
