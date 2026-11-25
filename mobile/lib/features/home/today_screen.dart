import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/family_repository.dart';
import '../capture/capture_repository.dart';
import '../child_mode/parent_child_mode.dart';
import '../family/children.dart';
import '../allowance/allowance_screens.dart' show ParentAllowanceCard;
import '../asks/ask_screens.dart' show ParentAsksCard;
import '../goal/goal_widgets.dart' show FamilyGoalCard;
import '../messages/chats_screen.dart';
import '../notifications/notifications_screen.dart';
import '../planning/event_editor.dart';
import '../planning/planning_repository.dart';
import '../planning/task_sheet.dart';
import '../handoff/handoff_cards.dart';
import 'live_now.dart';
import '../profile/profile_screen.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).valueOrNull;
    final familyId = me?.primaryFamily?.id;
    if (me == null || familyId == null) return const Scaffold(body: HallyLoading());
    final today = ref.watch(todayProvider(familyId));

    return Scaffold(
      body: RefreshIndicator(
        edgeOffset: 60,
        onRefresh: () => ref.refresh(todayProvider(familyId).future),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
            SliverToBoxAdapter(child: TodayHero(name: me.displayName, data: today.valueOrNull, caregiverFor: _caregiverFor(context, ref, familyId))),
            ...today.when(
              loading: () => [const SliverFillRemaining(hasScrollBody: false, child: HallyLoading())],
              error: (_, __) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: HallyErrorState(onRetry: () => ref.invalidate(todayProvider(familyId))),
                ),
              ],
              data: (d) => [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.md, HallySpace.md, 120),
                  sliver: SliverList.list(children: _body(context, ref, d, familyId)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// For a caregiver: the names of the children they look after (shown in a banner). Null for parents.
  String? _caregiverFor(BuildContext context, WidgetRef ref, String familyId) {
    if (!ref.watch(isCaregiverProvider)) return null;
    // The server only sends a caregiver the children they look after.
    final children = ref.watch(familyProvider(familyId)).valueOrNull?.children ?? const [];
    return children.isEmpty ? AppLocalizations.of(context).caregiverAllChildren : children.map((c) => c.firstName).join(', ');
  }

  List<Widget> _body(BuildContext context, WidgetRef ref, TodayData all, String familyId) {
    final l10n = AppLocalizations.of(context);
    final child = ref.watch(childFilterProvider);
    final d = TodayData(
      overdue: filterByChild(all.overdue, (t) => t.childIds, child),
      dueToday: filterByChild(all.dueToday, (t) => t.childIds, child),
      events: filterByChild(all.events, (e) => e.childIds, child),
      waiting: all.waiting,
    );
    var i = 0;
    return [
      LiveNowStrip(familyId: familyId),
      ChildFilterBar(familyId: familyId, padding: EdgeInsets.zero),
      if (!ref.watch(isCaregiverProvider)) ParentAsksCard(familyId: familyId),
      if (!ref.watch(isCaregiverProvider)) ChildClaimsCard(familyId: familyId),
      if (!ref.watch(isCaregiverProvider)) ParentAllowanceCard(familyId: familyId),
      if (ref.watch(isCaregiverProvider)) CaregiverHandoffCard(familyId: familyId) else ParentHandoffCards(familyId: familyId),
      if (!ref.watch(isCaregiverProvider)) FamilyGoalCard(familyId: familyId),
      if (d.waiting.isNotEmpty)
        HallyEntrance(
          index: i++,
          child: _WaitingCard(
            titles: [for (final p in d.waiting) p.payload.title],
            onTap: () {
              ref.read(lastCaptureProvider.notifier).state = null;
              context.push('/capture/review');
            },
          ),
        ),
      if (d.isEmpty)
        HallyEntrance(
          index: i++,
          child: Padding(
            padding: const EdgeInsets.only(top: HallySpace.lg),
            child: HallyEmptyState(
              icon: Icons.wb_sunny_rounded,
              color: HallyColors.mint,
              title: l10n.todayEmptyTitle,
              body: l10n.todayEmptyBody,
            ),
          ),
        ),
      if (d.overdue.isNotEmpty) ...[
        HallySectionHeader(title: l10n.todayOverdue, color: HallyColors.apricot, count: d.overdue.length),
        for (final t in d.overdue) HallyEntrance(index: i++, child: TaskTile(task: t, familyId: familyId, color: HallyColors.apricot)),
      ],
      if (d.dueToday.isNotEmpty) ...[
        HallySectionHeader(title: l10n.todayDue, color: HallyModule.tasks, count: d.dueToday.length),
        for (final t in d.dueToday) HallyEntrance(index: i++, child: TaskTile(task: t, familyId: familyId, color: HallyColors.mint)),
      ],
      if (d.events.isNotEmpty) ...[
        HallySectionHeader(title: l10n.todayEvents, color: HallyModule.calendar, count: d.events.length),
        for (final (n, e) in d.events.indexed) HallyEntrance(index: i++, child: _EventTile(event: e, familyId: familyId, last: n == d.events.length - 1)),
      ],
    ];
  }
}

/// Header: wordmark and shortcuts, date, greeting, the Hally assistant card and the day's counts as pastel tiles.
class TodayHero extends StatelessWidget {
  const TodayHero({super.key, required this.name, required this.data, this.caregiverFor});

  final String name;
  final TodayData? data;

  /// Set for a caregiver: a banner names their children and the assistant card and suggestion count are hidden.
  final String? caregiverFor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final now = DateTime.now();
    final first = name.trim().split(' ').first;
    final greeting = now.hour < 12
        ? l10n.todayGreetingMorning(first)
        : now.hour < 18
            ? l10n.todayGreetingAfternoon(first)
            : l10n.todayGreetingEvening(first);
    final locale = Localizations.localeOf(context);
    final date = DateFormat('d MMMM EEEE', locale.toLanguageTag()).format(now);
    final d = data;
    final ink = theme.colorScheme.onSurface;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.md + 4, HallySpace.sm, HallySpace.md, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const HallyWordmark(height: 26),
                const Spacer(),
                IconButton(
                  key: const Key('today.tasks'),
                  tooltip: l10n.todayAllTasks,
                  onPressed: () => context.push('/tasks'),
                  icon: Icon(Icons.checklist_rounded, color: ink),
                ),
                ChatsButton(color: ink),
                NotificationBell(color: ink),
                const SizedBox(width: HallySpace.xs),
                const ProfileButton(),
              ],
            ),
            const SizedBox(height: HallySpace.md),
            Text(date, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(greeting, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.1)),
            const SizedBox(height: HallySpace.xs),
            Text(l10n.brandEmotional, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: HallySpace.md + 4),
            if (caregiverFor case final names?)
              Container(
                key: const Key('today.caregiverBanner'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.sm + 2),
                decoration: BoxDecoration(
                  color: HallyColors.softOf(HallyColors.mist, theme.brightness),
                  borderRadius: BorderRadius.circular(HallyRadius.lg),
                ),
                child: Row(
                  children: [
                    Icon(Icons.volunteer_activism_rounded, size: 20, color: HallyColors.readableOn(HallyColors.mist, theme.brightness)),
                    const SizedBox(width: HallySpace.sm),
                    Expanded(child: Text(l10n.caregiverBanner(names), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                  ],
                ),
              )
            else
              const AskHallyBar(),
            const SizedBox(height: HallySpace.md - 4),
            AnimatedOpacity(
              opacity: d == null ? 0 : 1,
              duration: HallyMotion.medium,
              child: Row(
                children: [
                  Expanded(
                    child: _Stat(
                      icon: Icons.checklist_rounded,
                      color: HallyModule.tasks,
                      count: (d?.overdue.length ?? 0) + (d?.dueToday.length ?? 0),
                      label: l10n.todayTileTasks,
                      semantics: l10n.todayStatTasks((d?.overdue.length ?? 0) + (d?.dueToday.length ?? 0)),
                    ),
                  ),
                  const SizedBox(width: HallySpace.sm + 2),
                  Expanded(
                    child: _Stat(
                      icon: Icons.calendar_month_rounded,
                      color: HallyModule.calendar,
                      count: d?.events.length ?? 0,
                      label: l10n.todayTileEvents,
                      semantics: l10n.todayStatEvents(d?.events.length ?? 0),
                    ),
                  ),
                  if (caregiverFor == null) const SizedBox(width: HallySpace.sm + 2),
                  if (caregiverFor == null)
                    Expanded(
                      child: _Stat(
                        icon: Icons.auto_awesome_rounded,
                        color: HallyColors.powder,
                        count: d?.waiting.length ?? 0,
                        label: l10n.todayTileWaiting,
                        semantics: l10n.todayStatWaiting(d?.waiting.length ?? 0),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Hally assistant card: sage, the brand's campaign line and a field that opens the assistant.
/// The assistant used to have its own tab; now it is one tap from Today.
class AskHallyBar extends StatelessWidget {
  const AskHallyBar({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final onCard = theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.fromLTRB(HallySpace.md + 2, HallySpace.md + 2, HallySpace.md, HallySpace.md),
      decoration: BoxDecoration(
        gradient: dark ? HallyGradients.magicDark : HallyGradients.magic,
        borderRadius: BorderRadius.circular(HallyRadius.lg + 4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.brandCampaign, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: onCard)),
                    const SizedBox(height: 2),
                    Text(l10n.brandSlogan, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: onCard)),
                    const SizedBox(height: HallySpace.xs),
                    Text(l10n.askHallyCardBody, style: theme.textTheme.bodyMedium?.copyWith(color: HallyColors.readableOn(HallyModule.assistant, b))),
                  ],
                ),
              ),
              const SizedBox(width: HallySpace.sm),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: dark ? 0.5 : 0.7), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: HallyMark(size: 50, colors: dark ? HallyMarkColors.onDark : HallyMarkColors.onLight),
              ),
            ],
          ),
          const SizedBox(height: HallySpace.md - 2),
          Container(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, 8, 8, 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(HallyRadius.md),
              boxShadow: HallyShadows.soft(b),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    label: l10n.askHally,
                    excludeSemantics: true,
                    child: HallyPressable(
                      key: const Key('today.askHally'),
                      onTap: () => context.push('/assistant'),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome_rounded, color: HallyColors.readableOn(HallyModule.assistant, b), size: 20),
                          const SizedBox(width: HallySpace.sm + 2),
                          Expanded(child: Text(l10n.askHally, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                        ],
                      ),
                    ),
                  ),
                ),
                // Speak instead of type: opens the assistant already listening.
                Semantics(
                  button: true,
                  label: l10n.voiceSpeak,
                  excludeSemantics: true,
                  child: HallyPressable(
                    key: const Key('today.askHallyVoice'),
                    onTap: () => context.push('/assistant?voice=1'),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.mic_rounded, color: theme.colorScheme.onPrimary, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One pastel count tile (tasks, events, suggestions).
class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.color, required this.count, required this.label, required this.semantics});

  final IconData icon;
  final Color color;
  final int count;
  final String label;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final fg = HallyColors.readableOn(color, b);
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 12),
        decoration: BoxDecoration(color: HallyColors.softOf(color, b), borderRadius: BorderRadius.circular(HallyRadius.md + 2)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: fg),
            const SizedBox(height: HallySpace.sm),
            Text('$count', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, height: 1, color: theme.colorScheme.onSurface)),
            const SizedBox(height: HallySpace.xs),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Hally's suggestions waiting for approval: a calm sage card (the assistant's colour) with one cherry action.
class _WaitingCard extends StatelessWidget {
  const _WaitingCard({required this.titles, required this.onTap});

  final List<String> titles;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final accent = HallyColors.readableOn(HallyModule.assistant, b);
    return Padding(
      padding: const EdgeInsets.only(top: HallySpace.md),
      child: HallyPressable(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(HallyRadius.lg),
            border: Border.all(color: HallyColors.softOf(HallyModule.assistant, b), width: 1.5),
            boxShadow: HallyShadows.soft(b),
          ),
          padding: const EdgeInsets.all(HallySpace.md + 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const HallyIconBadge(icon: Icons.auto_awesome_rounded, color: HallyModule.assistant, size: 40),
                  const SizedBox(width: HallySpace.sm + 4),
                  Expanded(child: Text(l10n.todayWaiting, style: theme.textTheme.titleLarge)),
                  HallyPill(label: '${titles.length}', color: HallyModule.assistant),
                ],
              ),
              const SizedBox(height: HallySpace.sm),
              Text(l10n.todayWaitingBody(titles.length), style: theme.textTheme.bodyMedium),
              const SizedBox(height: HallySpace.sm + 4),
              for (final t in titles.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 6, color: accent),
                      const SizedBox(width: HallySpace.sm),
                      Expanded(
                        child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: HallySpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(HallyRadius.pill)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.todayReview, style: TextStyle(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    Icon(Icons.arrow_forward_rounded, size: 18, color: theme.colorScheme.onPrimary),
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

/// A task row: tap the circle or swipe right to complete (the check animates before the row disappears); tap the row to open it.
class TaskTile extends ConsumerStatefulWidget {
  const TaskTile({super.key, required this.task, required this.familyId, required this.color});

  final TaskItem task;
  final String familyId;
  final Color color;

  @override
  ConsumerState<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends ConsumerState<TaskTile> {
  bool _checked = false;

  Future<void> _complete() async {
    if (_checked) return;
    HapticFeedback.lightImpact();
    setState(() => _checked = true);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // The tile is gone once Today refreshes, so the undo action must not depend on this widget's ref.
    final container = ProviderScope.containerOf(context);
    final repo = ref.read(planningRepositoryProvider);
    final familyId = widget.familyId;
    final taskId = widget.task.id;
    try {
      await repo.completeTask(familyId, taskId);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('🎉  ${l10n.taskDoneToast}'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          key: const Key('task.undo'),
          label: l10n.taskReopen,
          onPressed: () async {
            try {
              await repo.reopenTask(familyId, taskId);
            } catch (_) {
              messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
            }
            container.invalidate(todayProvider(familyId));
          },
        ),
      ));
      await Future<void>.delayed(HallyMotion.medium);
      ref.invalidate(todayProvider(familyId));
    } catch (_) {
      if (mounted) setState(() => _checked = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final t = widget.task;
    final done = _checked || t.state == 'Done';
    final time = t.dueAt != null && !t.allDay ? TimeOfDay.fromDateTime(t.dueAt!).format(context) : null;

    return Dismissible(
      key: ValueKey('task.${t.id}'),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        await _complete();
        return false;
      },
      background: Container(
        margin: const EdgeInsets.only(bottom: HallySpace.sm + 2),
        padding: const EdgeInsets.symmetric(horizontal: HallySpace.lg),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(gradient: HallyGradients.mintDeep, borderRadius: BorderRadius.circular(HallyRadius.lg)),
        child: Row(
          children: [
            const Icon(Icons.check_rounded, color: Colors.white),
            const SizedBox(width: HallySpace.sm),
            Text(l10n.taskSwipeDone, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      child: AnimatedOpacity(
        opacity: done ? 0.55 : 1,
        duration: HallyMotion.medium,
        child: Card(
          child: InkWell(
            key: ValueKey('task.${t.id}.row'),
            // Tapping the row opens the task; only the circle (or a swipe) completes it, so a stray tap can't tick it off.
            onTap: ref.watch(isCaregiverProvider) ? null : () => showTaskSheet(context, ref, familyId: widget.familyId, task: t),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(HallySpace.md - 10, HallySpace.md - 12, HallySpace.md, HallySpace.md - 12),
              child: Row(
                children: [
                  IconButton(
                    key: ValueKey('task.${t.id}.check'),
                    tooltip: l10n.taskComplete,
                    onPressed: done ? null : _complete,
                    icon: AnimatedContainer(
                      duration: HallyMotion.medium,
                      curve: Curves.easeOutBack,
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: done ? HallyColors.accent(widget.color, theme.brightness) : Colors.transparent,
                        border: Border.all(color: HallyColors.accent(widget.color, theme.brightness), width: 2.2),
                      ),
                      child: AnimatedScale(
                        scale: done ? 1 : 0,
                        duration: HallyMotion.medium,
                        curve: Curves.easeOutBack,
                        child: Icon(Icons.check_rounded, size: 18, color: theme.colorScheme.surface),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: HallyMotion.medium,
                          style: theme.textTheme.titleMedium!.copyWith(
                            decoration: done ? TextDecoration.lineThrough : null,
                            decorationColor: theme.colorScheme.onSurfaceVariant,
                          ),
                          child: Text(t.title),
                        ),
                        if (time != null) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.schedule_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Text(time, style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (t.childIds.isNotEmpty) ...[
                    ChildBadges(familyId: widget.familyId, childIds: t.childIds),
                    const SizedBox(width: HallySpace.sm),
                  ],
                  Container(
                      width: 4,
                      height: 28,
                      decoration: BoxDecoration(color: HallyColors.softOf(widget.color, theme.brightness), borderRadius: BorderRadius.circular(2))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Timeline-style event row: time on the left, a coloured rail, then the title.
class _EventTile extends ConsumerWidget {
  const _EventTile({required this.event, required this.familyId, required this.last});

  final EventItem event;
  final String familyId;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final time = event.allDay ? l10n.reviewAllDay : TimeOfDay.fromDateTime(event.startsAt).format(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 58,
            child: Padding(
              padding: const EdgeInsets.only(top: HallySpace.md),
              child:
                  Text(time, style: theme.textTheme.labelLarge?.copyWith(fontSize: 13, color: HallyColors.readableOn(HallyModule.calendar, theme.brightness))),
            ),
          ),
          Column(
            children: [
              const SizedBox(height: HallySpace.md + 2),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: HallyColors.accent(HallyModule.calendar, theme.brightness),
                  border: Border.all(color: HallyColors.softOf(HallyModule.calendar, theme.brightness), width: 3),
                ),
              ),
              Expanded(
                child: Container(width: 2, color: last ? Colors.transparent : HallyColors.softOf(HallyModule.calendar, theme.brightness)),
              ),
            ],
          ),
          const SizedBox(width: HallySpace.sm + 4),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: Key('today.event.${event.id}'),
                onTap: ref.watch(isCaregiverProvider) ? null : () => showEventEditor(context, ref, familyId: familyId, event: event),
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Row(
                    children: [
                      Expanded(child: Text(event.title, style: theme.textTheme.titleMedium)),
                      if (event.childIds.isNotEmpty) ...[
                        ChildBadges(familyId: familyId, childIds: event.childIds),
                        const SizedBox(width: HallySpace.sm),
                      ],
                      const HallyIconBadge(icon: Icons.event_rounded, color: HallyModule.calendar, size: 34),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
