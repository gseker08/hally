import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart' show childColor;

class ReportExam {
  const ReportExam(this.subject, this.date, this.outcome);
  final String subject;
  final DateTime date;
  final String? outcome;
}

class ReportChild {
  const ReportChild({
    required this.id,
    required this.name,
    required this.color,
    required this.exams,
    required this.studyMinutes,
    this.screenAvgMinutes,
    this.sleepAvgMinutes,
    required this.cherries,
    required this.activities,
  });

  final String id;
  final String name;
  final String color;
  final List<ReportExam> exams;
  final int studyMinutes;
  final int? screenAvgMinutes;
  final int? sleepAvgMinutes;
  final int cherries;
  final int activities;

  bool get isEmpty => exams.isEmpty && studyMinutes == 0 && screenAvgMinutes == null && sleepAvgMinutes == null && cherries == 0;
}

class UpcomingExam {
  const UpcomingExam(this.childName, this.subject, this.date);
  final String childName;
  final String subject;
  final DateTime date;
}

/// "Haftanın özeti" (server: WeeklyReportService).
class WeeklyReport {
  const WeeklyReport({
    required this.offset,
    required this.weekStart,
    required this.weekEnd,
    required this.tasksDone,
    required this.tasksDonePrevious,
    required this.events,
    required this.exams,
    required this.adults,
    required this.helperCompleted,
    required this.children,
    required this.nextExams,
    required this.nextEvents,
    this.busiestDay,
    required this.busiestCount,
    this.tip,
    required this.quiet,
  });

  factory WeeklyReport.fromJson(Map<String, dynamic> j) {
    DateTime d(Object? v) => DateTime.parse(v as String);
    final next = j['nextWeek'] as Map<String, dynamic>;
    return WeeklyReport(
      offset: j['offset'] as int,
      weekStart: d(j['weekStart']),
      weekEnd: d(j['weekEnd']),
      tasksDone: j['tasksDone'] as int,
      tasksDonePrevious: j['tasksDonePrevious'] as int,
      events: j['events'] as int,
      exams: j['exams'] as int,
      adults: [for (final a in j['adults'] as List) ((a as Map)['firstName'] as String, a['completed'] as int)],
      helperCompleted: j['helperCompleted'] as int? ?? 0,
      children: [
        for (final c in j['children'] as List)
          ReportChild(
            id: c['childId'] as String,
            name: c['firstName'] as String,
            color: c['color'] as String,
            exams: [for (final e in c['exams'] as List) ReportExam(e['subject'] as String, d(e['date']), e['outcome'] as String?)],
            studyMinutes: c['studyMinutes'] as int,
            screenAvgMinutes: c['screenAvgMinutes'] as int?,
            sleepAvgMinutes: c['sleepAvgMinutes'] as int?,
            cherries: c['cherries'] as int,
            activities: c['activities'] as int,
          ),
      ],
      nextExams: [for (final e in next['exams'] as List) UpcomingExam(e['childName'] as String, e['subject'] as String, d(e['date']))],
      nextEvents: next['events'] as int,
      busiestDay: next['busiestDay'] == null ? null : d(next['busiestDay']),
      busiestCount: next['busiestCount'] as int? ?? 0,
      tip: j['tip'] as String?,
      quiet: j['quiet'] as bool? ?? false,
    );
  }

  final int offset;
  final DateTime weekStart;
  final DateTime weekEnd;
  final int tasksDone;
  final int tasksDonePrevious;
  final int events;
  final int exams;
  final List<(String, int)> adults;
  final int helperCompleted;
  final List<ReportChild> children;
  final List<UpcomingExam> nextExams;
  final int nextEvents;
  final DateTime? busiestDay;
  final int busiestCount;
  final String? tip;
  final bool quiet;
}

typedef _ReportArgs = (String familyId, int? offset);

final weeklyReportProvider = FutureProvider.autoDispose.family<WeeklyReport, _ReportArgs>((ref, a) async {
  final api = ref.watch(apiClientProvider);
  try {
    final res = await api.dio.get<Map<String, dynamic>>('/api/v1/families/${a.$1}/weekly-report', queryParameters: {if (a.$2 != null) 'offset': a.$2});
    return WeeklyReport.fromJson(res.data!);
  } catch (e) {
    throw ApiClient.toApiException(e);
  }
});

/// Family → "Haftanın özeti", and where the Sunday notification lands. [offset] null = the server's default week.
class WeeklyReportScreen extends ConsumerStatefulWidget {
  const WeeklyReportScreen({super.key, this.offset});

  final int? offset;

  @override
  ConsumerState<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends ConsumerState<WeeklyReportScreen> {
  late int? _offset = widget.offset;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final report = ref.watch(weeklyReportProvider((familyId, _offset)));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.reportTitle),
        actions: [
          TextButton.icon(
            key: const Key('report.share'),
            onPressed: () => context.push('/weekly-card'),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: Text(l10n.reportShare),
          ),
        ],
      ),
      body: report.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(weeklyReportProvider((familyId, _offset)))),
        data: (r) => _ReportBody(
          report: r,
          onWeek: (o) => setState(() => _offset = o),
        ),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, required this.onWeek});

  final WeeklyReport report;
  final ValueChanged<int> onWeek;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final r = report;
    final range = '${DateFormat('d MMM', locale).format(r.weekStart)} – ${DateFormat('d MMM', locale).format(r.weekEnd)}';
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final trend = r.tasksDone - r.tasksDonePrevious;
    final total = r.adults.fold<int>(r.helperCompleted, (s, a) => s + a.$2);
    String dur(int m) => m >= 60 ? l10n.reportHoursMinutes(m ~/ 60, m % 60) : l10n.tipMinutes(m);
    String outcome(String? o) => switch (o) {
          'Hard' => l10n.examsOutcomeHard,
          'Good' => l10n.examsOutcomeGood,
          'Great' => l10n.examsOutcomeGreat,
          _ => '',
        };

    Widget stat(String value, String label, {Widget? extra}) => Expanded(
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(HallySpace.sm + 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(value, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                        if (extra != null) ...[const SizedBox(width: 6), extra],
                      ],
                    ),
                  ),
                  Text(label, style: muted),
                ],
              ),
            ),
          ),
        );

    Widget chip(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
          child: Text(text, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        );

    final kids = r.children.where((c) => !c.isEmpty).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, 48),
      children: [
        Row(
          children: [
            Expanded(child: Text(range, style: muted)),
            IconButton(
              key: const Key('report.previous'),
              tooltip: l10n.reportPrevious,
              onPressed: r.offset <= -8 ? null : () => onWeek(r.offset - 1),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            IconButton(
              key: const Key('report.next'),
              tooltip: l10n.reportNext,
              onPressed: r.offset >= 0 ? null : () => onWeek(r.offset + 1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        if (r.quiet)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HallySpace.xl),
            child: HallyEmptyState(icon: Icons.insights_rounded, color: HallyColors.lavender, title: l10n.reportQuietTitle, body: l10n.reportQuietBody),
          )
        else ...[
          Row(
            children: [
              stat('${r.tasksDone}', l10n.reportTasksDone,
                  extra: trend == 0
                      ? null
                      : Text(trend > 0 ? '+$trend' : '−${-trend}',
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: trend > 0 ? HallyColors.readableOn(HallyColors.sage, theme.brightness) : theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700))),
              const SizedBox(width: HallySpace.sm),
              stat('${r.events}', l10n.reportEvents),
              const SizedBox(width: HallySpace.sm),
              stat('${r.exams}', l10n.reportExams),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: HallySpace.sm),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.reportWhoDidWhat, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: HallySpace.sm),
                    for (final (i, a) in [...r.adults, if (r.helperCompleted > 0) (l10n.reportHelper, r.helperCompleted)].indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            SizedBox(width: 72, child: Text(a.$1, overflow: TextOverflow.ellipsis)),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  minHeight: 12,
                                  value: total == 0 ? 0 : a.$2 / total,
                                  color: i == 0 ? HallyColors.cherry : HallyColors.sage,
                                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                                ),
                              ),
                            ),
                            SizedBox(width: 32, child: Text('${a.$2}', textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (kids.isNotEmpty) ...[
            const SizedBox(height: HallySpace.sm),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, c) in kids.indexed) ...[
                      if (i > 0) const SizedBox(height: HallySpace.md),
                      Row(
                        children: [
                          CircleAvatar(radius: 5, backgroundColor: childColor(c.color)),
                          const SizedBox(width: 8),
                          Text(c.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (c.exams.isNotEmpty)
                            chip('📝 ${l10n.reportChildExams(c.exams.length)}'
                                '${c.exams.any((e) => e.outcome != null) ? ' · ${c.exams.where((e) => e.outcome != null).map((e) => outcome(e.outcome)).join(', ')}' : ''}'),
                          if (c.studyMinutes > 0) chip('📚 ${l10n.reportStudy(dur(c.studyMinutes))}'),
                          if (c.screenAvgMinutes case final s?) chip('📱 ${l10n.reportScreenAvg(dur(s))}'),
                          if (c.sleepAvgMinutes case final s?) chip('😴 ${l10n.reportSleepAvg(dur(s))}'),
                          if (c.activities > 0) chip('🌳 ${l10n.reportActivities(c.activities)}'),
                          if (c.cherries > 0) chip('🍒 +${c.cherries}'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
        if (r.nextExams.isNotEmpty || r.nextEvents > 0) ...[
          const SizedBox(height: HallySpace.sm),
          Container(
            padding: const EdgeInsets.all(HallySpace.md),
            decoration: BoxDecoration(
              color: HallyColors.softOf(HallyColors.lavender, theme.brightness),
              borderRadius: BorderRadius.circular(HallyRadius.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.reportNextWeek, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                if (r.nextExams.isNotEmpty)
                  Text('📝 ${l10n.reportNextExams(r.nextExams.length)}: '
                      '${r.nextExams.map((e) => '${e.childName} ${e.subject} ${DateFormat('EEE', locale).format(e.date)}').join(', ')}'),
                if (r.nextEvents > 0) Text('📅 ${l10n.reportNextEvents(r.nextEvents)}'),
                if (r.busiestDay case final day?) Text('🔥 ${l10n.reportBusiest(DateFormat('EEEE', locale).format(day), r.busiestCount)}'),
              ],
            ),
          ),
        ],
        if (r.tip case final tip?) ...[
          const SizedBox(height: HallySpace.sm),
          Container(
            key: const Key('report.tip'),
            padding: const EdgeInsets.all(HallySpace.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(HallyRadius.lg),
              border: Border.all(color: theme.brightness == Brightness.dark ? HallyColors.powderPastelDark : HallyColors.powderPastel, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('💡 ${l10n.reportTipHeader}',
                    style:
                        theme.textTheme.labelLarge?.copyWith(color: HallyColors.readableOn(HallyColors.cherry, theme.brightness), fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(tip, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
