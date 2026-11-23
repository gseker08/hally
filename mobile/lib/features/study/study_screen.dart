import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import '../screen_time/screen_time_repository.dart' show formatScreenDuration;
import 'study_repository.dart';

bool _tr(BuildContext context) => Localizations.localeOf(context).languageCode != 'en';

String studyKindLabel(AppLocalizations l10n, String kind) => kind == 'Reading' ? l10n.studyReading : l10n.studyHomework;
IconData studyKindIcon(String kind) => kind == 'Reading' ? Icons.menu_book_rounded : Icons.edit_note_rounded;

const _goalChoices = [15, 20, 30, 45, 60, 90];

/// Homework and reading for every child: today's minutes against the daily minimum, the streak, and one tap to start or stop.
class StudyScreen extends ConsumerStatefulWidget {
  const StudyScreen({super.key});

  @override
  ConsumerState<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends ConsumerState<StudyScreen> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });
  final _busy = <String>{};

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _run(String familyId, String childId, Future<void> Function(StudyRepository repo) action) async {
    setState(() => _busy.add(childId));
    try {
      await action(ref.read(studyRepositoryProvider));
      ref.invalidate(studyStatusProvider(familyId));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy.remove(childId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final status = ref.watch(studyStatusProvider(familyId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.studyTitle)),
      body: children.isEmpty
          ? HallyEmptyState(icon: Icons.menu_book_rounded, title: l10n.studyTitle, body: l10n.studyNoChildren)
          : status.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(studyStatusProvider(familyId))),
              data: (byChild) => RefreshIndicator(
                onRefresh: () => ref.refresh(studyStatusProvider(familyId).future),
                child: ListView(
                  padding: const EdgeInsets.all(HallySpace.md),
                  children: [
                    for (final c in children)
                      _StudyCard(
                        child: c,
                        status: byChild[c.id],
                        busy: _busy.contains(c.id),
                        onOpen: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StudyHistoryScreen(familyId: familyId, child: c))),
                        onStart: (kind) => _run(familyId, c.id, (r) => r.start(familyId, c.id, kind)),
                        onStop: () => _run(familyId, c.id, (r) => r.stop(familyId, c.id)),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _StudyCard extends StatelessWidget {
  const _StudyCard({required this.child, required this.status, required this.busy, required this.onOpen, required this.onStart, required this.onStop});

  final ChildProfile child;
  final ChildStudyStatus? status;
  final bool busy;
  final VoidCallback onOpen;
  final void Function(String kind) onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tr = _tr(context);
    final s = status;
    final now = DateTime.now();
    final seconds = s?.secondsAt(now) ?? 0;
    final goal = s?.dailyGoalMinutes;
    final met = s?.goalMetAt(now) ?? false;
    final time = formatScreenDuration(seconds, turkish: tr);
    final line = goal == null ? l10n.studyToday(time) : l10n.studyOfGoal(time, formatScreenDuration(goal * 60, turkish: tr));

    return Card(
      child: InkWell(
        key: Key('study.child.${child.id}'),
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ChildBadge(child: child, size: 40),
                  const SizedBox(width: HallySpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(child.firstName, style: theme.textTheme.titleMedium),
                          if (met) ...[
                            const SizedBox(width: HallySpace.xs),
                            const Icon(Icons.check_circle_rounded, size: 18, color: HallyColors.mintDeep),
                          ],
                        ]),
                        Text(line, key: Key('study.line.${child.id}'), style: theme.textTheme.bodySmall),
                        if ((s?.streak ?? 0) > 1)
                          Text(l10n.studyStreak(s!.streak), key: Key('study.streak.${child.id}'),
                              style: theme.textTheme.labelSmall?.copyWith(color: HallyColors.apricot, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
              if (goal != null) ...[
                const SizedBox(height: HallySpace.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (seconds / (goal * 60)).clamp(0.0, 1.0),
                    minHeight: 8,
                    color: met ? HallyColors.mintDeep : childColor(child.color),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
              const SizedBox(height: HallySpace.sm),
              if (s?.isRunning ?? false)
                Row(
                  children: [
                    Icon(studyKindIcon(s!.runningKind!), color: childColor(child.color)),
                    const SizedBox(width: HallySpace.xs),
                    Expanded(
                      child: Text(
                        '${studyKindLabel(l10n, s.runningKind!)} · ${formatScreenDuration(s.runningSecondsAt(now), turkish: tr, withSeconds: true)}',
                        key: Key('study.running.${child.id}'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    FilledButton.icon(
                      key: Key('study.stop.${child.id}'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44), backgroundColor: HallyColors.apricot),
                      onPressed: busy ? null : onStop,
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(l10n.studyStop),
                    ),
                  ],
                )
              else
                Wrap(
                  spacing: HallySpace.sm,
                  children: [
                    for (final kind in ['Homework', 'Reading'])
                      OutlinedButton.icon(
                        key: Key('study.start.$kind.${child.id}'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: busy || s == null ? null : () => onStart(kind),
                        icon: Icon(studyKindIcon(kind), size: 18),
                        label: Text(studyKindLabel(l10n, kind)),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One child's last seven days against the goal, the entries, and the goal setting.
class StudyHistoryScreen extends ConsumerWidget {
  const StudyHistoryScreen({super.key, required this.familyId, required this.child});

  final String familyId;
  final ChildProfile child;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(studyHistoryProvider((familyId, child.id)));
    ref.invalidate(studyStatusProvider(familyId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tr = _tr(context);
    final key = (familyId, child.id);
    final history = ref.watch(studyHistoryProvider(key));
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Scaffold(
      appBar: AppBar(title: Text('${child.firstName} · ${l10n.studyTitle}')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('study.add'),
        onPressed: () async {
          if (await showAddStudySheet(context, familyId: familyId, childId: child.id) == true) await _refresh(ref);
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.studyAdd),
      ),
      body: history.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(studyHistoryProvider(key))),
        data: (h) {
          final goalSeconds = h.dailyGoalMinutes == null ? null : h.dailyGoalMinutes! * 60;
          final maxSeconds = [for (final d in h.days) d.homeworkSeconds + d.readingSeconds, goalSeconds ?? 0, 1800].reduce((a, b) => a > b ? a : b);
          const barHeight = 100.0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('study.goal'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () async {
                    if (await _pickGoal(context, ref, h.dailyGoalMinutes)) await _refresh(ref);
                  },
                  icon: const Icon(Icons.flag_rounded),
                  label: Text(h.dailyGoalMinutes == null ? l10n.studySetGoal : l10n.studyGoalLabel(formatScreenDuration(goalSeconds!, turkish: tr))),
                ),
              ),
              const SizedBox(height: HallySpace.md),
              SizedBox(
                height: barHeight,
                child: Stack(
                  children: [
                    if (goalSeconds != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: barHeight * goalSeconds / maxSeconds,
                        child: Container(height: 1.5, color: HallyColors.mintDeep.withValues(alpha: 0.6)),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final d in h.days)
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (d.readingSeconds > 0)
                                  Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 6),
                                    height: barHeight * d.readingSeconds / maxSeconds,
                                    decoration: BoxDecoration(color: HallyColors.sky, borderRadius: BorderRadius.circular(3)),
                                  ),
                                Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 6),
                                  height: d.homeworkSeconds == 0 ? 2 : barHeight * d.homeworkSeconds / maxSeconds,
                                  decoration: BoxDecoration(color: childColor(child.color), borderRadius: BorderRadius.circular(3)),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(children: [
                for (final d in h.days)
                  Expanded(
                    child: Column(children: [
                      Text(DateFormat.E(locale).format(d.date), textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
                      Icon(d.goalMet ? Icons.check_circle_rounded : Icons.circle_outlined, size: 14,
                          color: d.goalMet ? HallyColors.mintDeep : theme.colorScheme.outlineVariant),
                    ]),
                  ),
              ]),
              const SizedBox(height: HallySpace.xs),
              Wrap(spacing: HallySpace.md, children: [
                _Legend(color: childColor(child.color), label: l10n.studyHomework),
                _Legend(color: HallyColors.sky, label: l10n.studyReading),
              ]),
              const Divider(height: HallySpace.xl),
              if (h.entries.isEmpty) Text(l10n.studyNoRecord),
              for (final e in h.entries)
                ListTile(
                  key: Key('study.entry.${e.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(studyKindIcon(e.kind), color: e.kind == 'Reading' ? HallyColors.sky : childColor(child.color)),
                  title: Text('${studyKindLabel(l10n, e.kind)} · ${formatScreenDuration(e.seconds, turkish: tr)}'),
                  subtitle: Text([
                    '${DateFormat.MMMd(locale).format(e.startedAt)} ${DateFormat.Hm(locale).format(e.startedAt)}',
                    if (e.byName != null) e.byName!,
                    if (e.note != null) e.note!,
                  ].join(' · ')),
                  trailing: IconButton(
                    key: Key('study.delete.${e.id}'),
                    tooltip: l10n.sleepDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      await ref.read(studyRepositoryProvider).delete(familyId, child.id, e.id);
                      await _refresh(ref);
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Returns whether the goal changed.
  Future<bool> _pickGoal(BuildContext context, WidgetRef ref, int? current) async {
    final l10n = AppLocalizations.of(context);
    final tr = _tr(context);
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${child.firstName} · ${l10n.studyGoalTitle}', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: HallySpace.xs),
              Text(l10n.studyGoalHint, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: HallySpace.md),
              Wrap(
                spacing: HallySpace.sm,
                runSpacing: HallySpace.sm,
                children: [
                  ChoiceChip(key: const Key('study.goal.none'), label: Text(l10n.screenTimeNoGoal), selected: current == null, onSelected: (_) => Navigator.pop(context, 0)),
                  for (final m in _goalChoices)
                    ChoiceChip(
                      key: Key('study.goal.$m'),
                      label: Text(formatScreenDuration(m * 60, turkish: tr)),
                      selected: current == m,
                      onSelected: (_) => Navigator.pop(context, m),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return false;
    try {
      await ref.read(studyRepositoryProvider).setGoal(familyId, child.id, picked == 0 ? null : picked);
      return true;
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      return false;
    }
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

/// Add finished minutes (ending now) for when nobody started the timer.
Future<bool?> showAddStudySheet(BuildContext context, {required String familyId, required String childId}) => showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AddStudySheet(familyId: familyId, childId: childId),
    );

class _AddStudySheet extends ConsumerStatefulWidget {
  const _AddStudySheet({required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<_AddStudySheet> createState() => _AddStudySheetState();
}

class _AddStudySheetState extends ConsumerState<_AddStudySheet> {
  String _kind = 'Homework';
  int _minutes = 20;
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(studyRepositoryProvider).add(widget.familyId, widget.childId, kind: _kind, minutes: _minutes, note: _note.text.trim().isEmpty ? null : _note.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tr = _tr(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.studyAdd, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.sm),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              for (final kind in ['Homework', 'Reading'])
                ButtonSegment(value: kind, label: Text(studyKindLabel(l10n, kind)), icon: Icon(studyKindIcon(kind))),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: HallySpace.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                key: const Key('study.minutes.minus'),
                onPressed: _minutes > 5 ? () => setState(() => _minutes -= 5) : null,
                icon: const Icon(Icons.remove_rounded),
              ),
              SizedBox(
                width: 120,
                child: Text(formatScreenDuration(_minutes * 60, turkish: tr), key: const Key('study.minutes.value'), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              ),
              IconButton.filledTonal(
                key: const Key('study.minutes.plus'),
                onPressed: _minutes < 240 ? () => setState(() => _minutes += 5) : null,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          TextField(
            key: const Key('study.note'),
            controller: _note,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l10n.studyNote),
          ),
          FilledButton(key: const Key('study.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
        ],
      ),
    );
  }
}
