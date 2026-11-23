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
import '../profile/profile_screen.dart';

/// The child picked on the Kids tab. Null means "the first child".
final kidsSelectedProvider = StateProvider<String?>((ref) => null);

/// The trackers a child can have, grouped on the Kids tab.
enum Tracker { study, habits, stars, screenTime, sleep, feeding, medications, health }

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
                color: HallyColors.sky,
                title: l10n.kidsEmptyTitle,
                body: l10n.childAddBody,
                action: FilledButton.icon(
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
              await ref.refresh(familyProvider(familyId).future);
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
    final fits = trackersForAge(age);

    _TileData tile(Tracker t) => switch (t) {
          Tracker.study => _TileData(t, Icons.menu_book_rounded, HallyColors.study, l10n.studyTitle, '/study',
              value: today == null ? null : dur(today.studyMinutes),
              progress: data?.studyGoalMinutes == null || today == null ? null : today.studyMinutes / data!.studyGoalMinutes!),
          Tracker.habits => _TileData(t, Icons.local_fire_department_rounded, HallyColors.apricot, l10n.habitsTitle, '/habits',
              value: data == null || data.habits.isEmpty ? null : l10n.kidsStreakDays(data.habits.map((h) => h.streak).reduce(math.max)),
              note: today == null || today.habitsScheduled == 0 ? null : l10n.kidsDoneOf(today.habitsDone, today.habitsScheduled),
              ring: today == null || today.habitsScheduled == 0 ? null : '${today.habitsDone}/${today.habitsScheduled}',
              ringProgress: today == null || today.habitsScheduled == 0 ? null : today.habitsDone / today.habitsScheduled),
          Tracker.stars => _TileData(t, Icons.star_rounded, HallyColors.star, l10n.pointsTitle, '/stars', value: data == null ? null : '${data.starBalance}'),
          Tracker.screenTime => _TileData(t, Icons.phone_android_rounded, HallyColors.apricot, l10n.screenTimeTitle, '/screen-time',
              value: today == null ? null : dur(today.screenMinutes),
              progress: data?.screenGoalMinutes == null || today == null ? null : today.screenMinutes / data!.screenGoalMinutes!,
              overIsBad: true),
          Tracker.sleep => _TileData(t, Icons.bedtime_rounded, HallyColors.sky, l10n.sleepTitle, '/sleep',
              value: today == null || today.sleepMinutes == 0 ? null : dur(today.sleepMinutes)),
          Tracker.feeding => _TileData(t, Icons.baby_changing_station_rounded, HallyColors.mint, l10n.feedingTitle, '/feeding',
              value: today == null || today.feeds == 0 ? null : l10n.kidsFeeds(today.feeds)),
          Tracker.medications => _TileData(t, Icons.medication_rounded, HallyColors.cherry, l10n.medicationsTitle, '/medications',
              value: today == null || today.doses == 0 ? null : l10n.kidsDoses(today.doses)),
          Tracker.health => _TileData(t, Icons.health_and_safety_rounded, HallyColors.mint, l10n.healthTitle, '/health',
              note: data == null
                  ? null
                  : data.health.vaccinesOverdue > 0
                      ? l10n.kidsVaccinesOverdue(data.health.vaccinesOverdue)
                      : data.health.vaccinesDueSoon > 0
                          ? l10n.kidsVaccinesSoon(data.health.vaccinesDueSoon)
                          : null,
              warn: (data?.health.vaccinesOverdue ?? 0) > 0),
        };

    const growth = [Tracker.study, Tracker.habits, Tracker.stars, Tracker.screenTime];
    const care = [Tracker.sleep, Tracker.feeding, Tracker.medications, Tracker.health];
    // Babies and toddlers: care first.
    final careFirst = age != null && age <= 3;
    final groups = [
      (l10n.kidsGrowth, [for (final t in growth) if (fits.contains(t)) tile(t)]),
      (l10n.kidsCare, [for (final t in care) if (fits.contains(t)) tile(t)]),
    ];
    final ordered = careFirst ? groups.reversed.toList() : groups;
    final more = [for (final t in Tracker.values) if (!fits.contains(t)) tile(t)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Summary(
          child: c,
          tiles: [for (final t in (careFirst ? [Tracker.sleep, Tracker.feeding, Tracker.medications] : [Tracker.study, Tracker.screenTime, Tracker.habits])) if (fits.contains(t)) tile(t)],
          onInsights: () => context.push('/child/${c.id}/insights'),
          onEdit: () => showChildSheet(context, ref, familyId: widget.familyId, child: c, siblings: widget.siblings),
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
  const _TileData(this.tracker, this.icon, this.color, this.title, this.route, {this.value, this.note, this.progress, this.overIsBad = false, this.warn = false, this.ring, this.ringProgress});

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
  const _Summary({required this.child, required this.tiles, required this.onInsights, required this.onEdit});

  final ChildProfile child;
  final List<_TileData> tiles;
  final VoidCallback onInsights;
  final VoidCallback onEdit;

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
                IconButton(key: const Key('kids.edit'), tooltip: l10n.insightsEditChild, onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
                IconButton(key: const Key('kids.insights'), tooltip: l10n.insightsTitle, onPressed: onInsights, icon: const Icon(Icons.insights_rounded, size: 22)),
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
              color: over ? HallyColors.error : (p == null ? HallyColors.softOf(color, theme.brightness) : color),
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
    final noteColor = data.warn ? HallyColors.error : HallyColors.readableOn(data.color, theme.brightness);
    return HallyPressable(
      key: Key('kids.tile.${data.tracker.name}'),
      onTap: () => context.push(data.route),
      child: Container(
        padding: const EdgeInsets.all(HallySpace.md - 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(HallyRadius.lg),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                HallyIconBadge(icon: data.icon, color: data.color, size: 34),
                const Spacer(),
                Icon(Icons.chevron_right_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: HallySpace.sm + 2),
            const Spacer(),
            if (data.value != null) Text(data.value!, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1)),
            Text(data.title, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (data.note != null)
              Text(data.note!, style: theme.textTheme.labelSmall?.copyWith(color: noteColor, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (p != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: p.clamp(0, 1).toDouble(),
                    minHeight: 5,
                    backgroundColor: theme.colorScheme.outlineVariant,
                    color: over ? HallyColors.error : data.color,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
