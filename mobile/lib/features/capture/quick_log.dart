import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../kids/kids_screen.dart';
import '../screen_time/screen_time_repository.dart';
import '../sleep/sleep_repository.dart';
import '../study/study_repository.dart';

/// "Quick log" in the add sheet: pick a child, then one tap starts or stops sleep, screen time or homework.
/// Feeding, medication and stars need a detail, so they open their screen. Only trackers that fit the child's
/// age are shown.
class QuickLog extends ConsumerStatefulWidget {
  const QuickLog({super.key, required this.familyId, required this.onDone});

  final String familyId;

  /// Closes the sheet; [message] is shown as a snack bar afterwards, [route] opened instead when set.
  final void Function({String? message, String? route}) onDone;

  @override
  ConsumerState<QuickLog> createState() => _QuickLogState();
}

class _QuickLogState extends ConsumerState<QuickLog> {
  String? _childId;
  String? _busy;

  Future<void> _run(String key, Future<void> Function() action, String message) async {
    if (_busy != null) return;
    setState(() => _busy = key);
    try {
      await action();
      if (mounted) setState(() => _busy = null);
      widget.onDone(message: message);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final children = watchChildren(ref, widget.familyId);
    if (children.isEmpty) return const SizedBox.shrink();
    final child = children.where((c) => c.id == (_childId ?? ref.read(kidsSelectedProvider))).firstOrNull ?? children.first;
    final fits = trackersForAge(childAge(child, DateTime.now()));
    final f = widget.familyId;

    final asleep = ref.watch(sleepStatusProvider(f)).valueOrNull?[child.id]?.asleep != null;
    final screenOn = ref.watch(screenTimeProvider(f)).valueOrNull?[child.id]?.isRunning ?? false;
    final studyOn = ref.watch(studyStatusProvider(f)).valueOrNull?[child.id]?.isRunning ?? false;
    final name = child.firstName;

    final tiles = <Widget>[
      if (fits.contains(Tracker.sleep))
        _QuickTile(
          key: const Key('quick.sleep'),
          icon: asleep ? Icons.wb_sunny_rounded : Icons.bedtime_rounded,
          color: HallyModule.sleep,
          title: asleep ? l10n.quickWokeUp : l10n.quickSleepStart,
          busy: _busy == 'sleep',
          onTap: () => _run('sleep', () async {
            final repo = ref.read(sleepRepositoryProvider);
            asleep ? await repo.awake(f, child.id) : await repo.asleep(f, child.id);
            ref.invalidate(sleepStatusProvider(f));
          }, asleep ? l10n.quickWokeUpDone(name) : l10n.quickSleepDone(name)),
        ),
      if (fits.contains(Tracker.feeding))
        _QuickTile(key: const Key('quick.feeding'), icon: Icons.baby_changing_station_rounded, color: HallyModule.feeding, title: l10n.feedingTitle,
            onTap: () => widget.onDone(route: '/feeding')),
      if (fits.contains(Tracker.medications))
        _QuickTile(key: const Key('quick.medications'), icon: Icons.medication_rounded, color: HallyModule.medications, title: l10n.quickMedication,
            onTap: () => widget.onDone(route: '/medications')),
      if (fits.contains(Tracker.screenTime))
        _QuickTile(
          key: const Key('quick.screen'),
          icon: screenOn ? Icons.stop_circle_rounded : Icons.phone_android_rounded,
          color: HallyModule.screenTime,
          title: screenOn ? l10n.quickScreenStop : l10n.quickScreenStart,
          busy: _busy == 'screen',
          onTap: () => _run('screen', () async {
            final n = ref.read(screenTimeProvider(f).notifier);
            screenOn ? await n.stop(child.id) : await n.start(child.id);
          }, screenOn ? l10n.quickScreenStopped(name) : l10n.quickScreenStarted(name)),
        ),
      if (fits.contains(Tracker.study))
        _QuickTile(
          key: const Key('quick.study'),
          icon: studyOn ? Icons.stop_circle_rounded : Icons.menu_book_rounded,
          color: HallyModule.study,
          title: studyOn ? l10n.quickStudyStop : l10n.quickStudyStart,
          busy: _busy == 'study',
          onTap: () => _run('study', () async {
            final repo = ref.read(studyRepositoryProvider);
            studyOn ? await repo.stop(f, child.id) : await repo.start(f, child.id, 'Homework');
            ref.invalidate(studyStatusProvider(f));
          }, studyOn ? l10n.quickStudyStopped(name) : l10n.quickStudyStarted(name)),
        ),
      if (fits.contains(Tracker.stars))
        _QuickTile(key: const Key('quick.stars'), icon: Icons.star_rounded, color: HallyModule.rewards, title: l10n.quickStars,
            onTap: () => widget.onDone(route: '/stars')),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.bolt_rounded, color: HallyColors.apricot, size: 20),
            const SizedBox(width: 6),
            Text(l10n.quickLogTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: HallySpace.sm),
        if (children.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: HallySpace.sm),
            child: Wrap(
              spacing: HallySpace.sm,
              children: [
                for (final c in children)
                  ChoiceChip(
                    key: Key('quick.child.${c.id}'),
                    showCheckmark: false,
                    avatar: ChildBadge(child: c, size: 22),
                    label: Text(c.firstName),
                    selected: c.id == child.id,
                    onSelected: (_) => setState(() => _childId = c.id),
                  ),
              ],
            ),
          ),
        HallyTileGrid(children: tiles),
      ],
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({super.key, required this.icon, required this.color, required this.title, required this.onTap, this.busy = false});

  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HallyPressable(
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(HallyRadius.md + 2),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            busy
                ? const SizedBox.square(dimension: 34, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2.5)))
                : HallyIconBadge(icon: icon, color: color, size: 34),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 2)),
          ],
        ),
      ),
    );
  }
}
