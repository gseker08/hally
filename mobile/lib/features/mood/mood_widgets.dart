import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../child_mode/child_mode_repository.dart';
import '../family/children.dart';
import 'mood.dart';

/// Child mode, once a day: "Bugün nasılsın?" with six big faces and optional reasons. Same +1 cherry whatever the
/// answer, so an honest "Üzgün" is never worth less than "Çok iyi".
class KidMoodCard extends ConsumerStatefulWidget {
  const KidMoodCard({super.key});

  @override
  ConsumerState<KidMoodCard> createState() => _KidMoodCardState();
}

class _KidMoodCardState extends ConsumerState<KidMoodCard> {
  String? _mood;
  final _reasons = <String>{};
  bool _saving = false;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final cherries = await ref.read(childApiProvider).answerMood(_mood!, _reasons.toList());
      messenger.showSnackBar(SnackBar(content: Text(cherries > 0 ? l10n.moodThanks : l10n.moodSaved)));
      ref.invalidate(childHomeProvider);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final accent = HallyColors.accent(HallyColors.cherry, b);

    return Card(
      key: const Key('mood.card'),
      margin: const EdgeInsets.only(bottom: HallySpace.md),
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(
          children: [
            Text(l10n.moodQuestion, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: accent)),
            const SizedBox(height: 4),
            Text(l10n.moodQuestionHint, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: HallySpace.md),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.95,
              children: [
                for (final m in moodValues)
                  HallyPressable(
                    key: Key('mood.$m'),
                    onTap: () => setState(() => _mood = m),
                    child: AnimatedContainer(
                      duration: HallyMotion.fast,
                      decoration: BoxDecoration(
                        color: _mood == m ? HallyColors.softOf(HallyColors.cherry, b) : theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: _mood == m ? accent : theme.dividerColor.withValues(alpha: 0.5), width: 2),
                      ),
                      padding: const EdgeInsets.all(6),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(moodEmoji(m), style: const TextStyle(fontSize: 38)),
                          const SizedBox(height: 4),
                          Text(moodLabel(l10n, m), style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
            if (_mood != null) ...[
              const SizedBox(height: HallySpace.md),
              Align(alignment: Alignment.centerLeft, child: Text(l10n.moodWhy, style: theme.textTheme.titleSmall)),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final r in moodReasons)
                    FilterChip(
                      key: Key('mood.reason.$r'),
                      label: Text('${reasonEmoji(r)} ${reasonLabel(l10n, r)}'),
                      selected: _reasons.contains(r),
                      onSelected: (on) => setState(() => on ? _reasons.add(r) : _reasons.remove(r)),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: HallySpace.md),
            Row(children: [
              TextButton(key: const Key('mood.later'), onPressed: () => ref.read(moodSkippedProvider.notifier).state = true, child: Text(l10n.moodLater)),
              const Spacer(),
              Flexible(
                flex: 4,
                child: FilledButton(
                  key: const Key('mood.save'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _mood == null || _saving ? null : _save,
                  child: Row(
                      mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text(l10n.moodSave)), const SizedBox(width: 4), const CherryIcon(size: 18)]),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Parents only: a child's answers for the week (or 4 weeks), the trend, and a gentle nudge after a hard day.
class MoodScreen extends ConsumerStatefulWidget {
  const MoodScreen({super.key, required this.childId});

  final String childId;

  @override
  ConsumerState<MoodScreen> createState() => _MoodScreenState();
}

class _MoodScreenState extends ConsumerState<MoodScreen> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final child = watchChildren(ref, familyId).where((c) => c.id == widget.childId).firstOrNull;
    final name = child?.firstName ?? '';
    final key = (familyId, widget.childId, _days);
    final data = ref.watch(childMoodsProvider(key));
    final locale = Localizations.localeOf(context).toLanguageTag();

    return Scaffold(
      appBar: AppBar(title: Text(child == null ? l10n.moodTitle : l10n.moodTitleFor(name))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 7, label: Text(l10n.moodThisWeek, key: const Key('mood.week'))),
              ButtonSegment(value: 28, label: Text(l10n.moodFourWeeks, key: const Key('mood.month'))),
            ],
            selected: {_days},
            onSelectionChanged: (v) => setState(() => _days = v.first),
          ),
          const SizedBox(height: HallySpace.md),
          ...data.when(
            loading: () => [const Padding(padding: EdgeInsets.all(HallySpace.xl), child: HallyLoading())],
            error: (_, __) => [HallyErrorState(onRetry: () => ref.invalidate(childMoodsProvider(key)))],
            data: (w) => [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.moodWeekOf(name), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: HallySpace.sm),
                    if (w.isEmpty)
                      Text(l10n.moodEmpty, key: const Key('mood.empty'), style: theme.textTheme.bodyMedium)
                    else ...[
                      if (_days == 7)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            for (final d in w.days)
                              Column(children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                    border: DateUtils.isSameDay(d.date, w.today)
                                        ? Border.all(color: HallyColors.accent(HallyColors.cherry, theme.brightness), width: 2)
                                        : null,
                                  ),
                                  child: Text(d.mood == null ? '–' : moodEmoji(d.mood!), style: TextStyle(fontSize: d.mood == null ? 14 : 20)),
                                ),
                                const SizedBox(height: 4),
                                Text(DateFormat.E(locale).format(d.date), style: theme.textTheme.labelSmall),
                              ]),
                          ],
                        ),
                      const SizedBox(height: HallySpace.md),
                      SizedBox(height: 110, child: CustomPaint(key: const Key('mood.trend'), size: Size.infinite, painter: _TrendPainter(w.days, theme, l10n))),
                    ],
                  ]),
                ),
              ),
              if (w.nudge case final n?)
                Container(
                  key: const Key('mood.nudge'),
                  margin: const EdgeInsets.only(top: HallySpace.sm),
                  padding: const EdgeInsets.all(HallySpace.md),
                  decoration:
                      BoxDecoration(color: HallyColors.softOf(HallyColors.peach, theme.brightness), borderRadius: BorderRadius.circular(HallyRadius.lg)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('💬', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: HallySpace.sm),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          [
                            l10n.moodNudgeTitle(DateFormat.EEEE(locale).format(n.date), name, moodLabel(l10n, n.mood)),
                            if (n.reason != null) reasonLabel(l10n, n.reason!)
                          ].join(' · '),
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(switch (n.reason) { 'School' => l10n.moodNudgeSchool, 'Friends' => l10n.moodNudgeFriends, _ => l10n.moodNudgeBody },
                            style: theme.textTheme.bodyMedium),
                      ]),
                    ),
                  ]),
                ),
              if (!w.isEmpty)
                Card(
                  margin: const EdgeInsets.only(top: HallySpace.sm),
                  child: Padding(
                    padding: const EdgeInsets.all(HallySpace.md),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l10n.moodMostCommon, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          Text(
                              w.mostCommon == null
                                  ? '–'
                                  : '${moodEmoji(w.mostCommon!)} ${l10n.moodMostCommonValue(moodLabel(l10n, w.mostCommon!), w.mostCommonDays)}',
                              key: const Key('mood.mostCommon'),
                              style: theme.textTheme.bodySmall),
                        ]),
                      ),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l10n.moodTopReason, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          Text(w.topReason == null ? '–' : '${reasonEmoji(w.topReason!)} ${reasonLabel(l10n, w.topReason!)}', style: theme.textTheme.bodySmall),
                        ]),
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: HallySpace.md),
              Text(l10n.moodPrivacy, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.days, this.theme, this.l10n);

  final List<MoodDay> days;
  final ThemeData theme;
  final AppLocalizations l10n;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = theme.dividerColor.withValues(alpha: 0.35);
    const labelW = 30.0;
    final w = size.width - labelW;
    double y(int score) => 12 + (4 - score) / 3 * (size.height - 24);
    for (final s in [4, 1]) {
      canvas.drawLine(Offset(0, y(s)), Offset(w, y(s)), grid);
      final tp = TextPainter(
        text: TextSpan(
            text: s == 4 ? l10n.moodGoodLabel : l10n.moodHardLabel, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w + 4, y(s) - tp.height / 2));
    }

    final step = days.length <= 1 ? 0.0 : w / (days.length - 1);
    final line = Paint()
      ..color = HallyColors.accent(HallyColors.cherry, theme.brightness)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Offset? prev;
    for (final (i, d) in days.indexed) {
      if (d.mood == null) {
        prev = null;
        continue;
      }

      final p = Offset(i * step, y(moodScore(d.mood!)));
      if (prev != null) canvas.drawLine(prev, p, line);
      canvas.drawCircle(p, 5, Paint()..color = moodIsHard(d.mood!) ? HallyColors.accent(HallyColors.peach, theme.brightness) : line.color);
      prev = p;
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.days != days || old.theme != theme;
}
