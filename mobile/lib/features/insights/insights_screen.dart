import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart' show familyProvider, isCaregiverProvider;
import '../sleep/sleep_screen.dart' show formatSleepMinutes;
import 'insights_repository.dart';
import '../../core/locale/units.dart';

/// One child's logs at a glance, for a day or for the 7 days ending on a day: screen time, homework and reading, sleep,
/// feeding, stars, habits, medicine and the health card. Each part shows only when it has something to say.
class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key, required this.childId, this.today});

  final String childId;

  /// For tests; defaults to the device's today.
  final DateTime? today;

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  bool _week = false;
  late final DateTime _today = DateUtils.dateOnly(widget.today ?? DateTime.now());
  late DateTime _day = _today;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final child = watchChildren(ref, familyId).where((c) => c.id == widget.childId).firstOrNull;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final from = _week ? _day.subtract(const Duration(days: 6)) : _day;
    final key = (familyId, widget.childId, insightsDay(from), insightsDay(_day));
    final data = ref.watch(childInsightsProvider(key));
    final step = Duration(days: _week ? 7 : 1);
    final label = _week
        ? '${DateFormat.MMMd(locale).format(from)} – ${DateFormat.MMMd(locale).format(_day)}'
        : (_day == _today ? l10n.insightsToday : DateFormat.MMMEd(locale).format(_day));

    return Scaffold(
      appBar: AppBar(title: Text(child == null ? l10n.insightsTitle : l10n.insightsTitleFor(child.firstName))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: false, label: Text(l10n.insightsDaily, key: const Key('insights.daily'))),
              ButtonSegment(value: true, label: Text(l10n.insightsWeekly, key: const Key('insights.weekly'))),
            ],
            selected: {_week},
            onSelectionChanged: (v) => setState(() => _week = v.first),
          ),
          Row(
            children: [
              IconButton(key: const Key('insights.prev'), onPressed: () => setState(() => _day = _day.subtract(step)), icon: const Icon(Icons.chevron_left_rounded)),
              Expanded(child: Text(label, key: const Key('insights.range'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                key: const Key('insights.next'),
                onPressed: _day == _today ? null : () => setState(() => _day = _day.add(step).isAfter(_today) ? _today : _day.add(step)),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          ...data.when(
            loading: () => [const Padding(padding: EdgeInsets.all(HallySpace.xl), child: HallyLoading())],
            error: (_, __) => [HallyErrorState(onRetry: () => ref.invalidate(childInsightsProvider(key)))],
            data: (d) => _sections(context, d),
          ),
          if (!ref.watch(isCaregiverProvider))
            ListTile(
              key: const Key('insights.moods'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.mood_rounded),
              title: Text(l10n.moodTitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/child/${widget.childId}/moods'),
            ),
          if (ref.watch(familyProvider(familyId)).valueOrNull?.members.any((m) => m.isCaregiver) ?? false)
            ListTile(
              key: const Key('insights.handoffs'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.assignment_turned_in_outlined),
              title: Text(l10n.handoffHistory),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(Uri(path: '/handoffs', queryParameters: {'childId': widget.childId}).toString()),
            ),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context, ChildInsights d) {
    final l10n = AppLocalizations.of(context);
    final lang = langOf(context);
    String dur(int m) => formatSleepMinutes(m, lang: lang);
    final n = d.days.length;
    final out = <Widget>[];

    // Screen time
    final screen = d.sum((x) => x.screenMinutes);
    if (screen > 0 || d.screenGoalMinutes != null) {
      final goal = d.screenGoalMinutes;
      final over = goal == null ? 0 : d.days.where((x) => x.screenMinutes > goal).length;
      out.add(_Section(
        key: const Key('insights.screen'),
        icon: Icons.phone_android_rounded,
        color: HallyColors.sky,
        title: l10n.screenTimeTitle,
        value: _week ? l10n.insightsTotal(dur(screen)) : dur(screen),
        lines: [
          if (goal != null) _week ? l10n.insightsGoalOverDays(dur(goal), over) : (screen > goal ? l10n.insightsOverGoal(dur(goal)) : l10n.insightsGoalOf(dur(goal))),
          if (_week) l10n.insightsAverage(dur(screen ~/ n)),
        ],
        warn: goal != null && (_week ? over > 0 : screen > goal),
        progress: !_week && goal != null ? screen / goal : null,
        bars: _week ? [for (final x in d.days) x.screenMinutes.toDouble()] : null,
        goal: goal?.toDouble(),
        dates: d.days.map((x) => x.date).toList(),
        overIsBad: true,
      ));
    }

    // Homework and reading
    final study = d.sum((x) => x.studyMinutes);
    if (study > 0 || d.studyGoalMinutes != null) {
      final goal = d.studyGoalMinutes;
      final met = goal == null ? 0 : d.days.where((x) => x.studyMinutes >= goal).length;
      out.add(_Section(
        key: const Key('insights.study'),
        icon: Icons.menu_book_rounded,
        color: HallyColors.mint,
        title: l10n.studyTitle,
        value: _week ? l10n.insightsTotal(dur(study)) : dur(study),
        lines: [
          l10n.insightsStudySplit(dur(d.sum((x) => x.homeworkMinutes)), dur(d.sum((x) => x.readingMinutes))),
          if (goal != null) _week ? l10n.insightsGoalMetDays(dur(goal), met, n) : l10n.insightsGoalOf(dur(goal)),
        ],
        progress: !_week && goal != null ? study / goal : null,
        bars: _week ? [for (final x in d.days) x.studyMinutes.toDouble()] : null,
        goal: goal?.toDouble(),
        dates: d.days.map((x) => x.date).toList(),
      ));
    }

    // Sleep
    final sleep = d.sum((x) => x.sleepMinutes);
    if (sleep > 0) {
      out.add(_Section(
        key: const Key('insights.sleep'),
        icon: Icons.bedtime_rounded,
        color: HallyColors.sky,
        title: l10n.sleepTitle,
        value: _week ? l10n.insightsAverage(dur(sleep ~/ n)) : dur(sleep),
        lines: [l10n.insightsSleepSplit(dur(d.sum((x) => x.nightSleepMinutes)), dur(d.sum((x) => x.napMinutes)))],
        bars: _week ? [for (final x in d.days) x.sleepMinutes.toDouble()] : null,
        dates: d.days.map((x) => x.date).toList(),
      ));
    }

    // Feeding
    final feeds = d.sum((x) => x.feeds);
    if (feeds > 0) {
      final ml = d.sum((x) => x.bottleMl);
      final breast = d.sum((x) => x.breastMinutes);
      final solids = d.sum((x) => x.solids);
      out.add(_Section(
        key: const Key('insights.feeding'),
        icon: Icons.baby_changing_station_rounded,
        color: HallyColors.apricot,
        title: l10n.feedingTitle,
        value: l10n.insightsFeeds(feeds),
        lines: [
          [if (ml > 0) '$ml ml', if (breast > 0) dur(breast), if (solids > 0) l10n.insightsSolids(solids)].join(' · '),
        ].where((s) => s.isNotEmpty).toList(),
        bars: _week ? [for (final x in d.days) x.feeds.toDouble()] : null,
        dates: d.days.map((x) => x.date).toList(),
      ));
    }

    // Stars
    final earned = d.sum((x) => x.starsEarned);
    final spent = d.sum((x) => x.starsSpent);
    if (earned > 0 || spent > 0 || d.starBalance > 0) {
      out.add(_Section(
        key: const Key('insights.stars'),
        icon: Icons.star_rounded,
        color: HallyColors.apricot,
        title: l10n.pointsTitle,
        value: '+$earned',
        lines: [if (spent > 0) l10n.insightsStarsSpent(spent), l10n.pointsBalance(d.starBalance)],
        onTap: () => context.push('/stars'),
      ));
    }

    // Habits
    if (d.habits.isNotEmpty) {
      out.add(Card(
        key: const Key('insights.habits'),
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(icon: Icons.local_fire_department_rounded, color: HallyColors.apricot, title: l10n.habitsTitle),
              for (final h in d.habits)
                Padding(
                  padding: const EdgeInsets.only(top: HallySpace.xs),
                  child: Row(
                    children: [
                      Expanded(child: Text(h.title)),
                      Text(h.scheduled == 0 ? '–' : '${h.done}/${h.scheduled}', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(width: HallySpace.md),
                      const Icon(Icons.local_fire_department_rounded, size: 18, color: HallyColors.apricot),
                      Text(' ${h.streak}'),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ));
    }

    // Medicine
    if (d.medications.isNotEmpty) {
      out.add(_Section(
        key: const Key('insights.medications'),
        icon: Icons.medication_rounded,
        color: HallyColors.rose,
        title: l10n.medicationsTitle,
        value: l10n.insightsDoses(d.sum((x) => x.doses)),
        lines: [for (final m in d.medications) '${m.name}: ${l10n.insightsDoses(m.doses)}'],
        onTap: () => context.push('/medications'),
      ));
    }

    // Health card
    final h = d.health;
    if (!h.isEmpty) {
      final locale = Localizations.localeOf(context).toLanguageTag();
      final num = NumberFormat.decimalPattern(locale);
      out.add(_Section(
        key: const Key('insights.health'),
        icon: Icons.health_and_safety_rounded,
        color: HallyColors.sky,
        title: l10n.healthTitle,
        value: [if (h.heightCm != null) '${num.format(h.heightCm)} cm', if (h.weightKg != null) '${num.format(h.weightKg)} kg'].join(' · '),
        lines: [
          if (h.hasAllergies) l10n.insightsHasAllergies,
          if (h.vaccinesOverdue > 0) l10n.insightsVaccinesOverdue(h.vaccinesOverdue),
          if (h.vaccinesDueSoon > 0) l10n.insightsVaccinesSoon(h.vaccinesDueSoon),
          if (h.nextAppointment != null) l10n.insightsNextAppointment(h.nextAppointment!, DateFormat.MMMEd(locale).add_Hm().format(h.nextAppointmentAt!)),
        ],
        warn: h.vaccinesOverdue > 0,
        onTap: () => context.push('/health'),
      ));
    }

    // Expenses for this child
    if (d.expensesTotal > 0) {
      final money = NumberFormat.currency(locale: Localizations.localeOf(context).toLanguageTag(), symbol: '₺', decimalDigits: 2);
      out.add(_Section(
        key: const Key('insights.expenses'),
        icon: Icons.account_balance_wallet_rounded,
        color: HallyColors.mint,
        title: l10n.expensesTitle,
        value: money.format(d.expensesTotal),
        lines: const [],
        onTap: () => context.push('/expenses'),
      ));
    }

    if (out.isEmpty) {
      out.add(Padding(padding: const EdgeInsets.all(HallySpace.lg), child: Text(l10n.insightsEmpty, key: const Key('insights.empty'), textAlign: TextAlign.center)));
    }
    return out;
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.color, required this.title, this.value});

  final IconData icon;
  final Color color;
  final String title;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: HallySpace.sm),
        Expanded(child: Text(title, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
        if (value != null && value!.isNotEmpty)
          Flexible(
            flex: 2,
            child: Text(value!, textAlign: TextAlign.end, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.lines,
    this.warn = false,
    this.progress,
    this.bars,
    this.goal,
    this.dates = const [],
    this.overIsBad = false,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final List<String> lines;
  final bool warn;
  final double? progress;
  final List<double>? bars;
  final double? goal;
  final List<DateTime> dates;
  final bool overIsBad;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(icon: icon, color: color, title: title, value: value),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(l, style: theme.textTheme.bodyMedium?.copyWith(color: warn && l == lines.first ? HallyColors.error : Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              if (progress != null) ...[
                const SizedBox(height: HallySpace.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0, 1).toDouble(),
                    minHeight: 8,
                    color: warn ? HallyColors.error : color,
                    backgroundColor: color.withValues(alpha: 0.15),
                  ),
                ),
              ],
              if (bars != null && bars!.any((b) => b > 0)) ...[
                const SizedBox(height: HallySpace.sm),
                SizedBox(
                  height: 96,
                  child: CustomPaint(size: Size.infinite, painter: _BarsPainter(bars!, goal: goal, color: color, overIsBad: overIsBad)),
                ),
                Row(
                  children: [
                    for (final d in dates)
                      Expanded(child: Text(DateFormat.E(locale).format(d).characters.take(2).toString(), textAlign: TextAlign.center, style: theme.textTheme.labelSmall)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, {required this.color, this.goal, this.overIsBad = false});

  final List<double> values;
  final double? goal;
  final Color color;
  final bool overIsBad;

  @override
  void paint(Canvas canvas, Size size) {
    final top = [...values, goal ?? 0].reduce((a, b) => a > b ? a : b);
    if (top <= 0) return;
    final slot = size.width / values.length;
    final w = slot * 0.55;
    for (var i = 0; i < values.length; i++) {
      final h = values[i] / top * (size.height - 4);
      final bad = overIsBad && goal != null && values[i] > goal!;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(i * slot + (slot - w) / 2, size.height - h, w, h), const Radius.circular(4));
      canvas.drawRRect(r, Paint()..color = bad ? HallyColors.error : color);
    }
    if (goal != null) {
      final y = size.height - goal! / top * (size.height - 4);
      final paint = Paint()
        ..color = HallyColors.inkMuted
        ..strokeWidth = 1.5;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(x + 4, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.values != values || old.goal != goal;
}
