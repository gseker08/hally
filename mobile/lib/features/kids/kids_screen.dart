import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import '../insights/insights_repository.dart';
import '../sleep/sleep_screen.dart';
import '../exams/exam_screens.dart' show examCountdown;
import '../exams/exams.dart';
import '../profile/profile_screen.dart';

/// The child picked on the Kids tab. Null means "the first child".
final kidsSelectedProvider = StateProvider<String?>((ref) => null);

/// The trackers a child can have, grouped on the Kids tab.
enum Tracker { study, exams, habits, stars, screenTime, sleep, feeding, medications, health }

/// Which trackers fit a child's age. Unknown age shows everything; hidden ones stay one tap away under "More".
/// Ages come from the birth year only, so they are approximate on purpose.
Set<Tracker> trackersForAge(int? age) {
  if (age == null) return Tracker.values.toSet();
  return {
    Tracker.sleep,
    Tracker.medications,
    Tracker.health,
    Tracker.habits,
    if (age <= 3) Tracker.feeding,
    if (age >= 2) Tracker.screenTime,
    if (age >= 3) Tracker.stars,
    if (age >= 5) Tracker.study,
    if (age >= 6) Tracker.exams,
  };
}

int? childAge(ChildProfile c, DateTime now) => c.birthYear == null ? null : math.max(0, now.year - c.birthYear!);

/// Kids tab: pick a child, see their day at a glance, open any tracker. Everything that belongs to one
/// child lives here; adult chores live on the Family tab.
class KidsScreen extends ConsumerWidget {
  const KidsScreen({super.key, this.now});

  /// Injected in tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final family = ref.watch(familyProvider(familyId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabKids),
        actions: const [ProfileButton(), SizedBox(width: HallySpace.sm)],
      ),
      body: family.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(familyProvider(familyId))),
        data: (f) {
          if (f.children.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(HallySpace.lg),
              child: HallyEmptyState(
                icon: Icons.child_care_rounded,
                color: HallyModule.kids,
                title: l10n.kidsEmptyTitle,
                body: l10n.childAddBody,
                action: ref.watch(isCaregiverProvider)
                    ? null
                    : FilledButton.icon(
                        key: const Key('kids.addFirst'),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(l10n.childAdd),
                        onPressed: () => showChildSheet(context, ref, familyId: f.id, siblings: f.children),
                      ),
              ),
            );
          }
          final selectedId = ref.watch(kidsSelectedProvider);
          final child = f.children.where((c) => c.id == selectedId).firstOrNull ?? f.children.first;
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(childInsightsProvider);
              ref.invalidate(familyProvider(familyId));
              await ref.read(familyProvider(familyId).future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, 120),
              children: [
                _ChildSwitcher(family: f, selected: child),
                const SizedBox(height: HallySpace.md),
                _ChildDay(familyId: f.id, child: child, siblings: f.children, now: now ?? DateTime.now()),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ChildSwitcher extends ConsumerWidget {
  const _ChildSwitcher({required this.family, required this.selected});

  final FamilyDetails family;
  final ChildProfile selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final now = DateTime.now();
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final c in family.children)
            Padding(
              padding: const EdgeInsets.only(right: HallySpace.sm),
              child: HallyPressable(
                onTap: () => ref.read(kidsSelectedProvider.notifier).state = c.id,
                child: AnimatedContainer(
                  key: Key('kids.child.${c.id}'),
                  duration: HallyMotion.fast,
                  padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: c.id == selected.id ? childColor(c.color) : theme.colorScheme.outlineVariant,
                      width: c.id == selected.id ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      ChildBadge(child: c, size: 34),
                      const SizedBox(width: HallySpace.sm),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.firstName, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          if (childAge(c, now) case final age?) Text(l10n.kidsAge(age), style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!ref.watch(isCaregiverProvider))
            Tooltip(
              message: l10n.childAdd,
              child: HallyPressable(
                key: const Key('kids.add'),
                onTap: () => showChildSheet(context, ref, familyId: family.id, siblings: family.children),
                child: Container(
                  width: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: theme.colorScheme.outlineVariant, width: 1.5),
                  ),
                  child: Icon(Icons.add_rounded, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChildDay extends ConsumerStatefulWidget {
  const _ChildDay({required this.familyId, required this.child, required this.siblings, required this.now});

  final String familyId;
  final ChildProfile child;
  final List<ChildProfile> siblings;
  final DateTime now;

  @override
  ConsumerState<_ChildDay> createState() => _ChildDayState();
}

class _ChildDayState extends ConsumerState<_ChildDay> {
  bool _showMore = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    String dur(int m) => formatSleepMinutes(m, turkish: tr);
    final c = widget.child;
    final day = insightsDay(widget.now);
    final data = ref.watch(childInsightsProvider((widget.familyId, c.id, day, day))).valueOrNull;
    final today = data?.days.lastOrNull;
    final age = childAge(c, widget.now);
    // A caregiver without health permission doesn't get the health card at all.
    final fits = trackersForAge(age).where((t) => t != Tracker.health || ref.watch(canSeeHealthProvider)).toSet();

    final nextExam = (ref.watch(examsProvider(widget.familyId)).valueOrNull ?? const <Exam>[]).where((e) => e.childId == c.id && e.upcoming).firstOrNull;

    _TileData tile(Tracker t) => switch (t) {
          Tracker.study => _TileData(t, Icons.menu_book_rounded, HallyModule.study, l10n.studyTitle, '/study',
              value: today == null ? null : dur(today.studyMinutes),
              progress: data?.studyGoalMinutes == null || today == null ? null : today.studyMinutes / data!.studyGoalMinutes!),
          Tracker.exams => _TileData(t, Icons.edit_note_rounded, HallyModule.study, l10n.examsTitle, '/exams?child=${c.id}',
              value: nextExam == null ? null : examCountdown(l10n, nextExam.daysLeft), note: nextExam?.subject),
          Tracker.habits => _TileData(t, Icons.local_fire_department_rounded, HallyModule.habits, l10n.habitsTitle, '/habits',
              value: data == null || data.habits.isEmpty ? null : l10n.kidsStreakDays(data.habits.map((h) => h.streak).reduce(math.max)),
              note: today == null || today.habitsScheduled == 0 ? null : l10n.kidsDoneOf(today.habitsDone, today.habitsScheduled),
              ring: today == null || today.habitsScheduled == 0 ? null : '${today.habitsDone}/${today.habitsScheduled}',
              ringProgress: today == null || today.habitsScheduled == 0 ? null : today.habitsDone / today.habitsScheduled),
          Tracker.stars =>
            _TileData(t, Icons.star_rounded, HallyModule.rewards, l10n.pointsTitle, '/stars', value: data == null ? null : '${data.starBalance}'),
          Tracker.screenTime => _TileData(t, Icons.phone_android_rounded, HallyModule.screenTime, l10n.screenTimeTitle, '/screen-time',
              value: today == null ? null : dur(today.screenMinutes),
              progress: data?.screenGoalMinutes == null || today == null ? null : today.screenMinutes / data!.screenGoalMinutes!,
              overIsBad: true),
          Tracker.sleep => _TileData(t, Icons.bedtime_rounded, HallyModule.sleep, l10n.sleepTitle, '/sleep',
              value: today == null || today.sleepMinutes == 0 ? null : dur(today.sleepMinutes)),
          Tracker.feeding => _TileData(t, Icons.baby_changing_station_rounded, HallyModule.feeding, l10n.feedingTitle, '/feeding',
              value: today == null || today.feeds == 0 ? null : l10n.kidsFeeds(today.feeds)),
          Tracker.medications => _TileData(t, Icons.medication_rounded, HallyModule.medications, l10n.medicationsTitle, '/medications',
              value: today == null || today.doses == 0 ? null : l10n.kidsDoses(today.doses)),
          Tracker.health => _TileData(t, Icons.health_and_safety_rounded, HallyModule.health, l10n.healthTitle, '/health',
              note: data == null
                  ? null
                  : data.health.vaccinesOverdue > 0
                      ? l10n.kidsVaccinesOverdue(data.health.vaccinesOverdue)
                      : data.health.vaccinesDueSoon > 0
                          ? l10n.kidsVaccinesSoon(data.health.vaccinesDueSoon)
                          : null,
              warn: (data?.health.vaccinesOverdue ?? 0) > 0),
        };

    const growth = [Tracker.study, Tracker.exams, Tracker.habits, Tracker.stars, Tracker.screenTime];
    const care = [Tracker.sleep, Tracker.feeding, Tracker.medications, Tracker.health];
    // Babies and toddlers: care first.
    final careFirst = age != null && age <= 3;
    final groups = [
      (
        l10n.kidsGrowth,
        [
          for (final t in growth)
            if (fits.contains(t)) tile(t)
        ]
      ),
      (
        l10n.kidsCare,
        [
          for (final t in care)
            if (fits.contains(t)) tile(t)
        ]
      ),
    ];
    final ordered = careFirst ? groups.reversed.toList() : groups;
    final more = [
      for (final t in Tracker.values)
        if (!fits.contains(t) && (t != Tracker.health || ref.watch(canSeeHealthProvider))) tile(t),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Summary(
          child: c,
          tiles: [
            for (final t in (careFirst ? [Tracker.sleep, Tracker.feeding, Tracker.medications] : [Tracker.study, Tracker.screenTime, Tracker.habits]))
              if (fits.contains(t)) tile(t)
          ],
          onInsights: () => context.push('/child/${c.id}/insights'),
          onPhone: ref.watch(isCaregiverProvider) ? null : () => context.push('/family/${widget.familyId}/child/${c.id}/phone'),
          onAllowance: ref.watch(isCaregiverProvider)
              ? null
              : () => context.push('/allowance/${c.id}?familyId=${widget.familyId}&name=${Uri.encodeQueryComponent(c.firstName)}'),
          onEdit: ref.watch(isCaregiverProvider) ? null : () => showChildSheet(context, ref, familyId: widget.familyId, child: c, siblings: widget.siblings),
        ),
        for (final (title, tiles) in ordered)
          if (tiles.isNotEmpty) ...[
            HallySectionHeader(title: title),
            _Grid(tiles: tiles),
          ],
        if (more.isNotEmpty) ...[
          const SizedBox(height: HallySpace.sm),
          TextButton.icon(
            key: const Key('kids.more'),
            onPressed: () => setState(() => _showMore = !_showMore),
            icon: Icon(_showMore ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            label: Text(l10n.kidsMoreTrackers(more.length)),
          ),
          if (_showMore) _Grid(tiles: more),
        ],
      ],
    );
  }
}

class _TileData {
  const _TileData(this.tracker, this.icon, this.color, this.title, this.route,
      {this.value, this.note, this.progress, this.overIsBad = false, this.warn = false, this.ring, this.ringProgress});

  final Tracker tracker;
  final IconData icon;
  final Color color;
  final String title;
  final String route;
  final String? value;
  final String? note;
  final double? progress;
  final bool overIsBad;
  final bool warn;

  /// Shorter value and progress for the summary ring, when they differ from the tile.
  final String? ring;
  final double? ringProgress;
}

class _Summary extends StatelessWidget {
  const _Summary({required this.child, required this.tiles, required this.onInsights, required this.onEdit, this.onPhone, this.onAllowance});

  final ChildProfile child;
  final List<_TileData> tiles;
  final VoidCallback onInsights;

  /// Null for caregivers: editing a child is for parents.
  final VoidCallback? onEdit;

  /// Pair the child's own phone (child mode). Null for caregivers.
  final VoidCallback? onPhone;

  /// Harçlık (parents only).
  final VoidCallback? onAllowance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.xs, HallySpace.md),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text(l10n.kidsTodayOf(child.firstName), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                if (onEdit != null)
                  IconButton(key: const Key('kids.edit'), tooltip: l10n.insightsEditChild, onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
                if (onAllowance != null)
                  IconButton(
                      key: const Key('kids.allowance'),
                      tooltip: l10n.allowanceTitle,
                      onPressed: onAllowance,
                      icon: const Icon(Icons.savings_outlined, size: 20)),
                if (onPhone != null)
                  IconButton(
                      key: const Key('kids.phone'), tooltip: l10n.childPhoneConnect, onPressed: onPhone, icon: const Icon(Icons.smartphone_rounded, size: 20)),
                IconButton(
                    key: const Key('kids.insights'), tooltip: l10n.insightsTitle, onPressed: onInsights, icon: const Icon(Icons.insights_rounded, size: 22)),
              ],
            ),
            const SizedBox(height: HallySpace.xs),
            Row(
              children: [
                for (final t in tiles)
                  Expanded(
                    child: Column(
                      children: [
                        _Ring(value: t.ring ?? t.value ?? '–', progress: t.ringProgress ?? t.progress, color: t.color, overIsBad: t.overIsBad),
                        const SizedBox(height: 6),
                        Text(t.title, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.value, required this.progress, required this.color, this.overIsBad = false});

  final String value;
  final double? progress;
  final Color color;
  final bool overIsBad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = progress;
    final over = overIsBad && p != null && p > 1;
    return SizedBox.square(
      dimension: 68,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: p == null ? 1 : p.clamp(0, 1).toDouble(),
              strokeWidth: 6,
              strokeCap: StrokeCap.round,
              backgroundColor: theme.colorScheme.outlineVariant,
              color: over ? theme.colorScheme.error : (p == null ? HallyColors.softOf(color, theme.brightness) : HallyColors.accent(color, theme.brightness)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: FittedBox(child: Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800))),
          ),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.tiles});

  final List<_TileData> tiles;

  @override
  Widget build(BuildContext context) => HallyTileGrid(children: [for (final t in tiles) _Tile(data: t)]);
}

class _Tile extends StatelessWidget {
  const _Tile({required this.data});

  final _TileData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = data.progress;
    final over = data.overIsBad && p != null && p > 1;
    final b = theme.brightness;
    final fg = HallyColors.readableOn(data.color, b);
    final noteColor = data.warn ? theme.colorScheme.error : fg;
    return HallyPressable(
      key: Key('kids.tile.${data.tracker.name}'),
      onTap: () => context.push(data.route),
      child: Container(
        padding: const EdgeInsets.all(HallySpace.md - 2),
        decoration: BoxDecoration(
          color: HallyColors.softOf(data.color, b),
          borderRadius: BorderRadius.circular(HallyRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: b == Brightness.dark ? 0.35 : 0.7), borderRadius: BorderRadius.circular(12)),
                  child: Icon(data.icon, size: 20, color: fg),
                ),
                const Spacer(),
                Icon(Icons.chevron_right_rounded, size: 18, color: fg),
              ],
            ),
            const SizedBox(height: HallySpace.sm + 2),
            const Spacer(),
            if (data.value != null) Text(data.value!, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1)),
            Text(data.title, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (data.note != null)
              Text(data.note!,
                  style: theme.textTheme.labelSmall?.copyWith(color: noteColor, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (p != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: p.clamp(0, 1).toDouble(),
                    minHeight: 5,
                    backgroundColor: theme.colorScheme.surface.withValues(alpha: b == Brightness.dark ? 0.3 : 0.75),
                    color: over ? theme.colorScheme.error : HallyColors.accent(data.color, b),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
