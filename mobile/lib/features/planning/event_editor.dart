import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'calendar_screen.dart' show repeatLabel;
import 'planning_repository.dart';

/// Adds an event, or edits / deletes [event] when given. For a repeating event the edit and the delete apply to the
/// whole series. Refreshes the calendar and Today. Returns the day to show afterwards, or null if nothing changed.
Future<DateTime?> showEventEditor(
  BuildContext context,
  WidgetRef ref, {
  required String familyId,
  EventItem? event,
  DateTime? initialDate,
  Set<String> initialChildIds = const {},
}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final children = ref.read(familyProvider(familyId)).valueOrNull?.children ?? const <ChildProfile>[];
  final result = await showDialog<_EventResult>(
    context: context,
    builder: (_) => _EventDialog(
      event: event,
      initialDate: initialDate ?? DateUtils.dateOnly(DateTime.now()),
      children: children,
      initialChildIds: event == null ? initialChildIds : event.childIds.toSet(),
    ),
  );
  if (result == null) return null;

  final repo = ref.read(planningRepositoryProvider);
  void refresh() {
    // A series can show up in any window, so refresh every cached range.
    ref.invalidate(calendarEventsProvider);
    ref.invalidate(todayProvider(familyId));
  }

  try {
    switch (result) {
      case _Delete():
        await repo.deleteEvent(familyId, event!.id);
        refresh();
        messenger.showSnackBar(SnackBar(content: Text(l10n.eventDeleted)));
        return DateUtils.dateOnly(event.startsAt);
      case _Save(:final title, :final date, :final time, :final repeat, :final childIds):
        final startsAt = DateTime(date.year, date.month, date.day, time?.hour ?? 0, time?.minute ?? 0);
        final saved = event == null
            ? await repo.createEvent(familyId, title: title, startsAt: startsAt, allDay: time == null, repeat: repeat, childIds: childIds)
            : await repo.updateEvent(familyId, event, title: title, startsAt: startsAt, allDay: time == null, repeat: repeat, childIds: childIds);
        refresh();
        if (saved.conflicts.isNotEmpty) {
          messenger.showSnackBar(SnackBar(content: Text(l10n.eventConflict(saved.conflicts.first.title))));
        }
        // An edited occurrence of a series stays on its own day; a moved one-off event follows its new date.
        return event != null && event.repeat != EventRepeat.none && repeat != EventRepeat.none
            ? DateUtils.dateOnly(event.startsAt)
            : DateUtils.dateOnly(startsAt);
    }
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    return null;
  }
}

sealed class _EventResult {
  const _EventResult();
}

class _Save extends _EventResult {
  const _Save(this.title, this.date, this.time, this.repeat, this.childIds);

  final String title;
  final DateTime date;
  final TimeOfDay? time;
  final EventRepeat repeat;
  final List<String> childIds;
}

class _Delete extends _EventResult {
  const _Delete();
}

class _EventDialog extends StatefulWidget {
  const _EventDialog({required this.event, required this.initialDate, required this.children, required this.initialChildIds});

  final EventItem? event;
  final DateTime initialDate;
  final List<ChildProfile> children;
  final Set<String> initialChildIds;

  @override
  State<_EventDialog> createState() => _EventDialogState();
}

class _EventDialogState extends State<_EventDialog> {
  late final EventItem? _event = widget.event;
  late final _title = TextEditingController(text: _event?.title);

  // A series is edited from its first occurrence, so moving the date moves the whole series.
  late DateTime _date = _event == null ? widget.initialDate : DateUtils.dateOnly(_event.seriesStartsAt);
  late TimeOfDay? _time = _event == null || _event.allDay ? null : TimeOfDay.fromDateTime(_event.seriesStartsAt);
  late EventRepeat _repeat = _event?.repeat ?? EventRepeat.none;
  late Set<String> _childIds = widget.initialChildIds;

  bool get _isSeries => _event != null && _event.repeat != EventRepeat.none;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l10n.eventDeleteTitle),
        content: Text(_isSeries ? l10n.eventDeleteSeriesBody : l10n.eventDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(MaterialLocalizations.of(c).cancelButtonLabel)),
          FilledButton(
            key: const Key('event.deleteConfirm'),
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40), backgroundColor: HallyColors.error, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.eventDelete),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.pop(context, const _Delete());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return AlertDialog(
      // Scrolls instead of overflowing on short screens, with the keyboard open or large text.
      scrollable: true,
      title: Text(_event == null ? l10n.calendarAdd : l10n.eventEdit),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('event.title'),
            controller: _title,
            autofocus: _event == null,
            maxLength: 200,
            decoration: InputDecoration(labelText: l10n.eventTitle),
          ),
          if (_isSeries)
            Padding(
              padding: const EdgeInsets.only(bottom: HallySpace.xs),
              child: Row(
                children: [
                  Icon(Icons.repeat, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: HallySpace.xs),
                  Expanded(child: Text(l10n.eventSeriesNote, style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(DateFormat.yMMMEd(locale).format(_date)),
            onTap: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: _date.isBefore(now.subtract(const Duration(days: 365))) ? _date : now.subtract(const Duration(days: 365)),
                lastDate: now.add(const Duration(days: 730)),
              );
              if (picked != null) setState(() => _date = picked);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text(_time?.format(context) ?? l10n.reviewAllDay),
            trailing: _time == null
                ? null
                : IconButton(
                    key: const Key('event.allDay'),
                    tooltip: l10n.reviewAllDay,
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _time = null),
                  ),
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
        if (_event != null)
          TextButton(
            key: const Key('event.delete'),
            style: TextButton.styleFrom(foregroundColor: HallyColors.error),
            onPressed: _confirmDelete,
            child: Text(l10n.eventDelete),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(context, _Save(title, _date, _time, _repeat, _childIds.toList()));
          },
          child: Text(l10n.eventSave),
        ),
      ],
    );
  }
}
