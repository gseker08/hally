import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../capture/capture_sheet.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import '../planning/planning_repository.dart';
import '../study/study_repository.dart';
import 'exams.dart';

String _locale(BuildContext context) => Localizations.localeOf(context).toLanguageTag();

/// "Bugün", "Yarın", "5 gün".
String examCountdown(AppLocalizations l10n, int daysLeft) => switch (daysLeft) {
      0 => l10n.examsToday,
      1 => l10n.examsTomorrow,
      _ => l10n.examsDaysLeft(daysLeft),
    };

String examOutcomeLabel(AppLocalizations l10n, String outcome) => switch (outcome) {
      'Hard' => l10n.examsOutcomeHard,
      'Good' => l10n.examsOutcomeGood,
      _ => l10n.examsOutcomeGreat,
    };

String examOutcomeEmoji(String outcome) => switch (outcome) {
      'Hard' => '😕',
      'Good' => '🙂',
      _ => '🤩',
    };

/// Three days or less: orange (attention, never red). Further away: green.
Color examCountdownColor(int daysLeft) => daysLeft <= 3 ? HallyColors.apricot : HallyColors.mint;

ChildProfile? _childOf(List<ChildProfile> children, String id) {
  for (final c in children) {
    if (c.id == id) return c;
  }
  return null;
}

/// Sınavlar: upcoming exams per child with a countdown, those waiting for a result, and recent results.
class ExamsScreen extends ConsumerStatefulWidget {
  const ExamsScreen({super.key, this.childId});

  /// Opened from a child's page: start filtered to that child.
  final String? childId;

  @override
  ConsumerState<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends ConsumerState<ExamsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.childId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(childFilterProvider.notifier).state = widget.childId;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final caregiver = ref.watch(isCaregiverProvider);
    final children = watchChildren(ref, familyId);
    final filter = ref.watch(childFilterProvider);
    final exams = ref.watch(examsProvider(familyId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.examsTitle),
        actions: [
          if (!caregiver)
            Padding(
              padding: const EdgeInsets.only(right: HallySpace.sm),
              child: FilledButton.icon(
                key: const Key('exams.add'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () => showExamEditor(context, ref, familyId: familyId, childId: filter),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.examsAdd),
              ),
            ),
        ],
      ),
      body: exams.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(examsProvider(familyId))),
        data: (all) {
          final list = filterByChild(all, (e) => [e.childId], filter);
          final upcoming = list.where((e) => e.upcoming).toList();
          final awaiting = caregiver ? <Exam>[] : list.where((e) => e.awaitingResult).toList().reversed.toList();
          final results = caregiver ? <Exam>[] : list.where((e) => e.hasResult && !e.upcoming).toList().reversed.toList();
          return RefreshIndicator(
            onRefresh: () => ref.refresh(examsProvider(familyId).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, 120),
              children: [
                ChildFilterBar(familyId: familyId, padding: EdgeInsets.zero),
                HallySectionHeader(title: l10n.examsUpcoming, count: upcoming.length),
                if (upcoming.isEmpty)
                  HallyEmptyState(icon: Icons.edit_note_rounded, title: l10n.examsEmpty, body: l10n.examsEmptyBody)
                else
                  for (final e in upcoming)
                    _ExamCard(
                      exam: e,
                      child: _childOf(children, e.childId),
                      onTap: caregiver ? null : () => showExamEditor(context, ref, familyId: familyId, exam: e),
                    ),
                if (awaiting.isNotEmpty) ...[
                  HallySectionHeader(title: l10n.examsAwaiting, count: awaiting.length),
                  for (final e in awaiting)
                    _ExamCard(
                      exam: e,
                      child: _childOf(children, e.childId),
                      onTap: () => context.push('/exams/${e.id}/result'),
                      action: OutlinedButton(
                        key: Key('exam.${e.id}.result'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: () => context.push('/exams/${e.id}/result'),
                        child: Text(l10n.examsEnterResult),
                      ),
                    ),
                ],
                if (results.isNotEmpty) ...[
                  HallySectionHeader(title: l10n.examsResults),
                  for (final e in results.take(10))
                    _ExamCard(exam: e, child: _childOf(children, e.childId), onTap: () => context.push('/exams/${e.id}/result')),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A date box (27 / Cuma) in the child's colour, the subject and topics, and a countdown or an action.
class _ExamCard extends StatelessWidget {
  const _ExamCard({required this.exam, required this.child, this.onTap, this.action});

  final Exam exam;
  final ChildProfile? child;
  final VoidCallback? onTap;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final color = child == null ? HallyColors.mist : childColor(child!.color);
    final soon = exam.upcoming && exam.daysLeft <= 3;
    final subtitle = exam.upcoming || !exam.hasResult
        ? (exam.upcoming ? (exam.topics ?? l10n.examsNoTopics) : l10n.examsHowDidItGo(exam.childName))
        : '${examOutcomeEmoji(exam.outcome!)} ${examOutcomeLabel(l10n, exam.outcome!)}${exam.score == null ? '' : ' · ${exam.score}'}';
    return Card(
      key: Key('exam.${exam.id}'),
      shape: soon
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HallyRadius.lg), side: BorderSide(color: HallyColors.softOf(HallyColors.apricot, b), width: 2))
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md - 2),
          child: Row(
            children: [
              ExamDateBox(date: exam.date, color: exam.upcoming ? color : HallyColors.line),
              const SizedBox(width: HallySpace.md - 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(exam.subject, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (child != null && exam.upcoming) ...[
                      const SizedBox(height: 6),
                      HallyPill(label: child!.firstName, color: color),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: HallySpace.sm),
              action ??
                  (exam.upcoming
                      ? HallyPill(key: Key('exam.${exam.id}.countdown'), label: examCountdown(l10n, exam.daysLeft), color: examCountdownColor(exam.daysLeft))
                      : exam.cherries > 0
                          ? Row(mainAxisSize: MainAxisSize.min, children: [Text('+${exam.cherries}', style: theme.textTheme.titleSmall), const CherryIcon(size: 18)])
                          : const SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }
}

/// "27 / Cuma" on the child's pastel.
class ExamDateBox extends StatelessWidget {
  const ExamDateBox({super.key, required this.date, required this.color, this.size = 56});

  final DateTime date;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final fg = HallyColors.readableOn(color, b);
    final withinWeek = date.difference(DateUtils.dateOnly(DateTime.now())).inDays.abs() < 7;
    return Container(
      width: size,
      height: size + 4,
      decoration: BoxDecoration(color: HallyColors.softOf(color, b), borderRadius: BorderRadius.circular(HallyRadius.md)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${date.day}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1, color: fg)),
          const SizedBox(height: 2),
          Text(withinWeek ? DateFormat('EEEE', _locale(context)).format(date) : DateFormat('MMM', _locale(context)).format(date),
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg), maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
        ],
      ),
    );
  }
}

/// Add or edit an exam. Returns the saved exam (null when cancelled or deleted).
Future<Exam?> showExamEditor(BuildContext context, WidgetRef ref, {required String familyId, Exam? exam, String? childId}) =>
    showModalBottomSheet<Exam>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ExamEditor(familyId: familyId, exam: exam, childId: childId),
    );

class _ExamEditor extends ConsumerStatefulWidget {
  const _ExamEditor({required this.familyId, this.exam, this.childId});

  final String familyId;
  final Exam? exam;
  final String? childId;

  @override
  ConsumerState<_ExamEditor> createState() => _ExamEditorState();
}

class _ExamEditorState extends ConsumerState<_ExamEditor> {
  late final _subject = TextEditingController(text: widget.exam?.subject ?? '');
  late final _topics = TextEditingController(text: widget.exam?.topics ?? '');
  late final _slot = TextEditingController(text: widget.exam?.slot ?? '');
  late String? _childId = widget.exam?.childId ?? widget.childId;
  late DateTime _date = widget.exam?.date ?? DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 3));
  late int? _studyDays = widget.exam == null ? 3 : widget.exam!.studyDaysBefore;
  bool _busy = false;

  @override
  void dispose() {
    _subject.dispose();
    _topics.dispose();
    _slot.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final childId = _childId;
    if (childId == null || _subject.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final draft = ExamDraft(
      childId: childId,
      subject: _subject.text.trim(),
      date: _date,
      topics: _topics.text.trim().isEmpty ? null : _topics.text.trim(),
      slot: _slot.text.trim().isEmpty ? null : _slot.text.trim(),
      studyDaysBefore: _studyDays,
    );
    try {
      final repo = ref.read(examsRepositoryProvider);
      final saved = widget.exam == null ? await repo.create(widget.familyId, draft) : await repo.update(widget.familyId, widget.exam!.id, draft);
      ref.invalidate(examsProvider(widget.familyId));
      ref.invalidate(calendarEventsProvider);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(examsRepositoryProvider).delete(widget.familyId, widget.exam!.id);
      ref.invalidate(examsProvider(widget.familyId));
      ref.invalidate(calendarEventsProvider);
      if (mounted) Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.examsDeleted)));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  Future<void> _pickDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 60)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final children = watchChildren(ref, widget.familyId);
    _childId ??= children.length == 1 ? children.first.id : null;
    final subjects = l10n.examsSubjects.split('|');
    final typed = _subject.text.trim();
    final custom = typed.isNotEmpty && !subjects.contains(typed);
    final label = theme.textTheme.labelLarge;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.sm, HallySpace.lg, HallySpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(widget.exam == null ? l10n.examsNew : l10n.examsEdit,
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                if (widget.exam != null)
                  IconButton(key: const Key('exam.delete'), tooltip: l10n.examsDelete, onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline)),
              ],
            ),
            if (children.length > 1) ...[
              const SizedBox(height: HallySpace.sm),
              Text(l10n.examsWho, style: label),
              const SizedBox(height: HallySpace.xs),
              Wrap(spacing: HallySpace.sm, children: [
                for (final c in children)
                  ChoiceChip(
                    key: Key('exam.child.${c.id}'),
                    avatar: ChildBadge(child: c, size: 20),
                    label: Text(c.firstName),
                    selected: _childId == c.id,
                    selectedColor: HallyColors.softOf(childColor(c.color), theme.brightness),
                    onSelected: (_) => setState(() => _childId = c.id),
                  ),
              ]),
            ],
            const SizedBox(height: HallySpace.sm),
            Text(l10n.examsSubject, style: label),
            const SizedBox(height: HallySpace.xs),
            Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.xs, children: [
              for (final s in subjects)
                ChoiceChip(
                  key: Key('exam.subject.$s'),
                  label: Text(s),
                  selected: typed == s,
                  onSelected: (_) => setState(() => _subject.text = s),
                ),
            ]),
            const SizedBox(height: HallySpace.sm),
            TextField(
              key: const Key('exam.subjectField'),
              controller: _subject,
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.examsSubjectHint,
                prefixIcon: Icon(custom ? Icons.edit_rounded : Icons.edit_outlined, size: 20),
                counterText: '',
                isDense: true,
              ),
            ),
            const SizedBox(height: HallySpace.md),
            Text(l10n.examsDate, style: label),
            const SizedBox(height: HallySpace.xs),
            Row(children: [
              Expanded(
                flex: 3,
                child: OutlinedButton.icon(
                  key: const Key('exam.date'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today_rounded, size: 18),
                  label: Text(DateFormat.MMMMEEEEd(_locale(context)).format(_date), overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('exam.slot'),
                  controller: _slot,
                  maxLength: 20,
                  decoration: InputDecoration(hintText: l10n.examsSlotHint, counterText: '', isDense: true, prefixIcon: const Icon(Icons.schedule_rounded, size: 18)),
                ),
              ),
            ]),
            const SizedBox(height: HallySpace.md),
            Text(l10n.examsTopics, style: label),
            const SizedBox(height: HallySpace.xs),
            TextField(
              key: const Key('exam.topics'),
              controller: _topics,
              maxLength: 200,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(hintText: l10n.examsTopicsHint, counterText: '', isDense: true),
            ),
            const SizedBox(height: HallySpace.md),
            Card(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l10n.examsStudyReminder, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          Text(
                              _studyDays == null
                                  ? l10n.examsStudyReminderOff
                                  : _studyDays == 7
                                      ? l10n.examsStudyReminderWeek
                                      : l10n.examsStudyReminderBody(_studyDays!),
                              style: theme.textTheme.bodySmall),
                        ]),
                      ),
                      Switch(
                        key: const Key('exam.study'),
                        value: _studyDays != null,
                        onChanged: (on) => setState(() => _studyDays = on ? 3 : null),
                      ),
                    ]),
                    if (_studyDays != null) ...[
                      const SizedBox(height: HallySpace.sm),
                      Wrap(spacing: HallySpace.sm, children: [
                        for (final d in examStudyDayChoices)
                          ChoiceChip(
                            key: Key('exam.studyDays.$d'),
                            label: Text(d == 7 ? l10n.examsStudyWeek : l10n.examsDaysLeft(d)),
                            selected: _studyDays == d,
                            onSelected: (_) => setState(() => _studyDays = d),
                          ),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: HallySpace.md),
            FilledButton(
              key: const Key('exam.save'),
              onPressed: _busy || _childId == null || typed.isEmpty ? null : _save,
              child: Text(widget.exam == null ? l10n.examsSave : l10n.examsSaveEdit),
            ),
            if (widget.exam == null) ...[
              const SizedBox(height: HallySpace.xs),
              TextButton.icon(
                key: const Key('exam.scan'),
                onPressed: () {
                  Navigator.of(context).pop();
                  showCaptureSheet(context, ref);
                },
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: Text(l10n.examsScan),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Nasıl geçti?": how it went, an optional score and optional cherries (given once). Parents only.
class ExamResultScreen extends ConsumerStatefulWidget {
  const ExamResultScreen({super.key, required this.examId});

  final String examId;

  @override
  ConsumerState<ExamResultScreen> createState() => _ExamResultScreenState();
}

final _examProvider = FutureProvider.autoDispose.family<Exam, (String, String)>((ref, key) => ref.watch(examsRepositoryProvider).get(key.$1, key.$2));

class _ExamResultScreenState extends ConsumerState<ExamResultScreen> {
  String? _outcome;
  final _score = TextEditingController();
  bool _give = true;
  int _cherries = 5;
  bool _seeded = false;
  bool _busy = false;

  @override
  void dispose() {
    _score.dispose();
    super.dispose();
  }

  void _seed(Exam e) {
    if (_seeded) return;
    _seeded = true;
    _outcome = e.outcome;
    if (e.score != null) _score.text = '${e.score}';
    if (e.cherries > 0) _cherries = e.cherries;
  }

  Future<void> _save(String familyId, Exam exam) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_outcome == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.examsPickOutcome)));
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(examsRepositoryProvider).result(familyId, exam.id,
          outcome: _outcome!, score: int.tryParse(_score.text.trim()), cherries: exam.cherries > 0 || !_give ? 0 : _cherries);
      HapticFeedback.mediumImpact();
      ref.invalidate(examsProvider(familyId));
      messenger.showSnackBar(SnackBar(content: Text(l10n.examsSaved)));
      if (mounted) Navigator.of(context).maybePop();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final exam = ref.watch(_examProvider((familyId, widget.examId)));
    final children = watchChildren(ref, familyId);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.examsResultTitle)),
      body: exam.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(_examProvider((familyId, widget.examId)))),
        data: (e) {
          _seed(e);
          final child = _childOf(children, e.childId);
          final given = e.cherries > 0;
          return ListView(
            padding: const EdgeInsets.all(HallySpace.md),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Row(children: [
                    ExamDateBox(date: e.date, color: child == null ? HallyColors.mist : childColor(child.color)),
                    const SizedBox(width: HallySpace.md - 4),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.subject, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        Text([e.childName, if (e.studySeconds >= 60) l10n.examsStudied(e.studySeconds ~/ 60)].join(' · '), style: theme.textTheme.bodySmall),
                      ]),
                    ),
                  ]),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.examsHowQuestion, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: HallySpace.sm),
                    Row(children: [
                      for (final o in const ['Hard', 'Good', 'Great']) ...[
                        if (o != 'Hard') const SizedBox(width: HallySpace.sm),
                        Expanded(child: _OutcomeButton(outcome: o, selected: _outcome == o, onTap: () => setState(() => _outcome = o))),
                      ],
                    ]),
                    const SizedBox(height: HallySpace.md),
                    Text(l10n.examsScore, style: theme.textTheme.labelLarge),
                    const SizedBox(height: HallySpace.xs),
                    TextField(
                      key: const Key('exam.score'),
                      controller: _score,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b)),
                      decoration: const InputDecoration(hintText: '–', suffixText: '/ 100'),
                    ),
                  ]),
                ),
              ),
              Card(
                color: HallyColors.softOf(HallyColors.cherry, b),
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const CherryIcon(size: 32),
                      const SizedBox(width: HallySpace.sm),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(given ? l10n.examsCherriesGiven(e.cherries) : l10n.examsCherries, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          Text(l10n.examsCherriesBody, style: theme.textTheme.bodySmall),
                        ]),
                      ),
                      if (!given) Switch(key: const Key('exam.give'), value: _give, onChanged: (v) => setState(() => _give = v)),
                    ]),
                    if (!given && _give) ...[
                      const SizedBox(height: HallySpace.sm),
                      Wrap(spacing: HallySpace.sm, children: [
                        for (final n in const [3, 5, 10, 20])
                          ChoiceChip(
                            key: Key('exam.cherries.$n'),
                            label: Text('$n'),
                            avatar: n == _cherries ? const CherryIcon(size: 16) : null,
                            selected: _cherries == n,
                            onSelected: (_) => setState(() => _cherries = n),
                          ),
                      ]),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: HallySpace.sm),
              FilledButton(
                key: const Key('exam.saveResult'),
                onPressed: _busy || e.upcoming && e.daysLeft > 0 ? null : () => _save(familyId, e),
                child: Text(l10n.examsSaveEdit),
              ),
              const SizedBox(height: HallySpace.sm),
              Text(l10n.examsPrivate, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ],
          );
        },
      ),
    );
  }
}

class _OutcomeButton extends StatelessWidget {
  const _OutcomeButton({required this.outcome, required this.selected, required this.onTap});

  final String outcome;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    return InkWell(
      key: Key('exam.outcome.$outcome'),
      borderRadius: BorderRadius.circular(HallyRadius.md),
      onTap: onTap,
      child: AnimatedContainer(
        duration: HallyMotion.fast,
        height: 64,
        decoration: BoxDecoration(
          color: selected ? HallyColors.softOf(HallyColors.mint, b) : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(HallyRadius.md),
          border: Border.all(color: selected ? HallyColors.accent(HallyColors.mint, b) : theme.colorScheme.outlineVariant, width: 1.5),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(examOutcomeEmoji(outcome), style: const TextStyle(fontSize: 22)),
          Text(examOutcomeLabel(l10n, outcome), style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// In the calendar: "📚 Çalışma zamanı · Matematik" on each study evening before an exam, with "Başlat" today.
class ExamStudyRows extends ConsumerWidget {
  const ExamStudyRows({super.key, required this.familyId, required this.day, this.childId});

  final String familyId;
  final DateTime day;
  final String? childId;

  Future<void> _start(BuildContext context, WidgetRef ref, Exam e) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(examsRepositoryProvider).startStudy(familyId, e.childId, e.id);
      ref.invalidate(studyStatusProvider(familyId));
      messenger.showSnackBar(SnackBar(
        content: Text(l10n.examsStudyStarted(e.childName)),
        action: SnackBarAction(label: l10n.studyTitle, onPressed: () => context.push('/study')),
      ));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final exams = ref.watch(examsProvider(familyId)).valueOrNull ?? const [];
    final rows = exams.where((e) => e.isStudyDay(day) && (childId == null || e.childId == childId)).toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final children = watchChildren(ref, familyId);
    final today = DateUtils.isSameDay(day, DateTime.now());
    final caregiver = ref.watch(isCaregiverProvider);
    return Column(children: [
      for (final e in rows)
        Card(
          key: Key('studyRow.${e.id}'),
          child: ListTile(
            leading: const HallyIconBadge(icon: Icons.menu_book_rounded, color: HallyModule.study),
            title: Row(children: [
              Expanded(child: Text(l10n.examsStudyRow(e.subject), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
              if (_childOf(children, e.childId) case final c?) ChildBadge(child: c, size: 20),
            ]),
            subtitle: Text(l10n.examsStudyRowSub(e.childName, DateUtils.dateOnly(e.date).difference(DateUtils.dateOnly(day)).inDays)),
            trailing: today && !caregiver
                ? FilledButton(
                    key: Key('studyRow.${e.id}.start'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () => _start(context, ref, e), child: Text(l10n.examsStart))
                : null,
            onTap: caregiver ? null : () => showExamEditor(context, ref, familyId: familyId, exam: e),
          ),
        ),
    ]);
  }
}
