import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';

import '../models/models.dart';
import '../state/agenda_controller.dart';
import 'event_editor_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late DateTime _focusedDay;
  late DateTime _selectedDay;
  CalendarFormat _format = CalendarFormat.month;
  String? _shownError;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedDay = DateTime(now.year, now.month, now.day);
    _selectedDay = _focusedDay;
  }

  Future<void> _openEditor({CalendarEvent? event}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EventEditorScreen(event: event, initialDay: _selectedDay),
    ));
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() {
      _focusedDay = DateTime(now.year, now.month, now.day);
      _selectedDay = _focusedDay;
    });
  }

  void _showErrorIfNew(AgendaController agenda) {
    final error = agenda.lastError;
    if (error == null || error == _shownError) return;
    _shownError = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Synchroniseren mislukt:\n$error')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final agenda = context.watch<AgendaController>();
    final scheme = Theme.of(context).colorScheme;
    _showErrorIfNew(agenda);
    final dayEvents = agenda.occurrencesForDay(_selectedDay);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agenda'),
        actions: [
          IconButton(
            tooltip: 'Vandaag',
            icon: const Icon(Icons.today),
            onPressed: _goToToday,
          ),
          if (agenda.accounts.isNotEmpty)
            agenda.syncing
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Synchroniseren',
                    icon: const Icon(Icons.sync),
                    onPressed: agenda.sync,
                  ),
          IconButton(
            tooltip: 'Instellingen',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nieuwe afspraak',
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: agenda.accounts.isEmpty ? () async {} : agenda.sync,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: TableCalendar<EventOccurrence>(
                locale: 'nl_NL',
                firstDay: DateTime(2000),
                lastDay: DateTime(2100, 12, 31),
                focusedDay: _focusedDay,
                startingDayOfWeek: StartingDayOfWeek.monday,
                calendarFormat: _format,
                availableCalendarFormats: const {
                  CalendarFormat.month: 'Maand',
                  CalendarFormat.twoWeeks: '2 weken',
                  CalendarFormat.week: 'Week',
                },
                selectedDayPredicate: (day) => isSameDay(day, _selectedDay),
                eventLoader: agenda.occurrencesForDay,
                onDaySelected: (selected, focused) => setState(() {
                  _selectedDay = DateTime(selected.year, selected.month, selected.day);
                  _focusedDay = focused;
                }),
                onFormatChanged: (format) => setState(() => _format = format),
                onPageChanged: (focused) => _focusedDay = focused,
                headerStyle: HeaderStyle(
                  titleTextStyle: Theme.of(context).textTheme.titleMedium!,
                  formatButtonTextStyle: TextStyle(color: scheme.onSurface),
                  formatButtonDecoration: BoxDecoration(
                    border: Border.all(color: scheme.outline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leftChevronIcon: Icon(Icons.chevron_left, color: scheme.onSurface),
                  rightChevronIcon: Icon(Icons.chevron_right, color: scheme.onSurface),
                ),
                daysOfWeekStyle: DaysOfWeekStyle(
                  weekdayStyle: TextStyle(color: scheme.onSurfaceVariant),
                  weekendStyle: TextStyle(color: scheme.primary),
                ),
                calendarStyle: CalendarStyle(
                  outsideDaysVisible: false,
                  defaultTextStyle: TextStyle(color: scheme.onSurface),
                  weekendTextStyle: TextStyle(color: scheme.primary),
                  todayDecoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
                  todayTextStyle: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.bold),
                  selectedDecoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                  selectedTextStyle: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.bold),
                ),
                calendarBuilders: CalendarBuilders(
                  markerBuilder: (context, day, events) {
                    if (events.isEmpty) return null;
                    final colors = <int>{
                      for (final o in events) agenda.calendarById(o.event.calendarId)?.colorValue ?? 0xFF888888,
                    }.take(3);
                    return Positioned(
                      bottom: 4,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final c in colors)
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  toBeginningOfSentenceCase(DateFormat.yMMMMEEEEd('nl_NL').format(_selectedDay)),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            if (dayEvents.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Geen afspraken',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: dayEvents.length,
                itemBuilder: (context, i) => _OccurrenceTile(
                  occurrence: dayEvents[i],
                  day: _selectedDay,
                  onTap: () => _openEditor(event: dayEvents[i].event),
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 88)),
          ],
        ),
      ),
    );
  }
}

class _OccurrenceTile extends StatelessWidget {
  const _OccurrenceTile({required this.occurrence, required this.day, required this.onTap});

  final EventOccurrence occurrence;
  final DateTime day;
  final VoidCallback onTap;

  String _timeLabel() {
    if (occurrence.event.allDay) return 'Hele dag';
    final fmt = DateFormat.Hm('nl_NL');
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    final start = occurrence.start.isBefore(dayStart) ? '…' : fmt.format(occurrence.start);
    final end = occurrence.end.isAfter(dayEnd) ? '…' : fmt.format(occurrence.end);
    return '$start – $end';
  }

  @override
  Widget build(BuildContext context) {
    final agenda = context.read<AgendaController>();
    final calendar = agenda.calendarById(occurrence.event.calendarId);
    final color = Color(calendar?.colorValue ?? 0xFF888888);
    final event = occurrence.event;
    final subtitle = [
      _timeLabel(),
      if (event.location.isNotEmpty) event.location,
    ].join(' · ');

    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 6,
        height: 40,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      ),
      title: Text(event.title.isEmpty ? '(geen titel)' : event.title),
      subtitle: Text(subtitle),
      trailing: event.isRecurring || event.recurrenceId != null
          ? const Icon(Icons.repeat, size: 18, semanticLabel: 'Herhalend')
          : null,
    );
  }
}
