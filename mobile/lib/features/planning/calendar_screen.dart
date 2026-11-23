import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import '../notifications/reminder_sheet.dart';
import '../sharing/helper_share_sheet.dart';
import '../sharing/sharing_repository.dart';
import 'planning_repository.dart';

/// Week strip or month grid, plus the selected day's events. Events come from approved proposals or manual entry.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

enum _CalendarView { week, month }

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _selected = DateUtils.dateOnly(DateTime.now());
  _CalendarView _view = _CalendarView.week;

  CalendarRange _range(String familyId) =>
      _view == _CalendarView.week ? CalendarRange.week(familyId, _selected) : CalendarRange.month(familyId, _selected);

  void _step(int direction) => setState(() {
        _selected = _view == _CalendarView.week
            ? DateTime(_selected.year, _selected.month, _selected.day + 7 * direction)
            // Keep the day where the month has it, otherwise the month's last day (31 Jan → 28 Feb).
            : DateTime(_selected.year, _selected.month + direction, math.min(_selected.day, DateUtils.getDaysInMonth(_selected.year, _selected.month + direction)));
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());

    final range = _range(familyId);
    final child = ref.watch(childFilterProvider);
    final events = ref.watch(calendarEventsProvider(range)).whenData((all) => filterByChild(all, (e) => e.childIds, child));
    bool hasEvents(DateTime d) => events.valueOrNull?.any((e) => DateUtils.isSameDay(e.startsAt, d)) ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(DateFormat.yMMMM(locale).format(_selected)),
        actions: [
          IconButton(key: const Key('calendar.previous'), icon: const Icon(Icons.chevron_left), onPressed: () => _step(-1)),
          TextButton(onPressed: () => setState(() => _selected = DateUtils.dateOnly(DateTime.now())), child: Text(l10n.calendarToday)),
          IconButton(key: const Key('calendar.next'), icon: const Icon(Icons.chevron_right), onPressed: () => _step(1)),
          IconButton(
            key: const Key('calendar.shareDay'),
            tooltip: l10n.calendarShareDay,
            icon: const Icon(Icons.volunteer_activism_outlined),
            onPressed: () {
              final day = _selected;
              showHelperShareSheet(context, ref,
                  subject: DateFormat.MMMMEEEEd(locale).format(day), create: () => ref.read(sharingRepositoryProvider).shareDay(familyId, day));
            },
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 88),
        child: FloatingActionButton.extended(
          key: const Key('calendar.add'),
          onPressed: () => _addEvent(familyId),
          icon: const Icon(Icons.add),
          label: Text(l10n.calendarAdd),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, HallySpace.sm),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_CalendarView>(
                key: const Key('calendar.view'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: _CalendarView.week, label: Text(l10n.calendarWeek, key: const Key('calendar.view.week'))),
                  ButtonSegment(value: _CalendarView.month, label: Text(l10n.calendarMonth, key: const Key('calendar.view.month'))),
                ],
                selected: {_view},
                onSelectionChanged: (v) => setState(() => _view = v.first),
              ),
            ),
          ),
          ChildFilterBar(familyId: familyId),
          if (_view == _CalendarView.week)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm),
              child: Row(
                children: [
                  for (final d in range.dates)
                    Expanded(
                      child: _DayChip(
                        day: d,
                        selected: DateUtils.isSameDay(d, _selected),
                        hasEvents: hasEvents(d),
                        locale: locale,
                        onTap: () => setState(() => _selected = d),
                      ),
                    ),
                ],
              ),
            )
          else
            _MonthGrid(
              range: range,
              month: _selected.month,
              selected: _selected,
              hasEvents: hasEvents,
              locale: locale,
              onTap: (d) => setState(() => _selected = d),
            ),
          const SizedBox(height: HallySpace.sm),
          Expanded(
            child: events.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(calendarEventsProvider(range))),
              data: (events) {
                final today = events.where((e) => DateUtils.isSameDay(e.startsAt, _selected)).toList();
                if (today.isEmpty) {
                  return HallyEmptyState(icon: Icons.event_available_outlined, title: l10n.calendarEmpty, body: l10n.calendarEmptyBody);
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, 120),
                  children: [
                    for (final e in today)
                      Card(
                        child: ListTile(
                          leading: const HallyIconBadge(icon: Icons.event_rounded, color: HallyColors.apricot),
                          title: Row(
                            children: [
                              Expanded(child: Text(e.title, style: theme.textTheme.titleSmall)),
                              ChildBadges(familyId: familyId, childIds: e.childIds, size: 20),
                            ],
                          ),
                          subtitle: Text([
                            e.allDay ? l10n.reviewAllDay : TimeOfDay.fromDateTime(e.startsAt).format(context),
                            if (e.repeat != EventRepeat.none) repeatLabel(l10n, e.repeat),
                          ].join(' · ')),
                          trailing: IconButton(
                            key: Key('event.${e.id}.remind'),
                            icon: const Icon(Icons.notification_add_outlined),
                            tooltip: l10n.reminderTitle,
                            onPressed: () => showReminderSheet(context, ref,
                                familyId: familyId, target: 'Event', targetId: e.id, title: e.title, at: e.startsAt, allDay: e.allDay),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addEvent(String familyId) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final children = ref.read(familyProvider(familyId)).valueOrNull?.children ?? const <ChildProfile>[];
    final filtered = ref.read(childFilterProvider);
    final result = await showDialog<(String, DateTime, TimeOfDay?, EventRepeat, List<String>)>(
      context: context,
      builder: (_) => _EventDialog(initialDate: _selected, children: children, initialChildIds: {if (filtered != null) filtered}),
    );
    if (result == null) return;
    final (title, date, time, repeat, childIds) = result;
    final startsAt = DateTime(date.year, date.month, date.day, time?.hour ?? 0, time?.minute ?? 0);
    try {
      final saved = await ref.read(planningRepositoryProvider).createEvent(familyId, title: title, startsAt: startsAt, allDay: time == null, repeat: repeat, childIds: childIds);
      // A series can show up in any window, so refresh every cached range.
      ref.invalidate(calendarEventsProvider);
      if (saved.conflicts.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.eventConflict(saved.conflicts.first.title))));
      }
      if (mounted) setState(() => _selected = DateUtils.dateOnly(startsAt));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }
}

String repeatLabel(AppLocalizations l10n, EventRepeat repeat) => switch (repeat) {
      EventRepeat.none => l10n.repeatNone,
      EventRepeat.daily => l10n.repeatDaily,
      EventRepeat.weekly => l10n.repeatWeekly,
      EventRepeat.monthly => l10n.repeatMonthly,
    };

/// Six Monday-first weeks; days outside the month are dimmed but still tappable.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.range,
    required this.month,
    required this.selected,
    required this.hasEvents,
    required this.locale,
    required this.onTap,
  });

  final CalendarRange range;
  final int month;
  final DateTime selected;
  final bool Function(DateTime) hasEvents;
  final String locale;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dates = range.dates;
    final today = DateUtils.dateOnly(DateTime.now());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm),
      child: Column(
        children: [
          Row(
            children: [
              for (final d in dates.take(7))
                Expanded(
                  child: Center(
                    child: Text(DateFormat.E(locale).format(d), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: HallySpace.xs),
          for (var w = 0; w < 6; w++)
            Row(
              children: [
                for (final d in dates.skip(w * 7).take(7))
                  Expanded(
                    child: _MonthCell(
                      day: d,
                      inMonth: d.month == month,
                      isToday: d == today,
                      selected: DateUtils.isSameDay(d, selected),
                      hasEvents: hasEvents(d),
                      onTap: () => onTap(d),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.selected,
    required this.hasEvents,
    required this.onTap,
  });

  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool selected;
  final bool hasEvents;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected
        ? Colors.white
        : inMonth
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    return InkWell(
      key: Key('calendar.day.${day.year}-${day.month}-${day.day}'),
      borderRadius: BorderRadius.circular(HallyRadius.sm),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        height: 44,
        decoration: BoxDecoration(
          gradient: selected ? HallyGradients.cherry : null,
          borderRadius: BorderRadius.circular(HallyRadius.sm),
          border: isToday && !selected ? Border.all(color: theme.colorScheme.primary) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('${day.day}', style: theme.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: isToday ? FontWeight.w700 : null)),
            const SizedBox(height: 2),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(shape: BoxShape.circle, color: hasEvents ? (selected ? Colors.white : HallyColors.apricot) : Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.day, required this.selected, required this.hasEvents, required this.locale, required this.onTap});

  final DateTime day;
  final bool selected;
  final bool hasEvents;
  final String locale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? Colors.white : theme.colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(HallyRadius.md),
      onTap: onTap,
      child: AnimatedContainer(
        duration: HallyMotion.fast,
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(vertical: HallySpace.sm),
        decoration: BoxDecoration(
          gradient: selected ? HallyGradients.cherry : null,
          borderRadius: BorderRadius.circular(HallyRadius.md),
        ),
        child: Column(
          children: [
            Text(DateFormat.E(locale).format(day), style: theme.textTheme.labelSmall?.copyWith(color: fg)),
            const SizedBox(height: 2),
            Text('${day.day}', style: theme.textTheme.titleMedium?.copyWith(color: fg)),
            const SizedBox(height: 2),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(shape: BoxShape.circle, color: hasEvents ? (selected ? Colors.white : HallyColors.apricot) : Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventDialog extends StatefulWidget {
  const _EventDialog({required this.initialDate, required this.children, required this.initialChildIds});

  final DateTime initialDate;
  final List<ChildProfile> children;
  final Set<String> initialChildIds;

  @override
  State<_EventDialog> createState() => _EventDialogState();
}

class _EventDialogState extends State<_EventDialog> {
  final _title = TextEditingController();
  late DateTime _date = widget.initialDate;
  TimeOfDay? _time;
  EventRepeat _repeat = EventRepeat.none;
  late Set<String> _childIds = widget.initialChildIds;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return AlertDialog(
      // Scrolls instead of overflowing on short screens, with the keyboard open or large text.
      scrollable: true,
      title: Text(l10n.calendarAdd),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(key: const Key('event.title'), controller: _title, autofocus: true, maxLength: 200, decoration: InputDecoration(labelText: l10n.eventTitle)),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(DateFormat.yMMMEd(locale).format(_date)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime.now().subtract(const Duration(days: 365)),
                lastDate: DateTime.now().add(const Duration(days: 730)),
              );
              if (picked != null) setState(() => _date = picked);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text(_time?.format(context) ?? l10n.reviewAllDay),
            onTap: () async {
              final picked = await showTimePicker(context: context, initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0));
              if (picked != null) setState(() => _time = picked);
            },
          ),
          DropdownButtonFormField<EventRepeat>(
            key: const Key('event.repeat'),
            isExpanded: true,
            initialValue: _repeat,
            decoration: InputDecoration(labelText: l10n.eventRepeat, prefixIcon: const Icon(Icons.repeat)),
            items: [for (final r in EventRepeat.values) DropdownMenuItem(value: r, child: Text(repeatLabel(l10n, r)))],
            onChanged: (r) => setState(() => _repeat = r ?? EventRepeat.none),
          ),
          ChildPicker(children: widget.children, selected: _childIds, onChanged: (ids) => setState(() => _childIds = ids)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(context, (title, _date, _time, _repeat, _childIds.toList()));
          },
          child: Text(l10n.eventSave),
        ),
      ],
    );
  }
}
