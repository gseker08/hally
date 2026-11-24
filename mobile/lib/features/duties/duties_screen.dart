import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'duties_repository.dart';

String dutyKindLabel(AppLocalizations l10n, String kind) => kind == 'DropOff' ? l10n.dutiesDropOff : l10n.dutiesPickUp;

/// School run: who drops off and who picks up, this week and next, with a "done" tap that tells the other parent.
class DutiesScreen extends ConsumerStatefulWidget {
  const DutiesScreen({super.key});

  @override
  ConsumerState<DutiesScreen> createState() => _DutiesScreenState();
}

class _DutiesScreenState extends ConsumerState<DutiesScreen> {
  int _offset = 0;
  bool _busy = false;

  Future<void> _run(String familyId, Future<void> Function(DutiesRepository repo) action) async {
    setState(() => _busy = true);
    try {
      await action(ref.read(dutiesRepositoryProvider));
      ref.invalidate(dutyWeekProvider);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _who(BuildContext context, DutySlot s) {
    final l10n = AppLocalizations.of(context);
    if (!s.assigned) return l10n.dutiesNobody;
    return [s.assigneeName ?? '?', if (s.time != null) s.time!.format(context)].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final week = ref.watch(dutyWeekProvider((familyId, _offset)));
    final locale = Localizations.localeOf(context).toLanguageTag();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.dutiesTitle)),
      body: week.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(dutyWeekProvider((familyId, _offset)))),
        data: (w) {
          final today = w.todayDay;
          return ListView(
            padding: const EdgeInsets.all(HallySpace.md),
            children: [
              if (today != null)
                Card(
                  color: HallyColors.softOf(HallyModule.duties, Theme.of(context).brightness),
                  child: Padding(
                    padding: const EdgeInsets.all(HallySpace.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.dutiesToday, style: theme.textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface)),
                        for (final kind in ['DropOff', 'PickUp'])
                          Builder(builder: (context) {
                            final s = today.slot(kind);
                            final done = s.doneAt != null;
                            return Padding(
                              padding: const EdgeInsets.only(top: HallySpace.sm),
                              child: Row(
                                children: [
                                  Icon(kind == 'DropOff' ? Icons.school_rounded : Icons.home_rounded, color: HallyColors.sky),
                                  const SizedBox(width: HallySpace.sm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(dutyKindLabel(l10n, kind), style: theme.textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                        Text(
                                          done ? l10n.dutiesDoneBy(s.doneByName ?? '?', DateFormat.Hm(locale).format(s.doneAt!)) : _who(context, s),
                                          key: Key('duties.today.$kind'),
                                          style: theme.textTheme.titleSmall?.copyWith(color: done ? HallyColors.mintDeep : Theme.of(context).colorScheme.onSurface),
                                        ),
                                      ],
                                    ),
                                  ),
                                  done
                                      ? TextButton(
                                          key: Key('duties.undo.$kind'),
                                          onPressed: _busy ? null : () => _run(familyId, (r) => r.undone(familyId, kind)),
                                          child: Text(l10n.pointsUndo),
                                        )
                                      : FilledButton(
                                          key: Key('duties.done.$kind'),
                                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                                          onPressed: _busy ? null : () => _run(familyId, (r) => r.done(familyId, kind)),
                                          child: Text(kind == 'DropOff' ? l10n.dutiesDroppedOff : l10n.dutiesPickedUp),
                                        ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: HallySpace.md),
              Row(
                children: [
                  IconButton(
                    key: const Key('duties.prev'),
                    onPressed: _offset > -1 ? () => setState(() => _offset--) : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Expanded(
                    child: Text(
                      '${DateFormat.MMMd(locale).format(w.start)} – ${DateFormat.MMMd(locale).format(w.start.add(const Duration(days: 6)))}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const Key('duties.next'),
                    onPressed: _offset < 4 ? () => setState(() => _offset++) : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              Text(l10n.dutiesHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: HallySpace.sm),
              for (final d in w.days)
                Card(
                  color: d.date == w.today ? HallyColors.softOf(HallyModule.duties, Theme.of(context).brightness).withValues(alpha: 0.5) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.sm),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(DateFormat('EEE d', locale).format(d.date), style: theme.textTheme.titleSmall),
                        ),
                        for (final kind in ['DropOff', 'PickUp'])
                          Expanded(
                            child: InkWell(
                              key: Key('duties.slot.${dutyDate(d.date)}.$kind'),
                              borderRadius: BorderRadius.circular(HallyRadius.md),
                              onTap: _busy
                                  ? null
                                  : () async {
                                      final result = await showDutySheet(context, week: w, day: d, kind: kind);
                                      if (result == null) return;
                                      await _run(familyId, (r) async {
                                        switch (result) {
                                          case DutyChoice(reset: true):
                                            await r.resetDay(familyId, d.date, kind);
                                          case DutyChoice(everyWeek: true):
                                            await r.setRule(familyId, (d.date.weekday + 6) % 7, kind, result.assignee);
                                          default:
                                            await r.setDay(familyId, d.date, kind, result.assignee);
                                        }
                                      });
                                    },
                              child: Padding(
                                padding: const EdgeInsets.all(HallySpace.xs),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Text(dutyKindLabel(l10n, kind), style: theme.textTheme.labelSmall),
                                      if (d.slot(kind).isChange) ...[
                                        const SizedBox(width: 4),
                                        const Icon(Icons.swap_horiz_rounded, size: 14, color: HallyColors.apricot),
                                      ],
                                      if (d.slot(kind).doneAt != null) ...[
                                        const SizedBox(width: 4),
                                        const Icon(Icons.check_circle_rounded, size: 14, color: HallyColors.mintDeep),
                                      ],
                                    ]),
                                    Text(
                                      _who(context, d.slot(kind)),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium?.copyWith(color: d.slot(kind).assigned ? null : theme.colorScheme.outline),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// What the parent chose on the sheet.
class DutyChoice {
  const DutyChoice({this.assignee = const DutyAssignee(), this.everyWeek = false, this.reset = false});

  final DutyAssignee assignee;
  final bool everyWeek;

  /// Back to the usual plan.
  final bool reset;
}

Future<DutyChoice?> showDutySheet(BuildContext context, {required DutyWeek week, required DutyDay day, required String kind}) => showModalBottomSheet<DutyChoice>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _DutySheet(week: week, day: day, kind: kind),
    );

class _DutySheet extends StatefulWidget {
  const _DutySheet({required this.week, required this.day, required this.kind});

  final DutyWeek week;
  final DutyDay day;
  final String kind;

  @override
  State<_DutySheet> createState() => _DutySheetState();
}

class _DutySheetState extends State<_DutySheet> {
  late final DutySlot _slot = widget.day.slot(widget.kind);

  /// An adult's id, '' for "someone else", or null for nobody.
  late String? _who = _slot.assigneeUserId ?? (_slot.assigned ? '' : widget.week.adults.firstOrNull?.userId);
  late final _name = TextEditingController(text: _slot.assigneeUserId == null ? _slot.assigneeName : null);
  late TimeOfDay? _time = _slot.time;
  bool _everyWeek = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  DutyAssignee get _assignee => switch (_who) {
        null => const DutyAssignee(),
        '' => DutyAssignee(name: _name.text.trim().isEmpty ? null : _name.text.trim(), time: _time),
        final id => DutyAssignee(userId: id, time: _time),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${DateFormat.MMMMEEEEd(locale).format(widget.day.date)} · ${dutyKindLabel(l10n, widget.kind)}', style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.sm),
          Wrap(
            spacing: HallySpace.sm,
            runSpacing: HallySpace.xs,
            children: [
              for (final a in widget.week.adults)
                ChoiceChip(key: Key('duties.who.${a.userId}'), label: Text(a.name), selected: _who == a.userId, onSelected: (_) => setState(() => _who = a.userId)),
              ChoiceChip(key: const Key('duties.who.other'), label: Text(l10n.dutiesSomeoneElse), selected: _who == '', onSelected: (_) => setState(() => _who = '')),
              ChoiceChip(key: const Key('duties.who.none'), label: Text(l10n.dutiesNobody), selected: _who == null, onSelected: (_) => setState(() => _who = null)),
            ],
          ),
          if (_who == '')
            TextField(
              key: const Key('duties.name'),
              controller: _name,
              onChanged: (_) => setState(() {}),
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: l10n.dutiesNameHint),
            ),
          if (_who != null)
            ListTile(
              key: const Key('duties.time'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded),
              title: Text(l10n.feedingTime),
              trailing: Text(_time?.format(context) ?? '–', style: theme.textTheme.titleMedium),
              onTap: () async {
                final picked = await showTimePicker(context: context, initialTime: _time ?? (widget.kind == 'DropOff' ? const TimeOfDay(hour: 8, minute: 0) : const TimeOfDay(hour: 15, minute: 30)));
                if (picked != null) setState(() => _time = picked);
              },
            ),
          CheckboxListTile(
            key: const Key('duties.everyWeek'),
            contentPadding: EdgeInsets.zero,
            value: _everyWeek,
            onChanged: (v) => setState(() => _everyWeek = v ?? false),
            title: Text(l10n.dutiesEveryWeek(DateFormat.EEEE(locale).format(widget.day.date))),
          ),
          if (_slot.isChange)
            TextButton(
              key: const Key('duties.reset'),
              onPressed: () => Navigator.pop(context, const DutyChoice(reset: true)),
              child: Text(l10n.dutiesReset),
            ),
          FilledButton(
            key: const Key('duties.save'),
            onPressed: _who == '' && _name.text.trim().isEmpty ? null : () => Navigator.pop(context, DutyChoice(assignee: _assignee, everyWeek: _everyWeek)),
            child: Text(l10n.eventSave),
          ),
        ],
      ),
    );
  }
}
