import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'child_lock.dart';
import '../activities/activity_screens.dart' show KidIdeasCard;
import '../allowance/allowance_screens.dart' show KidSavingsSection;
import '../asks/ask_screens.dart' show KidAskCard;
import '../bedtime/bedtime.dart' show bedtimeLaterProvider;
import '../bedtime/bedtime_screens.dart' show KidBedtimeCard, KidBedtimeScreen, KidNightView;
import '../exams/exams.dart' show ChildExam;
import '../goal/goal_widgets.dart' show GoalBody, GoalMiniCard;
import '../mood/mood.dart' show moodSkippedProvider;
import '../mood/mood_widgets.dart' show KidMoodCard;
import '../school/school_screens.dart' show KidSchoolCards;
import 'child_mode_repository.dart';
import 'parent_exit.dart';

/// "Bu telefon bir çocuğun": the child types the six-digit code from a parent's phone.
class KidPairScreen extends ConsumerStatefulWidget {
  const KidPairScreen({super.key});

  @override
  ConsumerState<KidPairScreen> createState() => _KidPairScreenState();
}

class _KidPairScreenState extends ConsumerState<KidPairScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final l10n = AppLocalizations.of(context);
    final code = _code.text.trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      setState(() => _error = l10n.kidPairInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(childApiProvider).pair(code);
      ref.invalidate(childSessionProvider);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.code == 'pairing.code_invalid' || e.status == 422 || e.status == 400 ? l10n.kidPairInvalid : l10n.errorGeneric;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(HallySpace.lg),
          children: [
            const Center(child: CherryIcon(size: 72)),
            const SizedBox(height: HallySpace.md),
            Text(l10n.kidPairTitle, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
            const SizedBox(height: HallySpace.sm),
            Text(l10n.kidPairBody, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            const SizedBox(height: HallySpace.lg),
            TextField(
              key: const Key('kid.code'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 12, fontWeight: FontWeight.w800),
              decoration: InputDecoration(hintText: '••••••', labelText: l10n.kidPairCode, errorText: _error),
              onSubmitted: (_) => _pair(),
            ),
            const SizedBox(height: HallySpace.md),
            FilledButton(key: const Key('kid.pair'), onPressed: _busy ? null : _pair, child: Text(l10n.kidPairButton)),
          ],
        ),
      ),
    );
  }
}

/// The child's phone: Bugünüm, Kavanoz, Ödüller. When today's screen time is used up the lock page covers it.
class KidShell extends ConsumerStatefulWidget {
  const KidShell({super.key});

  @override
  ConsumerState<KidShell> createState() => _KidShellState();
}

class _KidShellState extends ConsumerState<KidShell> with WidgetsBindingObserver {
  int _tab = 0;

  /// The good-night page after the routine was closed (only when the phone does not lock for the night).
  bool _nightClosed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Approvals and extra minutes arrive while the app is in the background.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(childHomeProvider);
      // Bedtime steps open again each time the app comes back while they wait.
      ref.read(bedtimeLaterProvider.notifier).state = false;
      // Coming back from the Android settings pages after granting a permission.
      ref.invalidate(childLockStatusProvider);
    }
  }

  /// Starts the Android lock as soon as both permissions are there (and again after an update or a crash).
  Future<void> _startLock(ChildLockStatus? status) async {
    if (status == null || !status.ready || status.running) return;
    final session = await ref.read(childSessionProvider.future);
    if (session == null) return;
    await ref.read(childLockProvider).start(session.token);
    ref.invalidate(childLockStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final home = ref.watch(childHomeProvider);
    ref.listen(childLockStatusProvider, (_, next) => _startLock(next.valueOrNull));
    return home.when(
      loading: () => const Scaffold(body: HallyLoading()),
      error: (e, _) => Scaffold(body: HallyErrorState(onRetry: () => ref.invalidate(childHomeProvider))),
      data: (h) {
        if (h.screen.locked && h.screen.bedtime) return KidNightView(home: h);
        if (h.screen.locked) return KidLockView(home: h);
        final bed = h.bedtime;
        if (bed != null && bed.due && !ref.watch(bedtimeLaterProvider)) return KidBedtimeScreen(key: ValueKey(bed.done), bedtime: bed);
        if (bed != null && bed.finished && !_nightClosed && DateTime.now().difference(bed.finishedAt!).inHours < 2) {
          return KidNightView(home: h, onClose: () => setState(() => _nightClosed = true));
        }
        final pages = [_KidToday(home: h), _KidJar(home: h), _KidRewards(home: h)];
        return Scaffold(
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(childHomeProvider.future),
              child: pages[_tab],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                  key: const Key('kid.tab.today'),
                  icon: const Icon(Icons.wb_sunny_outlined),
                  selectedIcon: const Icon(Icons.wb_sunny_rounded),
                  label: l10n.kidTabToday),
              NavigationDestination(key: const Key('kid.tab.jar'), icon: const CherryIcon(size: 24), label: l10n.kidTabJar),
              NavigationDestination(
                  key: const Key('kid.tab.rewards'),
                  icon: const Icon(Icons.card_giftcard_outlined),
                  selectedIcon: const Icon(Icons.card_giftcard_rounded),
                  label: l10n.kidTabRewards),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _act(BuildContext context, WidgetRef ref, Future<ChildHome> Function(ChildApi api) action, String Function(ChildHome) message) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final home = await action(ref.read(childApiProvider));
    HapticFeedback.mediumImpact();
    messenger.showSnackBar(SnackBar(content: Text(message(home))));
    ref.invalidate(childHomeProvider);
  } on UnpairedException {
    ref.invalidate(childSessionProvider);
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.code == 'points.not_enough' ? l10n.pointsNotEnough : l10n.errorGeneric)));
  }
}

class _KidToday extends ConsumerWidget {
  const _KidToday({required this.home});

  final ChildHome home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final next = home.nextReward;
    final todo = home.today.where((i) => !i.isDone).length;
    return ListView(
      padding: const EdgeInsets.all(HallySpace.md),
      children: [
        Text(DateFormat('EEEE', locale).format(DateTime.now()), style: theme.textTheme.bodySmall),
        // Holding the greeting is the hidden parent exit (no button a child could find).
        ParentExitGesture(
          child: Text(l10n.kidHello(home.firstName), key: const Key('kid.hello'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: HallySpace.md),
        if (home.bedtime case final bed? when bed.due) KidBedtimeCard(bedtime: bed),
        if (home.todayMood == null && !ref.watch(moodSkippedProvider)) const KidMoodCard(),
        const KidAskCard(),
        if (home.school case final school?) KidSchoolCards(school: school),
        for (final exam in home.exams.take(2)) _KidExamCard(exam: exam),
        const _LockSetupCard(),
        Row(
          children: [
            Expanded(
              child: _Panel(
                color: HallyColors.softOf(HallyColors.cherry, b),
                child: Column(
                  children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const CherryIcon(size: 28),
                      const SizedBox(width: 4),
                      Text('${home.balance}',
                          key: const Key('kid.balance'),
                          style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b))),
                    ]),
                    Text(l10n.kidCherries, style: theme.textTheme.bodySmall),
                    if (home.streakDays > 0) Text('🔥 ${l10n.kidStreak(home.streakDays)}', style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ),
            const SizedBox(width: HallySpace.sm),
            Expanded(child: _ScreenPanel(screen: home.screen)),
          ],
        ),
        HallySectionHeader(title: l10n.kidMyTasks, count: todo),
        if (home.today.isEmpty)
          Padding(padding: const EdgeInsets.all(HallySpace.lg), child: Text(l10n.kidNoTasks, textAlign: TextAlign.center))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final item in home.today)
                  ListTile(
                    key: Key('kid.item.${item.id}'),
                    minVerticalPadding: 14,
                    leading: _DoneCircle(item: item),
                    title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: item.isPending
                        ? Align(alignment: Alignment.centerLeft, child: HallyPill(label: l10n.kidWaiting, color: HallyColors.butter))
                        : item.isHabit
                            ? Text(l10n.kidHabit)
                            : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('+${item.cherries}', style: theme.textTheme.titleSmall),
                      const SizedBox(width: 2),
                      const CherryIcon(size: 18),
                    ]),
                    onTap: item.isDone || item.isPending
                        ? null
                        : () =>
                            _act(context, ref, (api) => api.markDone(item), (h) => h.requireApproval ? l10n.kidDoneSent : l10n.kidDoneCherry(item.cherries)),
                  ),
              ],
            ),
          ),
        if (next != null) ...[
          const SizedBox(height: HallySpace.md),
          _Panel(
            color: HallyColors.softOf(HallyColors.lavender, b),
            child: Row(children: [
              const Text('🎁', style: TextStyle(fontSize: 20)),
              const SizedBox(width: HallySpace.sm),
              Expanded(child: Text(l10n.kidNextReward(next.title), style: const TextStyle(fontWeight: FontWeight.w700))),
              Text('${home.balance}/${next.cost}', style: TextStyle(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.lavender, b))),
            ]),
          ),
        ],
      ],
    );
  }
}

/// "Cuma Matematik sınavın var": the countdown, topics, minutes studied for it and "Çalıştım" (one cherry with the parents' OK).
class _KidExamCard extends ConsumerWidget {
  const _KidExamCard({required this.exam});

  final ChildExam exam;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final title = switch (exam.daysLeft) {
      0 => l10n.kidExamToday(exam.subject),
      1 => l10n.kidExamTomorrow(exam.subject),
      _ => l10n.kidExamOn(DateFormat(exam.daysLeft < 7 ? 'EEEE' : 'd MMMM', locale).format(exam.date), exam.subject),
    };
    final minutes = exam.studySeconds ~/ 60;
    return Padding(
      padding: const EdgeInsets.only(bottom: HallySpace.md),
      child: Container(
        key: Key('kid.exam.${exam.id}'),
        padding: const EdgeInsets.all(HallySpace.md),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [HallyColors.softOf(HallyColors.mist, b), HallyColors.softOf(HallyColors.lavender, b)],
          ),
          borderRadius: BorderRadius.circular(HallyRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Text('📝', style: TextStyle(fontSize: 36)),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  if (exam.topics != null) Text(exam.topics!, style: theme.textTheme.bodyMedium),
                ]),
              ),
            ]),
            if (exam.daysLeft > 0) ...[
              const SizedBox(height: HallySpace.sm),
              Container(
                padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.xs, HallySpace.xs),
                decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(HallyRadius.md)),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      exam.state == 'Done'
                          ? l10n.kidExamStudyDone
                          : minutes > 0
                              ? l10n.kidExamStudied(minutes)
                              : l10n.kidExamStudyPrompt,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (exam.state == 'Pending')
                    HallyPill(label: l10n.kidWaiting, color: HallyColors.butter)
                  else if (exam.state == 'Todo')
                    FilledButton(
                      key: Key('kid.exam.${exam.id}.studied'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                      onPressed: () =>
                          _act(context, ref, (api) => api.examStudied(exam.id), (h) => h.requireApproval ? l10n.kidDoneSent : l10n.kidDoneCherry(1)),
                      child: Text(l10n.kidExamStudyButton),
                    ),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DoneCircle extends StatelessWidget {
  const _DoneCircle({required this.item});

  final ChildItem item;

  @override
  Widget build(BuildContext context) {
    final color = HallyColors.accent(HallyColors.cherry, Theme.of(context).brightness);
    final filled = item.isDone || item.isPending;
    return AnimatedContainer(
      duration: HallyMotion.medium,
      width: 36,
      height: 36,
      decoration: BoxDecoration(shape: BoxShape.circle, color: filled ? color : null, border: Border.all(color: color, width: 2.5)),
      child: filled ? const Icon(Icons.check_rounded, color: Colors.white, size: 22) : null,
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(HallySpace.md),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(HallyRadius.md)),
        child: child,
      );
}

class _ScreenPanel extends StatelessWidget {
  const _ScreenPanel({required this.screen});

  final ChildScreen screen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final left = screen.minutesLeft;
    final limit = screen.limitMinutes;
    final color = HallyColors.accent(HallyColors.mist, b);
    return _Panel(
      color: HallyColors.softOf(HallyColors.mist, b),
      child: Column(
        children: [
          SizedBox.square(
            dimension: 64,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: limit == null || limit == 0 ? 0 : (left! / limit).clamp(0.0, 1.0),
                strokeWidth: 6,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(left == null ? '∞' : '$left', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                if (left != null) Text(l10n.kidScreenLeft, style: theme.textTheme.labelSmall?.copyWith(fontSize: 9)),
              ]),
            ]),
          ),
          const SizedBox(height: 4),
          Text(l10n.kidScreenTitle, style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _KidJar extends StatelessWidget {
  const _KidJar({required this.home});

  final ChildHome home;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final inCycle = home.streakDays > 0 && home.streakDays % 7 == 0 ? 7 : home.streakDays % 7;
    return ListView(
      padding: const EdgeInsets.all(HallySpace.md),
      children: [
        Text(l10n.kidJarTitle, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: HallySpace.md),
        Center(child: CherryJar(count: home.balance)),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('${home.balance}',
                key: const Key('kid.jar.count'),
                style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b))),
            const SizedBox(width: 6),
            Text(l10n.kidCherryUnit),
          ],
        ),
        const SizedBox(height: HallySpace.md),
        const KidSavingsSection(),
        const _KidGoal(),
        _Panel(
          color: HallyColors.softOf(HallyColors.butter, b),
          child: Column(children: [
            Text('✨ ${l10n.kidGoldenIn(home.nextBonusIn)}', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: HallySpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 7; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: CircleAvatar(
                      radius: 15,
                      backgroundColor: i < inCycle ? HallyColors.accent(HallyColors.cherry, b) : HallyColors.softOf(HallyColors.cherry, b),
                      child: Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: i < inCycle ? Colors.white : null)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: HallySpace.sm),
            Text(l10n.kidGoldenBody, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          ]),
        ),
        const SizedBox(height: HallySpace.md),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            title: Text(l10n.kidThisWeek, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(l10n.kidWeekCherries(home.weekCherries)),
            leading: const CherryIcon(size: 28),
          ),
        ),
      ],
    );
  }
}

/// The family goal in the jar tab; nothing when none runs (or it fails to load).
class _KidGoal extends ConsumerWidget {
  const _KidGoal();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(kidGoalProvider).valueOrNull?.goal;
    if (goal == null) return const SizedBox.shrink();
    return GoalMiniCard(
      goal: goal,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(AppLocalizations.of(context).goalTitle),
            actions: [
              Center(child: Text(AppLocalizations.of(context).goalDaysLeft(goal.daysLeft))),
              const SizedBox(width: HallySpace.md),
            ],
          ),
          body: GoalBody(goal: goal),
        ),
      )),
    );
  }
}

/// A glass jar that fills with cherries; new ones drop in with a little bounce.
class CherryJar extends StatelessWidget {
  const CherryJar({super.key, required this.count, this.width = 170});

  final int count;
  final double width;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final shown = math.min(count, 40);
    final height = width * 1.15;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned(
            top: 0,
            child: Container(
              width: width * 0.62,
              height: 16,
              decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.cherry, b), borderRadius: BorderRadius.circular(6)),
            ),
          ),
          Positioned(
            top: 12,
            child: Container(
              width: width,
              height: height - 12,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
                border: Border.all(color: HallyColors.line, width: 3),
                borderRadius: BorderRadius.circular(28),
              ),
              padding: const EdgeInsets.all(12),
              alignment: Alignment.bottomCenter,
              child: Wrap(
                alignment: WrapAlignment.center,
                verticalDirection: VerticalDirection.up,
                spacing: 0,
                runSpacing: -6,
                children: [
                  for (var i = 0; i < shown; i++)
                    TweenAnimationBuilder<double>(
                      key: ValueKey(i),
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(milliseconds: 300 + math.min(i, 20) * 25),
                      curve: Curves.bounceOut,
                      builder: (_, t, child) => Transform.translate(offset: Offset(0, (1 - t) * -60), child: Opacity(opacity: t.clamp(0, 1), child: child)),
                      child: const CherryIcon(size: 26),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KidRewards extends ConsumerWidget {
  const _KidRewards({required this.home});

  final ChildHome home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    return ListView(
      padding: const EdgeInsets.all(HallySpace.md),
      children: [
        Row(children: [
          Expanded(child: Text(l10n.kidRewardsTitle, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
          const CherryIcon(size: 22),
          Text(' ${home.balance}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b))),
        ]),
        const SizedBox(height: HallySpace.md),
        if (home.rewards.isEmpty)
          Padding(padding: const EdgeInsets.all(HallySpace.lg), child: Text(l10n.kidNoRewards, textAlign: TextAlign.center))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final r in home.rewards)
                  ListTile(
                    key: Key('kid.reward.${r.id}'),
                    minVerticalPadding: 12,
                    leading: HallyIconBadge(
                      icon: r.screenMinutes != null ? Icons.smartphone_rounded : Icons.card_giftcard_rounded,
                      color: r.screenMinutes != null ? HallyColors.mist : HallyColors.lavender,
                    ),
                    title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: r.cost > home.balance
                        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(l10n.kidMore(r.cost - home.balance)),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(value: home.balance / r.cost, borderRadius: BorderRadius.circular(4)),
                          ])
                        : r.screenMinutes != null
                            ? Text(l10n.kidScreenReward)
                            : null,
                    trailing: FilledButton(
                      key: Key('kid.buy.${r.id}'),
                      style: FilledButton.styleFrom(minimumSize: const Size(72, 40), padding: const EdgeInsets.symmetric(horizontal: 12)),
                      onPressed: r.cost > home.balance
                          ? null
                          : () => _act(context, ref, (api) => api.redeem(r.id),
                              (_) => r.screenMinutes != null ? l10n.kidBoughtScreen(r.screenMinutes!) : l10n.kidBought),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [Text('${r.cost} '), const CherryIcon(size: 16)]),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Today's screen time is used up. The Android lock (next step) shows the same page over every app; calls and the
/// family stay reachable.
class KidLockView extends ConsumerStatefulWidget {
  const KidLockView({super.key, required this.home});

  final ChildHome home;

  @override
  ConsumerState<KidLockView> createState() => _KidLockViewState();
}

class _KidLockViewState extends ConsumerState<KidLockView> {
  bool _asked = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final h = widget.home;
    final buy = h.affordableScreenReward;
    final used = h.screen.usedSeconds ~/ 60;
    return Scaffold(
      key: const Key('kid.lock'),
      backgroundColor: HallyColors.softOf(HallyColors.cherry, b),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.all(HallySpace.lg),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - HallySpace.lg * 2),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(),
                    Center(
                      child: ParentExitGesture(
                        child: CircleAvatar(radius: 48, backgroundColor: theme.colorScheme.surface, child: const CherryIcon(size: 56)),
                      ),
                    ),
                    const SizedBox(height: HallySpace.md),
                    Text(l10n.kidLockTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b))),
                    const SizedBox(height: HallySpace.sm),
                    Text('${l10n.kidLockUsed(_duration(l10n, used))}\n${l10n.kidLockTomorrow}', textAlign: TextAlign.center),
                    const SizedBox(height: HallySpace.lg),
                    KidIdeasCard(requireApproval: h.requireApproval),
                    const Spacer(),
                    const SizedBox(height: HallySpace.md),
                    if (buy != null) ...[
                      OutlinedButton(
                        key: const Key('kid.lock.buy'),
                        style: OutlinedButton.styleFrom(backgroundColor: theme.colorScheme.surface),
                        onPressed: () => _act(context, ref, (api) => api.redeem(buy.id), (_) => l10n.kidBoughtScreen(buy.screenMinutes!)),
                        child: Text(l10n.kidLockBuy(buy.cost, buy.screenMinutes!)),
                      ),
                      const SizedBox(height: HallySpace.sm),
                    ],
                    OutlinedButton(
                      key: const Key('kid.lock.ask'),
                      style: OutlinedButton.styleFrom(backgroundColor: theme.colorScheme.surface),
                      onPressed: _asked
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await ref.read(childApiProvider).requestTime(15);
                                setState(() => _asked = true);
                                // A parent's "Evet" adds the minutes; look for it now and then so the lock opens by itself.
                                _poll ??= Timer.periodic(const Duration(seconds: 15), (_) => ref.invalidate(childHomeProvider));
                                messenger.showSnackBar(SnackBar(content: Text(l10n.kidLockAsked)));
                              } catch (_) {
                                messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
                              }
                            },
                      child: Text(_asked ? l10n.kidLockAsked : l10n.kidLockAsk),
                    ),
                    const SizedBox(height: HallySpace.sm),
                    Row(children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () => launchUrl(Uri.parse('tel:112')),
                          icon: const Icon(Icons.call_rounded),
                          label: Text(l10n.kidLockEmergency),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () => ref.invalidate(childHomeProvider),
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(l10n.kidLockCheck),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _duration(AppLocalizations l10n, int minutes) => minutes >= 60 ? l10n.kidHoursMinutes(minutes ~/ 60, minutes % 60) : l10n.kidMinutes(minutes);
}

/// Android: the two permissions the screen lock needs, set up once by a parent on the child's phone.
class _LockSetupCard extends ConsumerWidget {
  const _LockSetupCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(childLockStatusProvider).valueOrNull;
    if (status == null || !status.supported || status.ready) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lock = ref.read(childLockProvider);
    Widget step(Key key, String title, bool done, Future<void> Function() open) => ListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          leading: Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: done ? HallyColors.accent(HallyColors.sage, theme.brightness) : null),
          title: Text(title),
          trailing: done ? null : TextButton(onPressed: open, child: Text(l10n.kidLockSetupOpen)),
        );
    return Card(
      key: const Key('kid.lockSetup'),
      margin: const EdgeInsets.only(bottom: HallySpace.md),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.md, HallySpace.sm, HallySpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.kidLockSetupTitle, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(l10n.kidLockSetupBody, style: theme.textTheme.bodySmall),
            step(const Key('kid.lockSetup.usage'), l10n.kidLockSetupUsage, status.usageAccess, lock.openUsageAccess),
            step(const Key('kid.lockSetup.overlay'), l10n.kidLockSetupOverlay, status.overlay, lock.openOverlay),
          ],
        ),
      ),
    );
  }
}
