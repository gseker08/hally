import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'habits_repository.dart';

/// Small daily habits per child with streaks. Tap the circle when it is done; tap a day dot to fix the last week.
class HabitsScreen extends ConsumerStatefulWidget {
  const HabitsScreen({super.key});

  @override
  ConsumerState<HabitsScreen> createState() => _HabitsScreenState();
}

class _HabitsScreenState extends ConsumerState<HabitsScreen> {
  final _busy = <String>{};

  Future<void> _toggle(String familyId, Habit habit, DateTime day, bool done) async {
    setState(() => _busy.add(habit.id));
    try {
      final repo = ref.read(habitsRepositoryProvider);
      done ? await repo.uncheck(familyId, habit.id, day) : await repo.check(familyId, habit.id, day);
      ref.invalidate(habitsProvider(familyId));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy.remove(habit.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final board = ref.watch(habitsProvider(familyId));
    final locale = Localizations.localeOf(context).toLanguageTag();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.habitsTitle)),
      floatingActionButton: children.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('habits.add'),
              onPressed: () async {
                if (await showAddHabitSheet(context, familyId: familyId, children: children) == true) ref.invalidate(habitsProvider(familyId));
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.habitsAdd),
            ),
      body: children.isEmpty
          ? HallyEmptyState(icon: Icons.local_fire_department_rounded, title: l10n.habitsTitle, body: l10n.habitsNoChildren)
          : board.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(habitsProvider(familyId))),
              data: (b) => b.habits.isEmpty
                  ? HallyEmptyState(icon: Icons.local_fire_department_rounded, title: l10n.habitsTitle, body: l10n.habitsEmpty)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
                      children: [
                        for (final c in children)
                          if (b.habits.any((h) => h.childId == c.id)) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: HallySpace.sm),
                              child: Row(children: [
                                ChildBadge(child: c, size: 28),
                                const SizedBox(width: HallySpace.sm),
                                Text(c.firstName, style: theme.textTheme.titleMedium),
                              ]),
                            ),
                            for (final h in b.habits.where((h) => h.childId == c.id))
                              Dismissible(
                                key: Key('habits.item.${h.id}'),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.symmetric(horizontal: HallySpace.lg),
                                  child: const Icon(Icons.delete_outline_rounded, color: HallyColors.inkMuted),
                                ),
                                onDismissed: (_) async {
                                  await ref.read(habitsRepositoryProvider).delete(familyId, h.id);
                                  ref.invalidate(habitsProvider(familyId));
                                },
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(HallySpace.md),
                                    child: Row(
                                      children: [
                                        IconButton(
                                          key: Key('habits.today.${h.id}'),
                                          iconSize: 40,
                                          tooltip: l10n.habitsDoneToday,
                                          onPressed: _busy.contains(h.id) ? null : () => _toggle(familyId, h, b.today, h.doneToday),
                                          icon: Icon(
                                            h.doneToday ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                            color: h.doneToday ? HallyColors.mintDeep : (h.dueToday ? childColor(c.color) : theme.colorScheme.outlineVariant),
                                          ),
                                        ),
                                        const SizedBox(width: HallySpace.sm),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(h.title, style: theme.textTheme.titleSmall),
                                              Text(
                                                h.streak > 0 ? l10n.habitsStreak(h.streak, h.best) : (h.dueToday ? l10n.habitsStart : l10n.habitsNotToday),
                                                key: Key('habits.streak.${h.id}'),
                                                style: theme.textTheme.bodySmall?.copyWith(color: h.streak > 0 ? HallyColors.apricot : null),
                                              ),
                                              const SizedBox(height: HallySpace.xs),
                                              Row(
                                                children: [
                                                  for (var i = 0; i < h.lastSeven.length; i++)
                                                    _DayDot(
                                                      key: Key('habits.day.${h.id}.$i'),
                                                      label: DateFormat.E(locale).format(b.today.subtract(Duration(days: h.lastSeven.length - 1 - i))).characters.first,
                                                      state: h.lastSeven[i],
                                                      color: childColor(c.color),
                                                      onTap: h.lastSeven[i] == null || _busy.contains(h.id)
                                                          ? null
                                                          : () => _toggle(familyId, h, b.today.subtract(Duration(days: h.lastSeven.length - 1 - i)), h.lastSeven[i]!),
                                                    ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                      ],
                    ),
            ),
    );
  }
}

class _DayDot extends StatelessWidget {
  const _DayDot({super.key, required this.label, required this.state, required this.color, this.onTap});

  final String label;

  /// true done, false not done, null not scheduled.
  final bool? state;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: state == true ? color : null,
            border: state == false ? Border.all(color: color.withValues(alpha: 0.5), width: 1.5) : null,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: state == true ? Colors.white : (state == null ? theme.colorScheme.outlineVariant : null),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Add a habit for one child on chosen weekdays.
Future<bool?> showAddHabitSheet(BuildContext context, {required String familyId, required List<ChildProfile> children}) => showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AddHabitSheet(familyId: familyId, children: children),
    );

class _AddHabitSheet extends ConsumerStatefulWidget {
  const _AddHabitSheet({required this.familyId, required this.children});

  final String familyId;
  final List<ChildProfile> children;

  @override
  ConsumerState<_AddHabitSheet> createState() => _AddHabitSheetState();
}

class _AddHabitSheetState extends ConsumerState<_AddHabitSheet> {
  late String _childId = widget.children.first.id;
  int _days = everyDay;
  final _title = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final title = _title.text.trim();
    if (title.isEmpty || _days == 0) {
      setState(() => _error = title.isEmpty ? l10n.pointsTitleRequired : l10n.habitsPickDay);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(habitsRepositoryProvider).add(widget.familyId, childId: _childId, title: title, days: _days);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l10n.errorGeneric;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final monday = DateTime(2026, 11, 23);
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.habitsAdd, style: theme.textTheme.titleLarge),
          if (widget.children.length > 1) ...[
            const SizedBox(height: HallySpace.sm),
            Wrap(spacing: HallySpace.sm, children: [
              for (final c in widget.children)
                ChoiceChip(
                  key: Key('habits.child.${c.id}'),
                  label: Text(c.firstName),
                  selected: _childId == c.id,
                  onSelected: (_) => setState(() => _childId = c.id),
                ),
            ]),
          ],
          const SizedBox(height: HallySpace.sm),
          TextField(
            key: const Key('habits.title'),
            controller: _title,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l10n.habitsTitleHint),
          ),
          Wrap(
            spacing: 4,
            children: [
              for (var i = 0; i < 7; i++)
                FilterChip(
                  key: Key('habits.weekday.$i'),
                  showCheckmark: false,
                  label: Text(DateFormat.E(locale).format(monday.add(Duration(days: i)))),
                  selected: _days & (1 << i) != 0,
                  onSelected: (_) => setState(() => _days ^= 1 << i),
                ),
            ],
          ),
          if (_error != null) Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error)),
          const SizedBox(height: HallySpace.md),
          FilledButton(key: const Key('habits.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
        ],
      ),
    );
  }
}
