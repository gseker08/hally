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
import 'feeding_repository.dart';
import '../../core/locale/units.dart';

String _hm(BuildContext context, DateTime t) => DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(t);

/// "45 dk" / "2 sa 10 dk" since [t], for "how long since she ate".
String feedingAgo(DateTime t, DateTime now, {required String lang}) {
  final minutes = now.difference(t).inMinutes.clamp(0, 99999);
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final hu = durationUnits(lang).h;
  final mu = durationUnits(lang).min;
  return h == 0 ? '$m $mu' : '$h $hu $m $mu';
}

String feedingSideLabel(AppLocalizations l10n, String? side) => switch (side) {
      'Left' => l10n.feedingLeft,
      'Right' => l10n.feedingRight,
      'Both' => l10n.feedingBoth,
      _ => '',
    };

/// "Emzirme · Sol · 15 dk", "Biberon · 120 ml", "Ek gıda · Havuç püresi".
String feedingSummary(AppLocalizations l10n, FeedingEntry e, {required String lang}) => switch (e.kind) {
      'Breast' => [l10n.feedingBreast, feedingSideLabel(l10n, e.side), if (e.minutes != null) '${e.minutes} ${durationUnits(lang).min}'].join(' · '),
      'Bottle' => '${l10n.feedingBottle} · ${e.amountMl} ml',
      _ => '${l10n.feedingSolid} · ${e.food}',
    };

IconData feedingIcon(String kind) => switch (kind) {
      'Breast' => Icons.favorite_rounded,
      'Bottle' => Icons.local_drink_rounded,
      _ => Icons.restaurant_rounded,
    };


/// Last feed and today's totals for every child, with quick add buttons. Tapping a child opens the last three days.
class FeedingScreen extends ConsumerStatefulWidget {
  const FeedingScreen({super.key});

  @override
  ConsumerState<FeedingScreen> createState() => _FeedingScreenState();
}

class _FeedingScreenState extends ConsumerState<FeedingScreen> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _add(String familyId, String childId, String kind, String? nextSide) async {
    if (await showAddFeedingSheet(context, familyId: familyId, childId: childId, kind: kind, nextSide: nextSide) == true) {
      ref.invalidate(feedingStatusProvider(familyId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final status = ref.watch(feedingStatusProvider(familyId));
    final now = DateTime.now();
    final lang = langOf(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.feedingTitle)),
      body: children.isEmpty
          ? HallyEmptyState(icon: Icons.restaurant_rounded, title: l10n.feedingTitle, body: l10n.feedingNoChildren)
          : status.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(feedingStatusProvider(familyId))),
              data: (byChild) => RefreshIndicator(
                onRefresh: () => ref.refresh(feedingStatusProvider(familyId).future),
                child: ListView(
                  padding: const EdgeInsets.all(HallySpace.md),
                  children: [
                    for (final c in children)
                      Builder(builder: (context) {
                        final s = byChild[c.id];
                        final last = s?.last;
                        return Card(
                          child: InkWell(
                            key: Key('feeding.child.${c.id}'),
                            borderRadius: BorderRadius.circular(HallyRadius.lg),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FeedingHistoryScreen(familyId: familyId, child: c))),
                            child: Padding(
                              padding: const EdgeInsets.all(HallySpace.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      ChildBadge(child: c, size: 40),
                                      const SizedBox(width: HallySpace.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(c.firstName, style: theme.textTheme.titleMedium),
                                            Text(
                                              last == null
                                                  ? l10n.feedingNoRecord
                                                  : l10n.feedingLast(feedingAgo(last.at, now, lang: lang), feedingSummary(l10n, last, lang: lang)),
                                              key: Key('feeding.line.${c.id}'),
                                              style: theme.textTheme.bodySmall,
                                            ),
                                            if (s != null && s.feedsToday > 0)
                                              Text(
                                                s.bottleMlToday > 0 ? l10n.feedingTodayWithMl(s.feedsToday, s.bottleMlToday) : l10n.feedingToday(s.feedsToday),
                                                key: Key('feeding.today.${c.id}'),
                                                style: theme.textTheme.bodySmall,
                                              ),
                                            if (s?.nextSide != null)
                                              Text(l10n.feedingNextSide(feedingSideLabel(l10n, s!.nextSide)),
                                                  key: Key('feeding.next.${c.id}'), style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.mintDeep)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: HallySpace.sm),
                                  Wrap(
                                    spacing: HallySpace.sm,
                                    runSpacing: HallySpace.xs,
                                    children: [
                                      for (final (kind, label) in [('Breast', l10n.feedingBreast), ('Bottle', l10n.feedingBottle), ('Solid', l10n.feedingSolid)])
                                        OutlinedButton.icon(
                                          key: Key('feeding.add.$kind.${c.id}'),
                                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                                          onPressed: s == null ? null : () => _add(familyId, c.id, kind, s.nextSide),
                                          icon: Icon(feedingIcon(kind), size: 18),
                                          label: Text(label),
                                        ),
                                    ],
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

/// One child's last three days: totals per day and every feed.
class FeedingHistoryScreen extends ConsumerWidget {
  const FeedingHistoryScreen({super.key, required this.familyId, required this.child});

  final String familyId;
  final ChildProfile child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lang = langOf(context);
    final key = (familyId, child.id);
    final history = ref.watch(feedingHistoryProvider(key));
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Scaffold(
      appBar: AppBar(title: Text('${child.firstName} · ${l10n.feedingTitle}')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('feeding.add'),
        onPressed: () async {
          if (await showAddFeedingSheet(context, familyId: familyId, childId: child.id, kind: 'Bottle') == true) ref.invalidate(feedingHistoryProvider(key));
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.feedingAdd),
      ),
      body: history.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(feedingHistoryProvider(key))),
        data: (h) => ListView(
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
          children: [
            for (final d in h.days.reversed)
              ListTile(
                key: Key('feeding.day.${DateFormat('yyyy-MM-dd').format(d.date)}'),
                contentPadding: EdgeInsets.zero,
                title: Text(DateFormat.MMMEd(locale).format(d.date), style: theme.textTheme.titleSmall),
                subtitle: Text(d.feeds == 0
                    ? l10n.feedingNoRecord
                    : [
                        l10n.feedingToday(d.feeds),
                        if (d.breastFeeds > 0) '${l10n.feedingBreast} ${d.breastFeeds}× · ${d.breastMinutes} ${durationUnits(lang).min}',
                        if (d.bottles > 0) '${l10n.feedingBottle} ${d.bottles}× · ${d.bottleMl} ml',
                        if (d.solids > 0) '${l10n.feedingSolid} ${d.solids}×',
                      ].join(' · ')),
              ),
            const Divider(height: HallySpace.xl),
            if (h.entries.isEmpty) Text(l10n.feedingNoRecord),
            for (final e in h.entries)
              ListTile(
                key: Key('feeding.entry.${e.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(feedingIcon(e.kind), color: childColor(child.color)),
                title: Text(feedingSummary(l10n, e, lang: lang)),
                subtitle: Text([
                  '${DateFormat.MMMd(locale).format(e.at)} ${_hm(context, e.at)}',
                  if (e.byName != null) e.byName!,
                  if (e.note != null) e.note!,
                ].join(' · ')),
                trailing: IconButton(
                  key: Key('feeding.delete.${e.id}'),
                  tooltip: l10n.sleepDelete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    await ref.read(feedingRepositoryProvider).delete(familyId, child.id, e.id);
                    ref.invalidate(feedingHistoryProvider(key));
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Add a feed: kind, then side and minutes, millilitres, or what was eaten; the time defaults to now.
Future<bool?> showAddFeedingSheet(BuildContext context, {required String familyId, required String childId, required String kind, String? nextSide}) =>
    showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AddFeedingSheet(familyId: familyId, childId: childId, kind: kind, nextSide: nextSide),
    );

class _AddFeedingSheet extends ConsumerStatefulWidget {
  const _AddFeedingSheet({required this.familyId, required this.childId, required this.kind, this.nextSide});

  final String familyId;
  final String childId;
  final String kind;
  final String? nextSide;

  @override
  ConsumerState<_AddFeedingSheet> createState() => _AddFeedingSheetState();
}

class _AddFeedingSheetState extends ConsumerState<_AddFeedingSheet> {
  late String _kind = widget.kind;
  late String _side = widget.nextSide ?? 'Left';
  int _minutes = 15;
  int _ml = 120;
  final _food = TextEditingController();
  TimeOfDay? _time;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _food.dispose();
    super.dispose();
  }

  /// Today at the picked time; a time later than now was yesterday evening.
  DateTime? get _at {
    final t = _time;
    if (t == null) return null;
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (at.isAfter(now)) at = at.subtract(const Duration(days: 1));
    return at;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (_kind == 'Solid' && _food.text.trim().isEmpty) {
      setState(() => _error = l10n.feedingFoodRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(feedingRepositoryProvider).add(
            widget.familyId,
            widget.childId,
            kind: _kind,
            at: _at,
            side: _kind == 'Breast' ? _side : null,
            minutes: _kind == 'Breast' ? _minutes : null,
            amountMl: _kind == 'Bottle' ? _ml : null,
            food: _kind == 'Solid' ? _food.text.trim() : null,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l10n.errorGeneric;
        });
      }
    }
  }

  Widget _stepper(String key, String value, VoidCallback? minus, VoidCallback? plus) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filledTonal(key: Key('feeding.$key.minus'), onPressed: minus, icon: const Icon(Icons.remove_rounded)),
          SizedBox(width: 110, child: Text(value, key: Key('feeding.$key.value'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall)),
          IconButton.filledTonal(key: Key('feeding.$key.plus'), onPressed: plus, icon: const Icon(Icons.add_rounded)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lang = langOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.feedingAdd, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.sm),
          SegmentedButton<String>(
            key: const Key('feeding.kind'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'Breast', label: Text(l10n.feedingBreast), icon: Icon(feedingIcon('Breast'))),
              ButtonSegment(value: 'Bottle', label: Text(l10n.feedingBottle), icon: Icon(feedingIcon('Bottle'))),
              ButtonSegment(value: 'Solid', label: Text(l10n.feedingSolid), icon: Icon(feedingIcon('Solid'))),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: HallySpace.md),
          if (_kind == 'Breast') ...[
            Wrap(
              spacing: HallySpace.sm,
              alignment: WrapAlignment.center,
              children: [
                for (final side in ['Left', 'Right', 'Both'])
                  ChoiceChip(
                    key: Key('feeding.side.$side'),
                    label: Text(feedingSideLabel(l10n, side)),
                    selected: _side == side,
                    onSelected: (_) => setState(() => _side = side),
                  ),
              ],
            ),
            const SizedBox(height: HallySpace.sm),
            _stepper('minutes', '$_minutes ${durationUnits(lang).min}', _minutes > 1 ? () => setState(() => _minutes = (_minutes - 5).clamp(1, 120)) : null,
                _minutes < 120 ? () => setState(() => _minutes = (_minutes + 5).clamp(1, 120)) : null),
          ],
          if (_kind == 'Bottle')
            _stepper('ml', '$_ml ml', _ml > 10 ? () => setState(() => _ml -= 10) : null, _ml < 500 ? () => setState(() => _ml += 10) : null),
          if (_kind == 'Solid')
            TextField(
              key: const Key('feeding.food'),
              controller: _food,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.feedingFood),
            ),
          ListTile(
            key: const Key('feeding.time'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_rounded),
            title: Text(l10n.feedingTime),
            trailing: Text(_time == null ? l10n.feedingNow : _time!.format(context), style: theme.textTheme.titleMedium),
            onTap: () async {
              final picked = await showTimePicker(context: context, initialTime: _time ?? TimeOfDay.now());
              if (picked != null) setState(() => _time = picked);
            },
          ),
          if (_error != null) Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error)),
          const SizedBox(height: HallySpace.sm),
          FilledButton(key: const Key('feeding.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
        ],
      ),
    );
  }
}
