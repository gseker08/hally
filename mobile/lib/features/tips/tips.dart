import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exams/exams.dart' show examsRepositoryProvider;

/// One "Hally fark etti" line (server: TipsService). Worked out from the family's data on every read; no AI.
class Tip {
  const Tip({
    required this.key,
    required this.kind,
    required this.emoji,
    required this.text,
    required this.actionLabel,
    required this.action,
    this.childId,
    this.examId,
    this.minutes,
    this.currentMinutes,
    this.restoreOn,
    this.route,
    this.detail,
  });

  factory Tip.fromJson(Map<String, dynamic> j) => Tip(
        key: j['key'] as String,
        kind: j['kind'] as String,
        emoji: j['emoji'] as String? ?? '💡',
        text: j['text'] as String,
        actionLabel: j['actionLabel'] as String,
        action: j['action'] as String,
        childId: j['childId'] as String?,
        examId: j['examId'] as String?,
        minutes: j['minutes'] as int?,
        currentMinutes: j['currentMinutes'] as int?,
        restoreOn: j['restoreOn'] == null ? null : DateTime.parse(j['restoreOn'] as String),
        route: j['route'] as String?,
        detail: j['detail'] as String?,
      );

  final String key;
  final String kind;
  final String emoji;
  final String text;
  final String actionLabel;

  /// screenLimit, bedtimeEarlier, startStudy or route.
  final String action;
  final String? childId;
  final String? examId;
  final int? minutes;
  final int? currentMinutes;
  final DateTime? restoreOn;
  final String? route;
  final String? detail;
}

class TipSettings {
  const TipSettings({required this.enabled, required this.hidden, required this.reportDay, required this.reportTime, required this.canGetReport});

  factory TipSettings.fromJson(Map<String, dynamic> j) => TipSettings(
        enabled: j['enabled'] as bool? ?? true,
        hidden: j['hidden'] as int? ?? 0,
        reportDay: j['reportDay'] as String? ?? 'Sunday',
        reportTime: j['reportTime'] as String?,
        canGetReport: j['canGetReport'] as bool? ?? false,
      );

  final bool enabled;
  final int hidden;

  /// Sunday (evening, this week) or Monday (morning, last week).
  final String reportDay;

  /// "HH:mm", or null when the weekly report notification is off.
  final String? reportTime;
  final bool canGetReport;
}

abstract interface class TipsRepository {
  Future<List<Tip>> list(String familyId);
  Future<void> dismiss(String familyId, String key, {required bool forever});
  Future<TipSettings> settings(String familyId);
  Future<TipSettings> saveSettings(String familyId, {required bool enabled, required String reportDay, String? reportTime});
  Future<TipSettings> restoreHidden(String familyId);
  Future<void> screenLimit(String familyId, String childId, int minutes, DateTime? restoreOn);
  Future<void> bedtimeEarlier(String familyId, String childId, int minutes);
}

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class ApiTipsRepository implements TipsRepository {
  ApiTipsRepository(this._api);

  final ApiClient _api;

  String _base(String familyId) => '/api/v1/families/$familyId/tips';

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<List<Tip>> list(String familyId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>(_base(familyId));
        return [for (final t in res.data ?? const []) Tip.fromJson(t as Map<String, dynamic>)];
      });

  @override
  Future<void> dismiss(String familyId, String key, {required bool forever}) =>
      _call(() => _api.dio.post<dynamic>('${_base(familyId)}/dismiss', data: {'key': key, 'forever': forever}));

  @override
  Future<TipSettings> settings(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('${_base(familyId)}/settings');
        return TipSettings.fromJson(res.data!);
      });

  @override
  Future<TipSettings> saveSettings(String familyId, {required bool enabled, required String reportDay, String? reportTime}) => _call(() async {
        final res = await _api.dio
            .put<Map<String, dynamic>>('${_base(familyId)}/settings', data: {'enabled': enabled, 'reportDay': reportDay, 'reportTime': reportTime});
        return TipSettings.fromJson(res.data!);
      });

  @override
  Future<TipSettings> restoreHidden(String familyId) => _call(() async {
        final res = await _api.dio.delete<Map<String, dynamic>>('${_base(familyId)}/dismissed');
        return TipSettings.fromJson(res.data!);
      });

  @override
  Future<void> screenLimit(String familyId, String childId, int minutes, DateTime? restoreOn) =>
      _call(() => _api.dio.post<dynamic>('${_base(familyId)}/screen-limit',
          data: {'childId': childId, 'minutes': minutes, 'restoreOn': restoreOn == null ? null : _day(restoreOn)}));

  @override
  Future<void> bedtimeEarlier(String familyId, String childId, int minutes) =>
      _call(() => _api.dio.post<dynamic>('${_base(familyId)}/bedtime-earlier', data: {'childId': childId, 'minutes': minutes}));
}

final tipsRepositoryProvider = Provider<TipsRepository>((ref) => ApiTipsRepository(ref.watch(apiClientProvider)));

final tipsProvider = FutureProvider.autoDispose.family<List<Tip>, String>((ref, familyId) => ref.watch(tipsRepositoryProvider).list(familyId));

final tipSettingsProvider = FutureProvider.autoDispose.family<TipSettings, String>((ref, familyId) => ref.watch(tipsRepositoryProvider).settings(familyId));

/// Today: "💡 Hally fark etti", one tip at a time (swipe for up to three), with its action, "Sonra" and ✕.
/// Shows nothing while loading, on errors or when there is nothing to say.
class TodayTipCard extends ConsumerStatefulWidget {
  const TodayTipCard({super.key, required this.familyId});

  final String familyId;

  @override
  ConsumerState<TodayTipCard> createState() => _TodayTipCardState();
}

class _TodayTipCardState extends ConsumerState<TodayTipCard> {
  final _pages = PageController();
  int _page = 0;

  /// Hidden right away on this screen, before the list reloads.
  final _gone = <String>{};

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _dismiss(Tip tip, {required bool forever}) async {
    setState(() => _gone.add(tip.key));
    try {
      await ref.read(tipsRepositoryProvider).dismiss(widget.familyId, tip.key, forever: forever);
    } catch (_) {
      // Best effort: it is gone from this screen either way.
    }
  }

  Future<void> _act(Tip tip) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (tip.action) {
        case 'screenLimit':
          final done = await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => ScreenLimitSheet(familyId: widget.familyId, tip: tip),
          );
          if (done == true) {
            setState(() => _gone.add(tip.key));
            ref.invalidate(tipsProvider(widget.familyId));
          }
        case 'bedtimeEarlier':
          await ref.read(tipsRepositoryProvider).bedtimeEarlier(widget.familyId, tip.childId!, tip.minutes ?? 20);
          await _dismiss(tip, forever: true);
          messenger.showSnackBar(SnackBar(content: Text(l10n.tipBedtimeDone(tip.minutes ?? 20))));
        case 'startStudy':
          await ref.read(examsRepositoryProvider).startStudy(widget.familyId, tip.childId!, tip.examId!);
          if (mounted) context.push('/study');
        default:
          if (tip.route case final route?) context.push(route);
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tips = [
      for (final t in ref.watch(tipsProvider(widget.familyId)).valueOrNull ?? const <Tip>[])
        if (!_gone.contains(t.key)) t,
    ];
    if (tips.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? HallyColors.cherryStrongDark : HallyColors.cherryStrong;
    final page = _page.clamp(0, tips.length - 1);

    Widget card(Tip tip) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('💡 ', style: theme.textTheme.labelLarge),
                Expanded(
                  child: Text(l10n.tipHeader, style: theme.textTheme.labelLarge?.copyWith(color: accent, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  key: Key('tip.dismiss.${tip.kind}'),
                  visualDensity: VisualDensity.compact,
                  tooltip: l10n.tipDismiss,
                  onPressed: () => _dismiss(tip, forever: true),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
            Text('${tip.emoji} ${tip.text}',
                maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
            const Spacer(),
            Row(
              children: [
                Flexible(
                  child: FilledButton(
                    key: Key('tip.action.${tip.kind}'),
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => _act(tip),
                    child: Text(tip.actionLabel, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: HallySpace.sm),
                TextButton(
                  key: Key('tip.later.${tip.kind}'),
                  onPressed: () => _dismiss(tip, forever: false),
                  child: Text(l10n.tipLater),
                ),
              ],
            ),
          ],
        );

    return Padding(
      padding: const EdgeInsets.only(bottom: HallySpace.md - 2),
      child: Container(
        key: const Key('today.tip'),
        height: 168,
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.xs, HallySpace.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(HallyRadius.lg),
          border: Border.all(color: dark ? HallyColors.powderPastelDark : HallyColors.powderPastel, width: 1.5),
        ),
        child: Stack(
          children: [
            PageView(
              controller: _pages,
              onPageChanged: (p) => setState(() => _page = p),
              children: [for (final t in tips) Padding(padding: const EdgeInsets.only(right: HallySpace.sm), child: card(t))],
            ),
            if (tips.length > 1)
              Positioned(
                right: 48,
                top: 20,
                child: Row(
                  children: [
                    for (var i = 0; i < tips.length; i++)
                      AnimatedContainer(
                        duration: HallyMotion.fast,
                        margin: const EdgeInsets.only(left: 4),
                        width: i == page ? 16 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == page ? HallyColors.cherry : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(3),
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

/// "Ela'nın ekran süresi": pick a daily limit; optionally the old one comes back after the exams.
class ScreenLimitSheet extends ConsumerStatefulWidget {
  const ScreenLimitSheet({super.key, required this.familyId, required this.tip});

  final String familyId;
  final Tip tip;

  @override
  ConsumerState<ScreenLimitSheet> createState() => _ScreenLimitSheetState();
}

class _ScreenLimitSheetState extends ConsumerState<ScreenLimitSheet> {
  late int _minutes = widget.tip.minutes ?? 60;
  bool _restore = true;
  bool _saving = false;

  Future<void> _apply() async {
    setState(() => _saving = true);
    try {
      await ref.read(tipsRepositoryProvider).screenLimit(widget.familyId, widget.tip.childId!, _minutes, _restore ? widget.tip.restoreOn : null);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tip = widget.tip;
    final restoreOn = tip.restoreOn;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.tipScreenTitle, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            if (tip.detail case final detail?) ...[
              const SizedBox(height: 4),
              Text(detail, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: HallySpace.md),
            Text(l10n.tipScreenDaily, style: theme.textTheme.labelLarge),
            const SizedBox(height: HallySpace.sm),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.sm,
              children: [
                for (final m in const [45, 60, 90])
                  ChoiceChip(
                    key: Key('tip.screen.$m'),
                    label: Text(l10n.tipMinutes(m)),
                    selected: _minutes == m,
                    onSelected: (_) => setState(() => _minutes = m),
                  ),
                if (tip.currentMinutes case final now?) Chip(label: Text(l10n.tipScreenNow(now))),
              ],
            ),
            if (restoreOn != null) ...[
              const SizedBox(height: HallySpace.md),
              SwitchListTile(
                key: const Key('tip.screen.restore'),
                contentPadding: EdgeInsets.zero,
                value: _restore,
                onChanged: (v) => setState(() => _restore = v),
                title: Text(l10n.tipScreenRestore),
                subtitle: Text(tip.currentMinutes == null
                    ? l10n.tipScreenRestoreNone(MaterialLocalizations.of(context).formatMediumDate(restoreOn))
                    : l10n.tipScreenRestoreBody(_weekday(restoreOn, locale), tip.currentMinutes!)),
              ),
            ],
            const SizedBox(height: HallySpace.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('tip.screen.apply'),
                onPressed: _saving ? null : _apply,
                child: Text(l10n.tipApply),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _weekday(DateTime d, String locale) {
    const tr = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];
    const en = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return (locale.startsWith('en') ? en : tr)[d.weekday - 1];
  }
}

/// Profile → "İpuçları ve rapor": tips on/off, bring back hidden ones, and the weekly report's day and time.
class TipsSettingsScreen extends ConsumerWidget {
  const TipsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final settings = ref.watch(tipSettingsProvider(familyId));
    final repo = ref.read(tipsRepositoryProvider);

    Future<void> save(Future<TipSettings> Function() call) async {
      try {
        await call();
        ref.invalidate(tipSettingsProvider(familyId));
        ref.invalidate(tipsProvider(familyId));
      } catch (_) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.tipSettingsTitle)),
      body: settings.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(tipSettingsProvider(familyId))),
        data: (s) {
          Future<void> report({String? day, String? time, bool clear = false}) =>
              save(() => repo.saveSettings(familyId, enabled: s.enabled, reportDay: day ?? s.reportDay, reportTime: clear ? null : (time ?? s.reportTime)));
          final defaultTime = s.reportDay == 'Monday' ? '08:00' : '19:00';
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const Key('tips.enabled'),
                      value: s.enabled,
                      onChanged: (v) => save(() => repo.saveSettings(familyId, enabled: v, reportDay: s.reportDay, reportTime: s.reportTime)),
                      title: Text(l10n.tipSettingsTips),
                      subtitle: Text(l10n.tipSettingsTipsBody),
                    ),
                    ListTile(
                      key: const Key('tips.hidden'),
                      title: Text(l10n.tipSettingsHidden),
                      subtitle: Text(l10n.tipSettingsHiddenBody(s.hidden)),
                      trailing: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: s.hidden == 0 ? null : () => save(() => repo.restoreHidden(familyId)),
                        child: Text(l10n.tipSettingsRestore),
                      ),
                    ),
                  ],
                ),
              ),
              if (s.canGetReport) ...[
                const SizedBox(height: HallySpace.md),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      SwitchListTile(
                        key: const Key('tips.report'),
                        value: s.reportTime != null,
                        onChanged: (v) => v ? report(time: defaultTime) : report(clear: true),
                        title: Text(l10n.tipSettingsReport),
                        subtitle: Text(l10n.tipSettingsReportBody),
                      ),
                      if (s.reportTime != null) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.md, HallySpace.xs),
                          child: SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<String>(
                              key: const Key('tips.reportDay'),
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: 'Sunday', label: Text(l10n.tipSettingsSundayEvening)),
                                ButtonSegment(value: 'Monday', label: Text(l10n.tipSettingsMondayMorning)),
                              ],
                              selected: {s.reportDay},
                              onSelectionChanged: (v) => report(day: v.first, time: v.first == 'Monday' ? '08:00' : '19:00'),
                            ),
                          ),
                        ),
                        ListTile(
                          key: const Key('tips.reportTime'),
                          title: Text(l10n.tipSettingsReportTime),
                          trailing: Text(s.reportTime!, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          onTap: () async {
                            final parts = s.reportTime!.split(':');
                            final picked =
                                await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])));
                            if (picked == null) return;
                            await report(time: '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: HallySpace.md),
              Text(l10n.tipSettingsFootnote,
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }
}
