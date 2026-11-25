import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'points_repository.dart';

/// Chore stars for one child at a time: balance, today's chores to tick, rewards to spend stars on.
class PointsScreen extends ConsumerStatefulWidget {
  const PointsScreen({super.key});

  @override
  ConsumerState<PointsScreen> createState() => _PointsScreenState();
}

class _PointsScreenState extends ConsumerState<PointsScreen> {
  String? _childId;
  bool _busy = false;

  Future<void> _act(String familyId, Future<void> Function(PointsRepository repo) action) async {
    setState(() => _busy = true);
    try {
      await action(ref.read(pointsRepositoryProvider));
      ref.invalidate(pointsBoardProvider(familyId));
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        final text = e is ApiException && e.code == 'points.not_enough' ? l10n.pointsNotEnough : l10n.errorGeneric;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final board = ref.watch(pointsBoardProvider(familyId));
    final child = children.where((c) => c.id == _childId).firstOrNull ?? children.firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pointsTitle),
        actions: [
          if (child != null)
            IconButton(
              key: const Key('points.history'),
              tooltip: l10n.pointsHistory,
              icon: const Icon(Icons.history_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PointsHistoryScreen(familyId: familyId, child: child))),
            ),
        ],
      ),
      floatingActionButton: children.isEmpty || ref.watch(isCaregiverProvider)
          ? null
          : FloatingActionButton.extended(
              key: const Key('points.add'),
              onPressed: () async {
                if (await showAddPointsItemSheet(context, familyId: familyId, children: children) == true) ref.invalidate(pointsBoardProvider(familyId));
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.pointsAdd),
            ),
      body: child == null
          ? HallyEmptyState(icon: Icons.star_rounded, title: l10n.pointsTitle, body: l10n.pointsNoChildren)
          : board.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(pointsBoardProvider(familyId))),
              data: (b) {
                final mine = b.of(child.id);
                final chores = b.chores.where((c) => c.isFor(child.id)).toList();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
                  children: [
                    if (children.length > 1)
                      Wrap(
                        spacing: HallySpace.sm,
                        children: [
                          for (final c in children)
                            ChoiceChip(
                              key: Key('points.child.${c.id}'),
                              avatar: ChildBadge(child: c, size: 22),
                              label: Text(c.firstName),
                              selected: c.id == child.id,
                              onSelected: (_) => setState(() => _childId = c.id),
                            ),
                        ],
                      ),
                    const SizedBox(height: HallySpace.sm),
                    Card(
                      color: HallyColors.softOf(HallyModule.rewards, Theme.of(context).brightness),
                      child: Padding(
                        padding: const EdgeInsets.all(HallySpace.lg),
                        child: Row(
                          children: [
                            const CherryIcon(size: 44),
                            const SizedBox(width: HallySpace.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(l10n.pointsBalance(mine.balance), key: const Key('points.balance'),
                                      style: theme.textTheme.headlineSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w800)),
                                  Text(l10n.pointsThisWeek(mine.weekPoints), style: theme.textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: HallySpace.md),
                    Text(l10n.pointsChoresToday, style: theme.textTheme.titleMedium),
                    if (chores.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: HallySpace.sm), child: Text(l10n.pointsNoChores)),
                    for (final c in chores)
                      Dismissible(
                        key: Key('points.chore.${c.id}'),
                        direction: ref.watch(isCaregiverProvider) ? DismissDirection.none : DismissDirection.endToStart,
                        background: _deleteBackground(),
                        onDismissed: (_) => _act(familyId, (r) => r.deleteChore(familyId, c.id)),
                        child: Card(
                          child: CheckboxListTile(
                            key: Key('points.done.${c.id}'),
                            value: mine.doneToday.containsKey(c.id),
                            onChanged: _busy
                                ? null
                                : (v) => _act(familyId, (r) async {
                                      final entry = mine.doneToday[c.id];
                                      entry == null ? await r.done(familyId, child.id, c.id) : await r.undo(familyId, child.id, entry);
                                    }),
                            title: Text(c.title),
                            secondary: _Stars(c.points),
                          ),
                        ),
                      ),
                    const SizedBox(height: HallySpace.md),
                    Text(l10n.pointsRewards, style: theme.textTheme.titleMedium),
                    if (b.rewards.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: HallySpace.sm), child: Text(l10n.pointsNoRewards)),
                    for (final r in b.rewards)
                      Dismissible(
                        key: Key('points.reward.${r.id}'),
                        direction: ref.watch(isCaregiverProvider) ? DismissDirection.none : DismissDirection.endToStart,
                        background: _deleteBackground(),
                        onDismissed: (_) => _act(familyId, (repo) => repo.deleteReward(familyId, r.id)),
                        child: Card(
                          child: ListTile(
                            leading: _Stars(r.cost),
                            title: Text(r.title),
                            subtitle: mine.balance < r.cost ? Text(l10n.pointsMissing(r.cost - mine.balance)) : null,
                            trailing: ref.watch(isCaregiverProvider) ? null : FilledButton(
                              key: Key('points.redeem.${r.id}'),
                              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                              onPressed: _busy || mine.balance < r.cost ? null : () => _act(familyId, (repo) => repo.redeem(familyId, child.id, r.id)),
                              child: Text(l10n.pointsRedeem),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _deleteBackground() => Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: HallySpace.lg),
        child: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
}

class _Stars extends StatelessWidget {
  const _Stars(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CherryIcon(size: 20),
          Text('$count', style: Theme.of(context).textTheme.titleSmall),
        ],
      );
}

/// A child's star ledger, newest first, with undo.
class PointsHistoryScreen extends ConsumerWidget {
  const PointsHistoryScreen({super.key, required this.familyId, required this.child});

  final String familyId;
  final ChildProfile child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final key = (familyId, child.id);
    final history = ref.watch(pointsHistoryProvider(key));
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Scaffold(
      appBar: AppBar(title: Text('${child.firstName} · ${l10n.pointsHistory}')),
      body: history.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(pointsHistoryProvider(key))),
        data: (entries) => entries.isEmpty
            ? HallyEmptyState(icon: Icons.star_outline_rounded, title: l10n.pointsHistory, body: l10n.pointsNoHistory)
            : ListView(
                padding: const EdgeInsets.all(HallySpace.md),
                children: [
                  for (final e in entries)
                    ListTile(
                      key: Key('points.entry.${e.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(e.kind == 'Reward' ? Icons.card_giftcard_rounded : Icons.check_circle_rounded,
                          color: e.kind == 'Reward' ? HallyColors.rose : HallyColors.mintDeep),
                      title: Text(e.kind == 'Mood' ? l10n.moodCherryTitle : e.title),
                      subtitle: Text([DateFormat.MMMd(locale).add_Hm().format(e.at), if (e.byName != null) e.byName!].join(' · ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(e.points > 0 ? '+${e.points}' : '${e.points}', style: Theme.of(context).textTheme.titleMedium),
                          if (!ref.watch(isCaregiverProvider))
                          IconButton(
                            key: Key('points.undo.${e.id}'),
                            tooltip: l10n.pointsUndo,
                            icon: const Icon(Icons.undo_rounded),
                            onPressed: () async {
                              await ref.read(pointsRepositoryProvider).undo(familyId, child.id, e.id);
                              ref.invalidate(pointsHistoryProvider(key));
                              ref.invalidate(pointsBoardProvider(familyId));
                            },
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

/// Add a chore (stars, for one child or all) or a reward (cost).
Future<bool?> showAddPointsItemSheet(BuildContext context, {required String familyId, required List<ChildProfile> children}) => showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AddItemSheet(familyId: familyId, children: children),
    );

class _AddItemSheet extends ConsumerStatefulWidget {
  const _AddItemSheet({required this.familyId, required this.children});

  final String familyId;
  final List<ChildProfile> children;

  @override
  ConsumerState<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends ConsumerState<_AddItemSheet> {
  bool _reward = false;
  int _stars = 5;

  /// Extra screen minutes this reward gives (null: an ordinary reward).
  int? _screenMinutes;
  String? _childId;
  final _title = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = l10n.pointsTitleRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(pointsRepositoryProvider);
      _reward
          ? await repo.addReward(widget.familyId, title: title, cost: _stars, screenMinutes: _screenMinutes)
          : await repo.addChore(widget.familyId, title: title, points: _stars, childId: _childId);
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final max = _reward ? 1000 : 50;
    final step = _reward ? 5 : 1;
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: false, label: Text(l10n.pointsChore), icon: const Icon(Icons.check_circle_outline_rounded)),
              ButtonSegment(value: true, label: Text(l10n.pointsReward), icon: const Icon(Icons.card_giftcard_rounded)),
            ],
            selected: {_reward},
            onSelectionChanged: (v) => setState(() {
              _reward = v.first;
              _stars = _reward ? 20 : 5;
              _screenMinutes = null;
            }),
          ),
          const SizedBox(height: HallySpace.md),
          TextField(
            key: const Key('points.title'),
            controller: _title,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: _reward ? l10n.pointsRewardHint : l10n.pointsChoreHint),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                key: const Key('points.minus'),
                onPressed: _stars > 1 ? () => setState(() => _stars = (_stars - step).clamp(1, max)) : null,
                icon: const Icon(Icons.remove_rounded),
              ),
              SizedBox(
                width: 110,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const CherryIcon(size: 24),
                  Text('$_stars', key: const Key('points.value'), style: theme.textTheme.headlineSmall),
                ]),
              ),
              IconButton.filledTonal(
                key: const Key('points.plus'),
                onPressed: _stars < max ? () => setState(() => _stars = (_stars + step).clamp(1, max)) : null,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          if (_reward) ...[
            SwitchListTile(
              key: const Key('points.screen'),
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.smartphone_rounded),
              title: Text(l10n.pointsScreenReward),
              subtitle: Text(l10n.pointsScreenRewardBody),
              value: _screenMinutes != null,
              onChanged: (v) => setState(() {
                _screenMinutes = v ? 15 : null;
                if (v && _title.text.trim().isEmpty) _title.text = l10n.pointsScreenMinutes(15);
              }),
            ),
            if (_screenMinutes != null)
              Wrap(spacing: HallySpace.sm, children: [
                for (final m in const [15, 30, 60])
                  ChoiceChip(
                    label: Text(l10n.kidMinutes(m)),
                    selected: _screenMinutes == m,
                    onSelected: (_) => setState(() {
                      if (_title.text == l10n.pointsScreenMinutes(_screenMinutes!)) _title.text = l10n.pointsScreenMinutes(m);
                      _screenMinutes = m;
                    }),
                  ),
              ]),
          ],
          if (!_reward && widget.children.length > 1) ...[
            const SizedBox(height: HallySpace.sm),
            Wrap(
              spacing: HallySpace.sm,
              children: [
                ChoiceChip(label: Text(l10n.pointsEveryone), selected: _childId == null, onSelected: (_) => setState(() => _childId = null)),
                for (final c in widget.children)
                  ChoiceChip(label: Text(c.firstName), selected: _childId == c.id, onSelected: (_) => setState(() => _childId = c.id)),
              ],
            ),
          ],
          if (_error != null) Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error)),
          const SizedBox(height: HallySpace.md),
          FilledButton(key: const Key('points.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
        ],
      ),
    );
  }
}
