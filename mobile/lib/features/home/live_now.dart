import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../screen_time/screen_time_repository.dart';
import '../sleep/sleep_repository.dart';
import '../sleep/sleep_screen.dart';
import '../study/study_repository.dart';
import '../../core/locale/units.dart';

/// One running timer shown on Today.
class LiveItem {
  const LiveItem({required this.key, required this.icon, required this.color, required this.label, required this.value, required this.route, this.progress});

  final String key;
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String route;
  final double? progress;
}

/// "Right now" strip on Today: who is asleep, whose screen time or homework timer is running. Hidden when nothing
/// runs. All three sources already follow the other parent's taps live over the family hub.
class LiveNowStrip extends ConsumerStatefulWidget {
  const LiveNowStrip({super.key, required this.familyId});

  final String familyId;

  @override
  ConsumerState<LiveNowStrip> createState() => _LiveNowStripState();
}

class _LiveNowStripState extends ConsumerState<LiveNowStrip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lang = langOf(context);
    String dur(int seconds) => formatSleepMinutes(seconds ~/ 60, lang: lang);
    final now = DateTime.now();
    final children = watchChildren(ref, widget.familyId);
    if (children.isEmpty) return const SizedBox.shrink();
    final sleep = ref.watch(sleepStatusProvider(widget.familyId)).valueOrNull ?? const {};
    final screen = ref.watch(screenTimeProvider(widget.familyId)).valueOrNull ?? const {};
    final study = ref.watch(studyStatusProvider(widget.familyId)).valueOrNull ?? const {};

    final items = <LiveItem>[
      for (final c in children) ...[
        if (sleep[c.id]?.asleep case final s?)
          LiveItem(
            key: 'sleep.${c.id}',
            icon: Icons.bedtime_rounded,
            color: HallyModule.sleep,
            label: l10n.liveAsleep(c.firstName),
            value: dur(now.difference(s.startedAt).inSeconds),
            route: '/sleep',
          ),
        if (screen[c.id] case final s? when s.isRunning)
          LiveItem(
            key: 'screen.${c.id}',
            icon: Icons.phone_android_rounded,
            color: HallyModule.screenTime,
            label: l10n.liveScreen(c.firstName),
            value: s.dailyGoalMinutes == null ? dur(s.secondsAt(now)) : '${s.secondsAt(now) ~/ 60} / ${s.dailyGoalMinutes} ${durationUnits(lang).min}',
            progress: s.progressAt(now),
            route: '/screen-time',
          ),
        if (study[c.id] case final s? when s.isRunning)
          LiveItem(
            key: 'study.${c.id}',
            icon: Icons.menu_book_rounded,
            color: HallyModule.study,
            label: l10n.liveStudy(c.firstName),
            value: dur(s.runningSecondsAt(now)),
            route: '/study',
          ),
      ],
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HallySectionHeader(title: l10n.liveNow, color: HallyColors.sky),
        SizedBox(
          height: 84,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: HallySpace.sm),
            itemBuilder: (_, i) => _LiveCard(item: items[i]),
          ),
        ),
        const SizedBox(height: HallySpace.md),
      ],
    );
  }
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.item});

  final LiveItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = HallyColors.readableOn(item.color, theme.brightness);
    final over = (item.progress ?? 0) > 1;
    return HallyPressable(
      key: Key('live.${item.key}'),
      onTap: () => context.push(item.route),
      child: Container(
        width: 164,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: HallyColors.softOf(item.color, theme.brightness),
          borderRadius: BorderRadius.circular(HallyRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(item.icon, size: 15, color: ink),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ink, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.value,
              maxLines: 1,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1, color: over ? HallyColors.error : null),
            ),
            if (item.progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: item.progress!.clamp(0, 1).toDouble(),
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surface,
                    color: over ? HallyColors.error : item.color,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
