import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'sleep_repository.dart';

/// "1 sa 05 dk" / "1 h 05 min", "45 dk" under an hour.
String formatSleepMinutes(int minutes, {required bool turkish}) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final hu = turkish ? 'sa' : 'h';
  final mu = turkish ? 'dk' : 'min';
  if (h == 0) return '$m $mu';
  return '$h $hu ${m.toString().padLeft(2, '0')} $mu';
}

bool _tr(BuildContext context) => Localizations.localeOf(context).languageCode != 'en';
String _hm(BuildContext context, DateTime t) => DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(t);

/// Asleep / awake for every child, with one tap to switch. Tapping a child opens the week.
class SleepScreen extends ConsumerStatefulWidget {
  const SleepScreen({super.key});

  @override
  ConsumerState<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends ConsumerState<SleepScreen> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  final _busy = <String>{};

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _toggle(String familyId, String childId, bool asleep) async {
    setState(() => _busy.add(childId));
    try {
      final repo = ref.read(sleepRepositoryProvider);
      asleep ? await repo.awake(familyId, childId) : await repo.asleep(familyId, childId);
      ref.invalidate(sleepStatusProvider(familyId));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy.remove(childId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final status = ref.watch(sleepStatusProvider(familyId));
    final now = DateTime.now();
    final tr = _tr(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.sleepTitle)),
      body: children.isEmpty
          ? HallyEmptyState(icon: Icons.bedtime_outlined, title: l10n.sleepTitle, body: l10n.sleepNoChildren)
          : status.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(sleepStatusProvider(familyId))),
              data: (byChild) => RefreshIndicator(
                onRefresh: () => ref.refresh(sleepStatusProvider(familyId).future),
                child: ListView(
                  padding: const EdgeInsets.all(HallySpace.md),
                  children: [
                    for (final c in children)
                      Builder(builder: (context) {
                        final s = byChild[c.id];
                        final asleep = s?.asleep;
                        final last = s?.lastSleep;
                        final String line;
                        if (asleep != null) {
                          line = l10n.sleepAsleepFor(formatSleepMinutes(now.difference(asleep.startedAt).inMinutes, turkish: tr), _hm(context, asleep.startedAt));
                        } else if (last?.endedAt != null) {
                          line = l10n.sleepAwakeFor(formatSleepMinutes(now.difference(last!.endedAt!).inMinutes, turkish: tr), _hm(context, last.endedAt!));
                        } else {
                          line = l10n.sleepNoRecord;
                        }
                        return Card(
                          child: InkWell(
                            key: Key('sleep.child.${c.id}'),
                            borderRadius: BorderRadius.circular(HallyRadius.lg),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SleepHistoryScreen(familyId: familyId, child: c))),
                            child: Padding(
                              padding: const EdgeInsets.all(HallySpace.md),
                              child: Row(
                                children: [
                                  ChildBadge(child: c, size: 40),
                                  const SizedBox(width: HallySpace.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(c.firstName, style: theme.textTheme.titleMedium),
                                            const SizedBox(width: HallySpace.xs),
                                            Icon(asleep != null ? Icons.bedtime_rounded : Icons.wb_sunny_rounded,
                                                size: 18, color: asleep != null ? HallyModule.sleep : HallyColors.apricot),
                                          ],
                                        ),
                                        Text(line, key: Key('sleep.line.${c.id}'), style: theme.textTheme.bodySmall),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: HallySpace.sm),
                                  FilledButton.icon(
                                    key: Key('sleep.toggle.${c.id}'),
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 44),
                                      padding: const EdgeInsets.symmetric(horizontal: HallySpace.md),
                                      backgroundColor: asleep != null ? HallyColors.apricot : HallyModule.sleep,
                                    ),
                                    onPressed: _busy.contains(c.id) || s == null ? null : () => _toggle(familyId, c.id, asleep != null),
                                    icon: Icon(asleep != null ? Icons.wb_sunny_rounded : Icons.bedtime_rounded),
                                    label: Text(asleep != null ? l10n.sleepWoke : l10n.sleepFellAsleep),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
    );
  }
}

/// One child's last seven sleep days, averages and entries.
class SleepHistoryScreen extends ConsumerWidget {
  const SleepHistoryScreen({super.key, required this.familyId, required this.child});

  final String familyId;
  final ChildProfile child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tr = _tr(context);
    final key = (familyId, child.id);
    final history = ref.watch(sleepHistoryProvider(key));
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Scaffold(
      appBar: AppBar(title: Text('${child.firstName} · ${l10n.sleepTitle}')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('sleep.add'),
        onPressed: () async {
          if (await showAddSleepSheet(context, ref, familyId: familyId, childId: child.id) == true) ref.invalidate(sleepHistoryProvider(key));
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.sleepAdd),
      ),
      body: history.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(sleepHistoryProvider(key))),
        data: (h) {
          final maxMinutes = [for (final d in h.days) d.nightMinutes + d.napMinutes, 60].reduce((a, b) => a > b ? a : b);
          const barHeight = 100.0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
            children: [
              Text(l10n.sleepAverages(formatSleepMinutes(h.averageNightMinutes, turkish: tr), formatSleepMinutes(h.averageNapMinutes, turkish: tr)),
                  key: const Key('sleep.averages'), style: theme.textTheme.titleSmall),
              const SizedBox(height: HallySpace.md),
              SizedBox(
                height: barHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in h.days)
                      Expanded(
                        child: Tooltip(
                          message: '${formatSleepMinutes(d.nightMinutes, turkish: tr)} + ${formatSleepMinutes(d.napMinutes, turkish: tr)}',
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (d.napMinutes > 0)
                                Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 6),
                                  height: barHeight * d.napMinutes / maxMinutes,
                                  decoration: BoxDecoration(color: HallyColors.apricot.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(3)),
                                ),
                              Container(
                                margin: const EdgeInsets.symmetric(horizontal: 6),
                                height: d.nightMinutes == 0 ? 2 : barHeight * d.nightMinutes / maxMinutes,
                                decoration: BoxDecoration(color: childColor(child.color), borderRadius: BorderRadius.circular(3)),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(children: [
                for (final d in h.days)
                  Expanded(child: Text(DateFormat.E(locale).format(d.date), textAlign: TextAlign.center, style: theme.textTheme.labelSmall)),
              ]),
              const SizedBox(height: HallySpace.xs),
              Wrap(
                spacing: HallySpace.md,
                children: [
                  _Legend(color: childColor(child.color), label: l10n.sleepNight),
                  _Legend(color: HallyColors.apricot.withValues(alpha: 0.7), label: l10n.sleepNap),
                ],
              ),
              const Divider(height: HallySpace.xl),
              if (h.entries.isEmpty) Text(l10n.sleepNoRecord),
              for (final e in h.entries)
                ListTile(
                  key: Key('sleep.entry.${e.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(e.isNight ? Icons.nights_stay_rounded : Icons.bedtime_outlined, color: e.isNight ? childColor(child.color) : HallyColors.apricot),
                  title: Text('${DateFormat.MMMd(locale).format(e.startedAt)} · ${_hm(context, e.startedAt)} – ${e.endedAt == null ? '…' : _hm(context, e.endedAt!)}'),
                  subtitle: Text([formatSleepMinutes(e.minutes, turkish: tr), e.isNight ? l10n.sleepNight : l10n.sleepNap, if (e.note != null) e.note!].join(' · ')),
                  trailing: IconButton(
                    key: Key('sleep.delete.${e.id}'),
                    tooltip: l10n.sleepDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      await ref.read(sleepRepositoryProvider).delete(familyId, child.id, e.id);
                      ref.invalidate(sleepHistoryProvider(key));
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

/// Add a finished sleep: start and wake-up times; when the start is later than the wake-up it began the day before.
Future<bool?> showAddSleepSheet(BuildContext context, WidgetRef ref, {required String familyId, required String childId}) =>
    showModalBottomSheet<bool>(context: context, useRootNavigator: true, showDragHandle: true, isScrollControlled: true, builder: (_) => _AddSleepSheet(familyId: familyId, childId: childId));

class _AddSleepSheet extends ConsumerStatefulWidget {
  const _AddSleepSheet({required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<_AddSleepSheet> createState() => _AddSleepSheetState();
}

class _AddSleepSheetState extends ConsumerState<_AddSleepSheet> {
  TimeOfDay _start = const TimeOfDay(hour: 13, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 14, minute: 30);
  bool _yesterday = false;
  bool _busy = false;
  String? _error;

  /// The wake-up is on the chosen day (today or yesterday); a start later than it was the evening before.
  (DateTime, DateTime) get _range {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day).subtract(Duration(days: _yesterday ? 1 : 0));
    final end = day.add(Duration(hours: _end.hour, minutes: _end.minute));
    var start = day.add(Duration(hours: _start.hour, minutes: _start.minute));
    if (!start.isBefore(end)) start = start.subtract(const Duration(days: 1));
    return (start, end);
  }

  Future<void> _pick(bool start) async {
    final picked = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (picked != null) setState(() => start ? _start = picked : _end = picked);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final (start, end) = _range;
    if (end.isAfter(DateTime.now())) {
      setState(() => _error = l10n.sleepInFuture);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sleepRepositoryProvider).add(widget.familyId, widget.childId, startedAt: start, endedAt: end);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l10n.sleepAddFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (start, end) = _range;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.sleepAdd, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.sm),
          Wrap(spacing: HallySpace.sm, children: [
            ChoiceChip(label: Text(l10n.sleepToday), selected: !_yesterday, onSelected: (_) => setState(() => _yesterday = false)),
            ChoiceChip(key: const Key('sleep.yesterday'), label: Text(l10n.sleepYesterday), selected: _yesterday, onSelected: (_) => setState(() => _yesterday = true)),
          ]),
          ListTile(
            key: const Key('sleep.start'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bedtime_rounded),
            title: Text(l10n.sleepFellAsleep),
            trailing: Text(_start.format(context), style: theme.textTheme.titleMedium),
            onTap: () => _pick(true),
          ),
          ListTile(
            key: const Key('sleep.end'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.wb_sunny_rounded),
            title: Text(l10n.sleepWoke),
            trailing: Text(_end.format(context), style: theme.textTheme.titleMedium),
            onTap: () => _pick(false),
          ),
          Text(formatSleepMinutes(end.difference(start).inMinutes, turkish: _tr(context)), style: theme.textTheme.bodySmall),
          if (_error != null) Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error)),
          const SizedBox(height: HallySpace.md),
          FilledButton(key: const Key('sleep.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
        ],
      ),
    );
  }
}
