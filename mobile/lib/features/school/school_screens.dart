import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../child_mode/child_mode_repository.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'school.dart';

String _locale(BuildContext context) => Localizations.localeOf(context).toLanguageTag();

/// "Pzt" … "Cum" (1 = Monday), from a known Monday.
String weekdayShort(BuildContext context, int weekday) => DateFormat('E', _locale(context)).format(DateTime(2024, 1, weekday));

String weekdayLong(BuildContext context, int weekday) => DateFormat('EEEE', _locale(context)).format(DateTime(2024, 1, weekday));

Color subjectColor(String subject) => switch (subjectColorKey(subject)) {
      'mist' => HallyColors.mist,
      'lavender' => HallyColors.lavender,
      'sage' => HallyColors.sage,
      'peach' => HallyColors.peach,
      'butter' => HallyColors.butter,
      _ => HallyColors.powder,
    };

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
  }
}

/// Ders programı: one child's week (Monday–Friday × the family's bell times), today's column marked, and tomorrow's bag.
class TimetableScreen extends ConsumerStatefulWidget {
  const TimetableScreen({super.key, this.childId});

  final String? childId;

  @override
  ConsumerState<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends ConsumerState<TimetableScreen> {
  late String? _childId = widget.childId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final caregiver = ref.watch(isCaregiverProvider);
    final children = watchChildren(ref, familyId);
    final school = ref.watch(schoolProvider(familyId));
    final childId = children.any((c) => c.id == _childId) ? _childId : (ref.read(childFilterProvider) ?? children.firstOrNull?.id);
    final child = children.where((c) => c.id == childId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.timetableTitle),
        actions: [
          if (!caregiver)
            IconButton(
              key: const Key('timetable.settings'),
              tooltip: l10n.timetableSettings,
              onPressed: () => context.push('/timetable/settings'),
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
      body: school.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(schoolProvider(familyId))),
        data: (s) {
          if (child == null) {
            return HallyEmptyState(icon: Icons.backpack_rounded, title: l10n.timetableNoChildren, body: l10n.timetableNoChildrenBody);
          }
          final mine = s.lessonsOf(child.id);
          final sibling = children.where((c) => c.id != child.id && s.lessonsOf(c.id).isNotEmpty).firstOrNull;
          final bag = s.bagOf(child.id);
          return RefreshIndicator(
            onRefresh: () => ref.refresh(schoolProvider(familyId).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, 120),
              children: [
                if (children.length > 1)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final c in children)
                        Padding(
                          padding: const EdgeInsets.only(right: HallySpace.sm),
                          child: ChoiceChip(
                            key: Key('timetable.child.${c.id}'),
                            avatar: ChildBadge(child: c, size: 20),
                            label: Text(c.firstName),
                            selected: c.id == child.id,
                            selectedColor: HallyColors.softOf(childColor(c.color), Theme.of(context).brightness),
                            onSelected: (_) => setState(() => _childId = c.id),
                          ),
                        ),
                    ]),
                  ),
                const SizedBox(height: HallySpace.sm),
                if (mine.isEmpty && !caregiver)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HallySpace.sm),
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(HallySpace.md),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l10n.timetableEmpty(child.firstName), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(l10n.timetableEmptyBody, style: Theme.of(context).textTheme.bodySmall),
                          if (sibling != null) ...[
                            const SizedBox(height: HallySpace.sm),
                            OutlinedButton.icon(
                              key: const Key('timetable.copy'),
                              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                              onPressed: () => _guard(context, () async {
                                await ref.read(schoolProvider(familyId).notifier).run((r) => r.copy(familyId, fromChildId: sibling.id, toChildId: child.id));
                              }),
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: Text(l10n.timetableCopyFrom(sibling.firstName)),
                            ),
                          ],
                        ]),
                      ),
                    ),
                  ),
                TimetableGrid(
                  state: s,
                  childId: child.id,
                  onTap:
                      caregiver ? null : (weekday, period) => showLessonSheet(context, familyId: familyId, childId: child.id, weekday: weekday, period: period),
                ),
                if (!caregiver)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('timetable.addPeriod'),
                      onPressed: s.settings.bellTimes.length >= 10
                          ? null
                          : () => _guard(context, () async {
                                final bells = [...s.settings.bellTimes, nextBell(s.settings.bellTimes)];
                                await ref.read(schoolProvider(familyId).notifier).run((r) => r.saveSettings(familyId, s.settings.copyWith(bellTimes: bells)));
                              }),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(l10n.timetableAddPeriod),
                    ),
                  ),
                if (bag != null) ...[
                  const SizedBox(height: HallySpace.sm),
                  BagCard(familyId: familyId, bag: bag, showName: false),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A new bell 50 minutes after the last one (08:30 when there is none).
String nextBell(List<String> bells) {
  if (bells.isEmpty) return '08:30';
  final p = bells.last.split(':');
  final m = (int.parse(p[0]) * 60 + int.parse(p[1]) + 50).clamp(0, 23 * 60 + 59);
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// Monday–Friday columns, one row per period: the subject on its colour, item emojis under it.
class TimetableGrid extends StatelessWidget {
  const TimetableGrid({super.key, required this.state, required this.childId, this.onTap});

  final SchoolState state;
  final String childId;
  final void Function(int weekday, int period)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final todayCol = state.todayIsSchoolDay ? state.today.weekday : 0;
    final rows = state.periodsOf(childId);
    final bells = state.settings.bellTimes;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.sm),
        child: Column(
          children: [
            Row(children: [
              const SizedBox(width: 40),
              for (var d = 1; d <= 5; d++)
                Expanded(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: d == todayCol
                          ? BoxDecoration(color: HallyColors.accent(HallyColors.cherry, b), borderRadius: BorderRadius.circular(HallyRadius.pill))
                          : null,
                      child: Text(weekdayShort(context, d),
                          style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700, color: d == todayCol ? Colors.white : null)),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            for (var p = 1; p <= rows; p++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  SizedBox(
                    width: 40,
                    child: Column(children: [
                      Text('$p', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
                      if (p <= bells.length) Text(bells[p - 1], style: theme.textTheme.labelSmall?.copyWith(fontSize: 10)),
                    ]),
                  ),
                  for (var d = 1; d <= 5; d++)
                    Expanded(
                        child: _Cell(
                            lesson: state.lessonAt(childId, d, p),
                            today: d == todayCol,
                            onTap: onTap == null ? null : () => onTap!(d, p),
                            id: 'timetable.cell.$d.$p')),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.lesson, required this.today, required this.onTap, required this.id});

  final Lesson? lesson;
  final bool today;
  final VoidCallback? onTap;
  final String id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final l = lesson;
    final color = l == null ? null : subjectColor(l.subject);
    final emojis = l == null ? '' : l.items.map(itemEmoji).whereType<String>().take(2).join();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: color == null ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4) : HallyColors.softOf(color, b),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HallyRadius.sm),
          side: today ? BorderSide(color: HallyColors.accent(HallyColors.cherry, b).withValues(alpha: 0.35), width: 1.5) : BorderSide.none,
        ),
        child: InkWell(
          key: Key(id),
          borderRadius: BorderRadius.circular(HallyRadius.sm),
          onTap: onTap,
          child: SizedBox(
            height: 50,
            child: Center(
              child: l == null
                  ? Icon(onTap == null ? Icons.remove_rounded : Icons.add_rounded, size: 16, color: theme.hintColor)
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(l.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: HallyColors.readableOn(color!, b))),
                        if (emojis.isNotEmpty) Text(emojis, style: const TextStyle(fontSize: 10)),
                      ]),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Perşembe · 3. ders": pick the subject and what it needs. Items follow the subject to its other periods.
Future<void> showLessonSheet(BuildContext context, {required String familyId, required String childId, required int weekday, required int period}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _LessonSheet(familyId: familyId, childId: childId, weekday: weekday, period: period),
    );

class _LessonSheet extends ConsumerStatefulWidget {
  const _LessonSheet({required this.familyId, required this.childId, required this.weekday, required this.period});

  final String familyId;
  final String childId;
  final int weekday;
  final int period;

  @override
  ConsumerState<_LessonSheet> createState() => _LessonSheetState();
}

class _LessonSheetState extends ConsumerState<_LessonSheet> {
  final _subject = TextEditingController();
  final Set<String> _items = {};
  final List<String> _extraItems = [];
  Lesson? _lesson;
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _subject.dispose();
    super.dispose();
  }

  SchoolState? get _state => ref.read(schoolProvider(widget.familyId)).valueOrNull;

  void _pickSubject(String s) {
    setState(() {
      _subject.text = s;
      if (_items.isEmpty) {
        // Items are remembered per subject: Beden Eğitimi on Monday already needs 👟.
        final same = _state?.lessonsOf(widget.childId).where((l) => l.subject == s && l.items.isNotEmpty).firstOrNull;
        if (same != null) _items.addAll(same.items);
      }
    });
  }

  Future<void> _addItem() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.timetableItemAdd),
        content: TextField(
          key: const Key('lesson.itemField'),
          controller: controller,
          autofocus: true,
          maxLength: 30,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: l10n.timetableItemHint, counterText: ''),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(l10n.timetableItemAddButton),
          ),
        ],
      ),
    );
    final item = text?.trim() ?? '';
    if (item.isEmpty || !mounted) return;
    setState(() {
      if (!_extraItems.contains(item)) _extraItems.add(item);
      _items.add(item);
    });
  }

  Future<void> _save({bool clear = false}) async {
    final subject = clear ? '' : _subject.text.trim();
    if (!clear && subject.isEmpty) return;
    setState(() => _busy = true);
    final notifier = ref.read(schoolProvider(widget.familyId).notifier);
    final items = _items.take(6).toList();
    try {
      var s = await notifier
          .run((r) => r.setLesson(widget.familyId, childId: widget.childId, weekday: widget.weekday, period: widget.period, subject: subject, items: items));
      if (!clear) {
        // The same subject on other days needs the same things.
        for (final other in s.lessonsOf(widget.childId).where((l) => l.subject == subject && !_sameItems(l.items, items)).toList()) {
          s = await notifier
              .run((r) => r.setLesson(widget.familyId, childId: widget.childId, weekday: other.weekday, period: other.period, subject: subject, items: items));
        }
      }
      HapticFeedback.selectionClick();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
      }
    }
  }

  static bool _sameItems(List<String> a, List<String> b) => a.length == b.length && a.toSet().containsAll(b);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(schoolProvider(widget.familyId)).valueOrNull;
    if (!_loaded && state != null) {
      _loaded = true;
      _lesson = state.lessonAt(widget.childId, widget.weekday, widget.period);
      _subject.text = _lesson?.subject ?? '';
      _items.addAll(_lesson?.items ?? const []);
    }
    final used = {for (final l in state?.lessons ?? const <Lesson>[]) l.subject};
    final subjects = {...l10n.timetableSubjects.split('|'), ...used}.toList();
    final usedItems = {for (final l in state?.lessons ?? const <Lesson>[]) ...l.items};
    final items = {...l10n.timetableItems.split('|'), ...usedItems, ..._items, ..._extraItems}.toList();
    final typed = _subject.text.trim();
    final label = theme.textTheme.labelLarge;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.sm, HallySpace.lg, HallySpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(l10n.timetableLessonTitle(weekdayLong(context, widget.weekday), widget.period),
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ),
              if (_lesson != null)
                IconButton(
                    key: const Key('lesson.delete'),
                    tooltip: l10n.timetableLessonClear,
                    onPressed: _busy ? null : () => _save(clear: true),
                    icon: const Icon(Icons.delete_outline)),
            ]),
            const SizedBox(height: HallySpace.sm),
            Text(l10n.timetableSubject, style: label),
            const SizedBox(height: HallySpace.xs),
            Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.xs, children: [
              for (final s in subjects)
                ChoiceChip(
                  key: Key('lesson.subject.$s'),
                  label: Text(s),
                  selected: typed == s,
                  selectedColor: HallyColors.softOf(subjectColor(s), theme.brightness),
                  onSelected: (_) => _pickSubject(s),
                ),
            ]),
            const SizedBox(height: HallySpace.sm),
            TextField(
              key: const Key('lesson.subjectField'),
              controller: _subject,
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration:
                  InputDecoration(hintText: l10n.timetableSubjectHint, prefixIcon: const Icon(Icons.edit_outlined, size: 20), counterText: '', isDense: true),
            ),
            const SizedBox(height: HallySpace.md),
            Text(l10n.timetableItemsQuestion, style: label),
            const SizedBox(height: HallySpace.xs),
            Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.xs, children: [
              for (final i in items)
                FilterChip(
                  key: Key('lesson.item.$i'),
                  label: Text(i),
                  selected: _items.contains(i),
                  onSelected: (on) => setState(() => on ? _items.add(i) : _items.remove(i)),
                ),
              ActionChip(
                  key: const Key('lesson.addItem'), avatar: const Icon(Icons.add, size: 18), label: Text(l10n.timetableItemAddButton), onPressed: _addItem),
            ]),
            const SizedBox(height: HallySpace.md),
            Container(
              padding: const EdgeInsets.all(HallySpace.md),
              decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.butter, theme.brightness), borderRadius: BorderRadius.circular(HallyRadius.md)),
              child: Row(children: [
                const Icon(Icons.repeat_rounded, size: 20),
                const SizedBox(width: HallySpace.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.timetableWeekly, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(l10n.timetableWeeklyBody, style: theme.textTheme.bodySmall),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: HallySpace.md),
            FilledButton(key: const Key('lesson.save'), onPressed: _busy || typed.isEmpty ? null : _save, child: Text(l10n.timetableSave)),
          ],
        ),
      ),
    );
  }
}

/// "🎒 Yarın çantaya": tomorrow's items (and exams to study for) to tick, and "Hazırladık".
class BagCard extends ConsumerWidget {
  const BagCard({super.key, required this.familyId, required this.bag, this.showName = true});

  final String familyId;
  final Bag bag;
  final bool showName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final notifier = ref.read(schoolProvider(familyId).notifier);
    return Card(
      key: Key('bag.${bag.childId}'),
      margin: const EdgeInsets.only(bottom: HallySpace.md),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.md, HallySpace.md, HallySpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Text('🎒', style: TextStyle(fontSize: 26)),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(showName ? l10n.bagTitleFor(bag.childName) : l10n.bagTitle, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  Text(DateFormat('EEEE', _locale(context)).format(bag.day), style: theme.textTheme.bodySmall),
                ]),
              ),
              if (bag.items.isNotEmpty) Text('${bag.packedCount}/${bag.items.length}', key: Key('bag.${bag.childId}.count'), style: theme.textTheme.titleSmall),
            ]),
            if (bag.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HallySpace.sm),
                child: Text(l10n.bagNothing(bag.subjects.join(', ')), style: theme.textTheme.bodySmall),
              ),
            for (final item in bag.items)
              BagItemRow(
                item: item,
                day: bag.day,
                onChanged: (on) => _guard(context, () async {
                  await notifier.run((r) => r.pack(familyId, bag.childId, item.key, on));
                }),
              ),
            const SizedBox(height: HallySpace.xs),
            if (bag.ready)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HallySpace.sm),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded, color: HallyColors.accent(HallyColors.sage, b), size: 20),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(bag.readyByChild ? l10n.bagReadyByChild(bag.childName) : l10n.bagReady,
                        key: Key('bag.${bag.childId}.ready'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
              )
            else
              FilledButton.tonal(
                key: Key('bag.${bag.childId}.done'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => _guard(context, () async {
                  await notifier.run((r) => r.ready(familyId, bag.childId));
                  HapticFeedback.mediumImpact();
                }),
                child: Text(l10n.bagDone),
              ),
          ],
        ),
      ),
    );
  }
}

/// One checkbox line: "👟 Eşofman · Beden Eğitimi" or "📝 Matematik sınavı · Cuma · çalışma".
class BagItemRow extends StatelessWidget {
  const BagItemRow({super.key, required this.item, required this.day, required this.onChanged});

  final BagItem item;
  final DateTime day;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final title = item.isExam ? '📝 ${l10n.bagExam(item.text)}' : item.text;
    final detail = item.isExam
        ? (DateUtils.isSameDay(item.examDate, day) ? l10n.bagExamTomorrow : l10n.bagExamStudy(DateFormat('EEEE', _locale(context)).format(item.examDate!)))
        : item.subjects.isEmpty
            ? l10n.bagEveryDay
            : item.subjects.join(', ');
    return InkWell(
      key: Key('bagItem.${item.key}'),
      borderRadius: BorderRadius.circular(HallyRadius.sm),
      onTap: onChanged == null ? null : () => onChanged!(!item.packed),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Checkbox(value: item.packed, onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false)),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: title, style: TextStyle(fontWeight: FontWeight.w600, decoration: item.packed ? TextDecoration.lineThrough : null)),
                TextSpan(text: ' · $detail', style: theme.textTheme.bodySmall),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// On Today: each child's bag for tomorrow (school evenings only; nothing without a timetable).
class TodayBagCards extends ConsumerWidget {
  const TodayBagCards({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bags = ref.watch(schoolProvider(familyId)).valueOrNull?.bags ?? const <Bag>[];
    final filter = ref.watch(childFilterProvider);
    final shown = bags.where((b) => filter == null || b.childId == filter).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(children: [for (final bag in shown) BagCard(familyId: familyId, bag: bag)]);
  }
}

/// Program ayarları: bell times, the evening note, the child's phone, holidays, every-day items and breaks.
class SchoolSettingsScreen extends ConsumerWidget {
  const SchoolSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final school = ref.watch(schoolProvider(familyId));
    final notifier = ref.read(schoolProvider(familyId).notifier);

    Future<void> save(SchoolSettings next) => _guard(context, () async {
          await notifier.run((r) => r.saveSettings(familyId, next));
        });

    Future<String?> pickTime(String current) async {
      final p = current.split(':');
      final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])));
      if (t == null) return null;
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.schoolSettingsTitle)),
      body: school.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(schoolProvider(familyId))),
        data: (s) {
          final set = s.settings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, 80),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.schoolBellTimes, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text(l10n.schoolBellTimesBody, style: theme.textTheme.bodySmall),
                    const SizedBox(height: HallySpace.sm),
                    Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.xs, children: [
                      for (var i = 0; i < set.bellTimes.length; i++)
                        InputChip(
                          key: Key('school.bell.${i + 1}'),
                          label: Text('${i + 1} · ${set.bellTimes[i]}'),
                          onPressed: () async {
                            final t = await pickTime(set.bellTimes[i]);
                            if (t == null) return;
                            final bells = [...set.bellTimes]..[i] = t;
                            bells.sort();
                            await save(set.copyWith(bellTimes: bells));
                          },
                          onDeleted: i == set.bellTimes.length - 1 ? () => save(set.copyWith(bellTimes: set.bellTimes.sublist(0, i))) : null,
                        ),
                      if (set.bellTimes.length < 10)
                        ActionChip(
                          key: const Key('school.bell.add'),
                          avatar: const Icon(Icons.add, size: 18),
                          label: Text(l10n.schoolBellAdd),
                          onPressed: () => save(set.copyWith(bellTimes: [...set.bellTimes, nextBell(set.bellTimes)])),
                        ),
                    ]),
                  ]),
                ),
              ),
              Card(
                child: Column(children: [
                  SwitchListTile(
                    key: const Key('school.reminder'),
                    title: Text(l10n.schoolReminder),
                    subtitle: Text(l10n.schoolReminderBody),
                    value: set.reminderTime != null,
                    onChanged: (on) => save(set.copyWith(reminderTime: () => on ? '19:30' : null)),
                  ),
                  if (set.reminderTime != null)
                    ListTile(
                      title: Text(l10n.schoolReminderTime),
                      trailing: OutlinedButton(
                        key: const Key('school.reminderTime'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: () async {
                          final t = await pickTime(set.reminderTime!);
                          if (t != null) await save(set.copyWith(reminderTime: () => t));
                        },
                        child: Text(set.reminderTime!),
                      ),
                    ),
                  SwitchListTile(
                    key: const Key('school.childPhone'),
                    title: Text(l10n.schoolChildPhone),
                    subtitle: Text(l10n.schoolChildPhoneBody),
                    value: set.childPhone,
                    onChanged: (on) => save(set.copyWith(childPhone: on)),
                  ),
                  SwitchListTile(
                    key: const Key('school.quiet'),
                    title: Text(l10n.schoolQuiet),
                    subtitle: Text(l10n.schoolQuietBody),
                    value: set.quietOnHolidays,
                    onChanged: (on) => save(set.copyWith(quietOnHolidays: on)),
                  ),
                ]),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.schoolDailyItems, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text(l10n.schoolDailyItemsBody, style: theme.textTheme.bodySmall),
                    const SizedBox(height: HallySpace.sm),
                    Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.xs, children: [
                      for (final item in set.dailyItems)
                        InputChip(label: Text(item), onDeleted: () => save(set.copyWith(dailyItems: set.dailyItems.where((i) => i != item).toList()))),
                      if (set.dailyItems.length < 6)
                        ActionChip(
                          key: const Key('school.daily.add'),
                          avatar: const Icon(Icons.add, size: 18),
                          label: Text(l10n.timetableItemAddButton),
                          onPressed: () async {
                            final item = await _askText(context, l10n.schoolDailyItems, l10n.schoolDailyItemHint);
                            if (item != null) await save(set.copyWith(dailyItems: [...set.dailyItems, item]));
                          },
                        ),
                    ]),
                  ]),
                ),
              ),
              Card(
                child: Column(children: [
                  for (final br in s.breaks)
                    ListTile(
                      key: Key('school.break.${br.id}'),
                      leading: const Text('🏖️', style: TextStyle(fontSize: 22)),
                      title: Text(br.title),
                      subtitle: Text(
                          '${DateFormat.MMMd(_locale(context)).format(br.from)} – ${DateFormat.MMMd(_locale(context)).format(br.to)} · ${l10n.schoolBreakQuiet}'),
                      trailing: IconButton(
                        tooltip: l10n.schoolBreakDelete,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _guard(context, () async {
                          await notifier.run((r) => r.deleteBreak(familyId, br.id));
                        }),
                      ),
                    ),
                  ListTile(
                    leading: s.breaks.isEmpty ? const Text('🏖️', style: TextStyle(fontSize: 22)) : null,
                    title: Text(l10n.schoolBreaks),
                    subtitle: s.breaks.isEmpty ? Text(l10n.schoolBreaksBody) : null,
                    trailing: OutlinedButton(
                      key: const Key('school.break.add'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                      onPressed: () async {
                        final now = DateUtils.dateOnly(DateTime.now());
                        final range = await showDateRangePicker(
                            context: context, firstDate: now.subtract(const Duration(days: 7)), lastDate: now.add(const Duration(days: 365)));
                        if (range == null || !context.mounted) return;
                        final title = await _askText(context, l10n.schoolBreaks, l10n.schoolBreakHint, initial: l10n.schoolBreakDefault);
                        if (title == null || !context.mounted) return;
                        await _guard(context, () async {
                          await notifier.run((r) => r.addBreak(familyId, title, range.start, range.end));
                        });
                      },
                      child: Text(l10n.schoolBreakAdd),
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: Text(l10n.schoolCaregiverNote, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              ),
            ],
          );
        },
      ),
    );
  }
}

Future<String?> _askText(BuildContext context, String title, String hint, {String? initial}) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: initial);
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('school.textField'),
        controller: controller,
        autofocus: true,
        maxLength: 30,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: hint, counterText: ''),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.cancel)),
        FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(l10n.timetableSave)),
      ],
    ),
  );
  final t = text?.trim() ?? '';
  return t.isEmpty ? null : t;
}

/// Child mode: "Bugünün dersleri" (the current one marked) and "Yarın çantana" with "Çantam hazır!".
class KidSchoolCards extends ConsumerWidget {
  const KidSchoolCards({super.key, required this.school});

  final ChildSchool school;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function(ChildApi api) action, {String? done}) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action(ref.read(childApiProvider));
      if (done != null) {
        HapticFeedback.mediumImpact();
        messenger.showSnackBar(SnackBar(content: Text(done)));
      }
      ref.invalidate(childHomeProvider);
    } on UnpairedException {
      ref.invalidate(childSessionProvider);
    } on ApiException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final bag = school.bag;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (school.today.isNotEmpty)
        Container(
          key: const Key('kid.lessons'),
          margin: const EdgeInsets.only(bottom: HallySpace.md),
          padding: const EdgeInsets.all(HallySpace.md),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [HallyColors.softOf(HallyColors.mist, b), HallyColors.softOf(HallyColors.lavender, b)]),
            borderRadius: BorderRadius.circular(HallyRadius.lg),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('📚', style: TextStyle(fontSize: 26)),
              const SizedBox(width: HallySpace.sm),
              Text(l10n.kidLessonsToday, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: HallySpace.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final l in school.today)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: HallyColors.softOf(subjectColor(l.subject), b),
                      borderRadius: BorderRadius.circular(HallyRadius.md),
                      border: l.now ? Border.all(color: HallyColors.accent(HallyColors.cherry, b), width: 2) : null,
                    ),
                    child: Column(children: [
                      Text(l.subject, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                      Text(l.now ? l10n.kidLessonNow : (l.start ?? '${l.period}.'), style: theme.textTheme.labelSmall),
                    ]),
                  ),
              ]),
            ),
          ]),
        ),
      if (bag != null)
        Card(
          key: const Key('kid.bag'),
          margin: const EdgeInsets.only(bottom: HallySpace.md),
          child: Padding(
            padding: const EdgeInsets.all(HallySpace.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Text('🎒', style: TextStyle(fontSize: 30)),
                const SizedBox(width: HallySpace.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.kidBagTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    Text(DateFormat('EEEE', _locale(context)).format(bag.day), style: theme.textTheme.bodySmall),
                  ]),
                ),
                if (bag.childClaim == null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('+1', style: theme.textTheme.titleSmall?.copyWith(color: HallyColors.accent(HallyColors.cherry, b))),
                    const SizedBox(width: 2),
                    const CherryIcon(size: 18),
                  ]),
              ]),
              if (bag.items.isEmpty) Padding(padding: const EdgeInsets.only(top: HallySpace.sm), child: Text(l10n.bagNothing(bag.subjects.join(', ')))),
              for (final item in bag.items)
                BagItemRow(
                  item: item,
                  day: bag.day,
                  onChanged: (on) => _run(context, ref, (api) => api.packBag(item.key, on)),
                ),
              const SizedBox(height: HallySpace.sm),
              if (bag.childClaim == 'Pending')
                Center(child: HallyPill(label: l10n.kidWaiting, color: HallyColors.butter))
              else if (bag.childClaim == 'Done' || bag.ready)
                Center(child: Text(l10n.kidBagReady, key: const Key('kid.bag.ready'), style: const TextStyle(fontWeight: FontWeight.w700)))
              else
                FilledButton(
                  key: const Key('kid.bag.done'),
                  onPressed: () => _run(context, ref, (api) => api.bagReady(), done: l10n.kidBagSent),
                  child: Text(l10n.kidBagDone),
                ),
            ]),
          ),
        ),
    ]);
  }
}
