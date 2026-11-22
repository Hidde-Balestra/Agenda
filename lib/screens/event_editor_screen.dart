import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../ical/event_codec.dart';
import '../models/models.dart';
import '../state/agenda_controller.dart';

const repeatLabels = {
  RepeatFrequency.none: 'Niet herhalen',
  RepeatFrequency.daily: 'Elke dag',
  RepeatFrequency.weekly: 'Elke week',
  RepeatFrequency.monthly: 'Elke maand',
  RepeatFrequency.yearly: 'Elk jaar',
};

class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({super.key, this.event, required this.initialDay});

  /// The event to edit, or null to create a new one.
  final CalendarEvent? event;
  final DateTime initialDay;

  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _description;
  late DateTime _start;
  late DateTime _end;
  late bool _allDay;
  late String _calendarId;
  late RepeatFrequency _repeat;
  bool _saving = false;

  bool get _isNew => widget.event == null;

  /// Complex server-side rules (e.g. "every 2nd Tuesday") are kept untouched
  /// unless the user picks another repeat option.
  late final bool _hasCustomRule;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    final agenda = context.read<AgendaController>();
    _title = TextEditingController(text: e?.title ?? '');
    _location = TextEditingController(text: e?.location ?? '');
    _description = TextEditingController(text: e?.description ?? '');
    if (e != null) {
      _start = e.start;
      _allDay = e.allDay;
      // Show all-day end inclusively in the UI.
      _end = e.allDay ? DateTime(e.end.year, e.end.month, e.end.day - 1) : e.end;
      _calendarId = e.calendarId;
      _repeat = e.repeatFrequency;
      _hasCustomRule = e.isRecurring && e.rrule!.toUpperCase() != rruleFor(_repeat);
    } else {
      final now = DateTime.now();
      final d = widget.initialDay;
      // Next full hour, but never past 23:00 so the event stays on the chosen day.
      _start = DateTime(d.year, d.month, d.day, now.hour < 23 ? now.hour + 1 : 23);
      _end = _start.add(const Duration(hours: 1));
      _allDay = false;
      _calendarId = agenda.defaultCalendar.id;
      _repeat = RepeatFrequency.none;
      _hasCustomRule = false;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null) return;
    setState(() {
      final updated = DateTime(picked.year, picked.month, picked.day, current.hour, current.minute);
      if (start) {
        final length = _end.difference(_start);
        _start = updated;
        _end = updated.add(length);
      } else {
        _end = updated;
      }
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (picked == null) return;
    setState(() {
      final updated = DateTime(current.year, current.month, current.day, picked.hour, picked.minute);
      if (start) {
        final length = _end.difference(_start);
        _start = updated;
        _end = updated.add(length);
      } else {
        _end = updated;
      }
    });
  }

  String? _validateRange() {
    if (_allDay) {
      final s = DateTime(_start.year, _start.month, _start.day);
      final e = DateTime(_end.year, _end.month, _end.day);
      return e.isBefore(s) ? 'De einddatum ligt voor de begindatum' : null;
    }
    return _end.isBefore(_start) ? 'Het einde ligt voor het begin' : null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final rangeError = _validateRange();
    if (rangeError != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(rangeError)));
      return;
    }
    final agenda = context.read<AgendaController>();
    final original = widget.event;

    final start = _allDay ? DateTime(_start.year, _start.month, _start.day) : _start;
    final end = _allDay ? DateTime(_end.year, _end.month, _end.day + 1) : _end;
    final keepRule = _hasCustomRule && _repeat == original?.repeatFrequency;
    final rrule = keepRule ? original!.rrule : rruleFor(_repeat);

    final base = original ??
        CalendarEvent(uid: agenda.newUid(), calendarId: _calendarId, title: '', start: start, end: end);
    final event = base.copyWith(
      calendarId: _calendarId,
      title: _title.text.trim(),
      location: _location.text.trim(),
      description: _description.text.trim(),
      start: start,
      end: end,
      allDay: _allDay,
      rrule: () => original?.recurrenceId != null ? null : rrule,
      exdates: rrule == original?.rrule ? original?.exdates : const [],
    );

    setState(() => _saving = true);
    try {
      await agenda.saveEvent(event, original: original);
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Opslaan mislukt: $e')));
    }
  }

  Future<void> _delete() async {
    final event = widget.event!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Afspraak verwijderen?'),
        content: Text(event.isRecurring || event.recurrenceId != null
            ? 'Alle herhalingen van deze afspraak worden verwijderd.'
            : 'Deze afspraak wordt verwijderd.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuleren')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Verwijderen')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await context.read<AgendaController>().deleteEvent(event);
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Verwijderen mislukt: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final agenda = context.watch<AgendaController>();
    final calendar = agenda.calendarById(_calendarId);
    final readOnly = calendar?.readOnly ?? false;
    final selectable = [
      ...agenda.writableCalendars,
      if (readOnly && calendar != null) calendar,
    ];
    final dateFmt = DateFormat.yMMMEd('nl_NL');
    final timeFmt = DateFormat.Hm('nl_NL');

    Widget dateRow(String label, DateTime value, {required bool start}) => Row(
          children: [
            SizedBox(width: 56, child: Text(label)),
            Expanded(
              child: TextButton(
                onPressed: readOnly ? null : () => _pickDate(start: start),
                child: Align(alignment: Alignment.centerLeft, child: Text(dateFmt.format(value))),
              ),
            ),
            if (!_allDay)
              TextButton(
                onPressed: readOnly ? null : () => _pickTime(start: start),
                child: Text(timeFmt.format(value)),
              ),
          ],
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nieuwe afspraak' : 'Afspraak'),
        actions: [
          if (!_isNew && !readOnly)
            IconButton(
              tooltip: 'Verwijderen',
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _delete,
            ),
          if (!readOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('Opslaan'),
              ),
            ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (readOnly)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Deze agenda is alleen-lezen.'),
                ),
              TextFormField(
                key: const Key('titleField'),
                controller: _title,
                readOnly: readOnly,
                autofocus: _isNew,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Titel'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Vul een titel in' : null,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Hele dag'),
                value: _allDay,
                onChanged: readOnly ? null : (v) => setState(() => _allDay = v),
              ),
              dateRow('Begin', _start, start: true),
              dateRow('Einde', _end, start: false),
              const SizedBox(height: 12),
              DropdownButtonFormField<RepeatFrequency>(
                initialValue: _repeat,
                decoration: InputDecoration(
                  labelText: 'Herhalen',
                  helperText: _hasCustomRule ? 'Aangepaste herhaling: ${widget.event!.rrule}' : null,
                ),
                items: [
                  for (final entry in repeatLabels.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: readOnly || widget.event?.recurrenceId != null
                    ? null
                    : (v) => setState(() => _repeat = v ?? RepeatFrequency.none),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _calendarId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Agenda'),
                items: [
                  for (final c in selectable)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 14, color: Color(c.colorValue)),
                          const SizedBox(width: 8),
                          Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                ],
                onChanged: readOnly ? null : (v) => setState(() => _calendarId = v ?? _calendarId),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _location,
                readOnly: readOnly,
                decoration: const InputDecoration(labelText: 'Locatie', prefixIcon: Icon(Icons.place_outlined)),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                readOnly: readOnly,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'Beschrijving', alignLabelWithHint: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
