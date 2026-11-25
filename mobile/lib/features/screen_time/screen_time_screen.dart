import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'screen_time_repository.dart';

bool _turkish(BuildContext context) => Localizations.localeOf(context).languageCode != 'en';

/// Rebuilds every second while [running] so a running timer counts up on screen.
class _Ticker extends StatefulWidget {
  const _Ticker({required this.running, required this.builder});

  final bool running;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Ticker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.running && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!widget.running) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
}

/// The Family screen's screen time section: one row per child with today's time, the goal bar and Start/Stop.
/// Tapping a row opens the screen time page with the weekly summary.
class ScreenTimeCard extends ConsumerWidget {
  const ScreenTimeCard({super.key, required this.familyId, required this.children});

  final String familyId;
  final List<ChildProfile> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (children.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(screenTimeProvider(familyId)).valueOrNull ?? const {};
    return Card(
      key: const Key('screenTime.card'),
      child: Column(
        children: [
          ListTile(
            leading: const HallyIconBadge(icon: Icons.timer_rounded, color: HallyColors.sky),
            title: Text(l10n.screenTimeTitle),
            subtitle: Text(l10n.screenTimeBody),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/screen-time'),
          ),
          for (final c in children) ScreenTimeRow(familyId: familyId, child: c, status: status[c.id]),
          const SizedBox(height: HallySpace.sm),
        ],
      ),
    );
  }
}

/// A child's timer: name, today's time (counting while it runs), goal bar and a Start/Stop button.
class ScreenTimeRow extends ConsumerStatefulWidget {
  const ScreenTimeRow({super.key, required this.familyId, required this.child, required this.status});

  final String familyId;
  final ChildProfile child;
  final ChildScreenTime? status;

  @override
  ConsumerState<ScreenTimeRow> createState() => _ScreenTimeRowState();
}

class _ScreenTimeRowState extends ConsumerState<ScreenTimeRow> {
  bool _busy = false;

  Future<void> _toggle() async {
    final running = widget.status?.isRunning ?? false;
    final controller = ref.read(screenTimeProvider(widget.familyId).notifier);
    setState(() => _busy = true);
    try {
      running ? await controller.stop(widget.child.id) : await controller.start(widget.child.id);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = widget.status;
    final running = status?.isRunning ?? false;
    final color = childColor(widget.child.color);
    final me = ref.watch(meProvider).valueOrNull?.id;
    return _Ticker(
      running: running,
      builder: (context, now) {
        final seconds = status?.secondsAt(now) ?? 0;
        final progress = status?.progressAt(now);
        final over = progress != null && progress >= 1;
        final tr = _turkish(context);
        final time = formatScreenDuration(seconds, turkish: tr, withSeconds: running);
        final goal = status?.dailyGoalMinutes;
        final line = goal == null ? l10n.screenTimeToday(time) : l10n.screenTimeOfGoal(time, formatScreenDuration(goal * 60, turkish: tr));
        final by = running && status?.startedByName != null && status?.startedByUserId != me ? l10n.screenTimeStartedBy(status!.startedByName!) : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.md, HallySpace.xs),
          child: Row(
            children: [
              ChildBadge(child: widget.child, size: 36),
              const SizedBox(width: HallySpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.child.firstName, style: theme.textTheme.titleSmall),
                    Text(line, key: Key('screenTime.time.${widget.child.id}'), style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    if (progress != null) ...[
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0, 1).toDouble(),
                          minHeight: 6,
                          backgroundColor: HallyColors.softOf(color, theme.brightness),
                          // Over the goal turns orange (attention), never red.
                          color: over ? HallyColors.apricot : color,
                        ),
                      ),
                    ],
                    if (over) Text(l10n.screenTimeOverGoal, style: theme.textTheme.labelSmall?.copyWith(color: HallyColors.apricot, fontWeight: FontWeight.w700)),
                    if (by != null) Text(by, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              const SizedBox(width: HallySpace.sm),
              running
                  ? FilledButton.icon(
                      key: Key('screenTime.stop.${widget.child.id}'),
                      onPressed: _busy || status == null ? null : _toggle,
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: HallySpace.md)),
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(l10n.screenTimeStop),
                    )
                  : OutlinedButton.icon(
                      key: Key('screenTime.start.${widget.child.id}'),
                      onPressed: _busy || status == null ? null : _toggle,
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: HallySpace.md)),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(l10n.screenTimeStart),
                    ),
            ],
          ),
        );
      },
    );
  }
}

/// Full page: today's timers, this week's bars per child, the daily goal and "add time".
class ScreenTimeScreen extends ConsumerWidget {
  const ScreenTimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final today = ref.watch(screenTimeProvider(familyId));
    final week = ref.watch(screenTimeWeekProvider(familyId));
    // A start/stop changes this week's numbers too.
    ref.listen(screenTimeProvider(familyId), (_, __) => ref.invalidate(screenTimeWeekProvider(familyId)));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.screenTimeTitle)),
      body: children.isEmpty
          ? HallyEmptyState(icon: Icons.timer_outlined, title: l10n.screenTimeTitle, body: l10n.screenTimeNoChildren)
          : today.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(screenTimeProvider(familyId))),
              data: (status) => RefreshIndicator(
                onRefresh: () async {
                  await ref.read(screenTimeProvider(familyId).notifier).refresh();
                  ref.invalidate(screenTimeWeekProvider(familyId));
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, HallySpace.xxl),
                  children: [
                    Text(l10n.screenTimeBody, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: HallySpace.sm),
                    for (final c in children)
                      Card(
                        child: Column(
                          children: [
                            ScreenTimeRow(familyId: familyId, child: c, status: status[c.id]),
                            _ChildActions(familyId: familyId, child: c, status: status[c.id]),
                            if (week.valueOrNull?.children.where((w) => w.childId == c.id).firstOrNull case final w?)
                              _WeekBars(week: w, start: week.value!.start, color: childColor(c.color)),
                            const SizedBox(height: HallySpace.sm),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ChildActions extends ConsumerWidget {
  const _ChildActions({required this.familyId, required this.child, required this.status});

  final String familyId;
  final ChildProfile child;
  final ChildScreenTime? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final goal = status?.dailyGoalMinutes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm),
      child: Wrap(
        spacing: HallySpace.xs,
        children: [
          if (!ref.watch(isCaregiverProvider))
          TextButton.icon(
            key: Key('screenTime.goal.${child.id}'),
            onPressed: () => _showGoalSheet(context, ref, familyId, child, goal),
            icon: const Icon(Icons.flag_outlined),
            label: Text(goal == null ? l10n.screenTimeSetGoal : '${l10n.screenTimeGoal}: ${formatScreenDuration(goal * 60, turkish: _turkish(context))}'),
          ),
          TextButton.icon(
            key: Key('screenTime.add.${child.id}'),
            onPressed: () => _showAddSheet(context, ref, familyId, child),
            icon: const Icon(Icons.more_time_rounded),
            label: Text(l10n.screenTimeAddMinutes),
          ),
        ],
      ),
    );
  }
}

const _goalChoices = [30, 60, 90, 120, 180];
const _addChoices = [15, 30, 45, 60, 90, 120];

Future<void> _showGoalSheet(BuildContext context, WidgetRef ref, String familyId, ChildProfile child, int? current) async {
  final l10n = AppLocalizations.of(context);
  final tr = _turkish(context);
  final picked = await showModalBottomSheet<int>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${child.firstName} · ${l10n.screenTimeGoal}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: HallySpace.md),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.sm,
              children: [
                ChoiceChip(key: const Key('screenTime.goal.none'), label: Text(l10n.screenTimeNoGoal), selected: current == null, onSelected: (_) => Navigator.pop(context, 0)),
                for (final m in _goalChoices)
                  ChoiceChip(
                    key: Key('screenTime.goal.$m'),
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
  if (picked == null) return;
  try {
    await ref.read(screenTimeProvider(familyId).notifier).setGoal(child.id, picked == 0 ? null : picked);
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
  }
}

Future<void> _showAddSheet(BuildContext context, WidgetRef ref, String familyId, ChildProfile child) async {
  final l10n = AppLocalizations.of(context);
  final tr = _turkish(context);
  final picked = await showModalBottomSheet<int>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${child.firstName} · ${l10n.screenTimeAddMinutes}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: HallySpace.xs),
            Text(l10n.screenTimeAddMinutesBody, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: HallySpace.md),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.sm,
              children: [
                for (final m in _addChoices)
                  ActionChip(key: Key('screenTime.add.$m'), label: Text('+${formatScreenDuration(m * 60, turkish: tr)}'), onPressed: () => Navigator.pop(context, m)),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null) return;
  try {
    await ref.read(screenTimeProvider(familyId).notifier).addMinutes(child.id, picked);
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
  }
}

/// Seven bars, Monday first, with the goal as a dashed-looking line. Days over the goal are orange.
class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.week, required this.start, required this.color});

  final ChildScreenWeek week;
  final DateTime start;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tr = _turkish(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final goalSeconds = week.dailyGoalMinutes == null ? null : week.dailyGoalMinutes! * 60;
    final maxValue = [...week.dailySeconds, goalSeconds ?? 0, 60 * 30].reduce((a, b) => a > b ? a : b).toDouble();
    const height = 80.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.screenTimeWeek, style: theme.textTheme.labelLarge),
          Text(
            l10n.screenTimeWeekSummary(formatScreenDuration(week.totalSeconds, turkish: tr), formatScreenDuration(week.averageSeconds, turkish: tr)),
            key: Key('screenTime.week.${week.childId}'),
            style: theme.textTheme.bodySmall,
          ),
          if (goalSeconds != null && week.daysOverGoal > 0)
            Text(l10n.screenTimeDaysOver(week.daysOverGoal), style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.apricot, fontWeight: FontWeight.w600)),
          const SizedBox(height: HallySpace.sm),
          SizedBox(
            height: height,
            child: Stack(
              children: [
                if (goalSeconds != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: height - height * goalSeconds / maxValue,
                    child: Container(height: 1.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final s in week.dailySeconds)
                      Expanded(
                        child: Tooltip(
                          message: formatScreenDuration(s, turkish: tr),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            height: s == 0 ? 2 : (height * s / maxValue).clamp(4, height).toDouble(),
                            decoration: BoxDecoration(
                              color: goalSeconds != null && s > goalSeconds ? HallyColors.apricot : color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Text(DateFormat.E(locale).format(start.add(Duration(days: i))), textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
