import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart' show childColor;
import 'family_goal.dart';

/// The big goal panel: reward, cherries so far and the bar. Shared by parents and the child's phone.
class GoalPanel extends StatelessWidget {
  const GoalPanel({super.key, required this.goal});

  final FamilyGoal goal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final deep = HallyColors.accent(HallyColors.cherry, b);
    return Container(
      key: const Key('goal.panel'),
      padding: const EdgeInsets.all(HallySpace.lg),
      decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.cherry, b), borderRadius: BorderRadius.circular(HallyRadius.lg)),
      child: Column(children: [
        Text(l10n.goalThisWeek, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800, color: deep, letterSpacing: 0.3)),
        const SizedBox(height: 6),
        Text('${goal.rewardEmoji} ${goal.rewardTitle}',
            textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: HallySpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const CherryIcon(size: 30),
            const SizedBox(width: 6),
            Text('${goal.total}', key: const Key('goal.total'), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: deep)),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(' / ${goal.target}',
                  style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: HallySpace.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: goal.progress,
            minHeight: 12,
            color: deep,
            backgroundColor: theme.colorScheme.surface,
          ),
        ),
        const SizedBox(height: HallySpace.sm),
        Text(goal.reached ? l10n.goalReached : l10n.goalMore(goal.missing),
            key: const Key('goal.status'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// "Kim ne kattı": everyone's share, in the family's own order (never ranked).
class GoalContributors extends StatelessWidget {
  const GoalContributors({super.key, required this.goal});

  final FamilyGoal goal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final most = goal.contributors.fold<int>(1, (m, c) => c.cherries > m ? c.cherries : m);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.xs),
        child: Column(children: [
          for (final c in goal.contributors)
            Padding(
              key: Key('goal.who.${c.id}'),
              padding: const EdgeInsets.symmetric(vertical: HallySpace.sm),
              child: Row(children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: HallyColors.softOf(c.isChild && c.color != null ? childColor(c.color!) : HallyColors.powder, b),
                  child: Text(c.name.isEmpty ? '?' : c.name.characters.first.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: HallySpace.sm + 4),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: c.cherries / most,
                        minHeight: 6,
                        color: HallyColors.accent(HallyColors.cherry, b),
                        backgroundColor: HallyColors.softOf(HallyColors.cherry, b),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(width: HallySpace.sm + 4),
                Text('${c.cherries}', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(width: 2),
                const CherryIcon(size: 16),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// The whole goal view under the app bar (parents and child).
class GoalBody extends StatelessWidget {
  const GoalBody({super.key, required this.goal});

  final FamilyGoal goal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.md, HallySpace.xl),
      children: [
        GoalPanel(goal: goal),
        HallySectionHeader(title: l10n.goalWho),
        GoalContributors(goal: goal),
        const SizedBox(height: HallySpace.md),
        Text(l10n.goalNote, textAlign: TextAlign.center, style: muted),
        const SizedBox(height: 4),
        Text(l10n.goalAdultNote, textAlign: TextAlign.center, style: muted),
      ],
    );
  }
}

/// Parents: Family → Aile görevi, and a tap on the Today card.
class FamilyGoalScreen extends ConsumerWidget {
  const FamilyGoalScreen({super.key, this.familyId});

  /// Null (from a notification): the user's family.
  final String? familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = familyId ?? ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (id == null) return const Scaffold(body: HallyLoading());
    return _FamilyGoalView(familyId: id);
  }
}

class _FamilyGoalView extends ConsumerWidget {
  const _FamilyGoalView({required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(familyGoalProvider(familyId));
    final goal = state.valueOrNull?.goal;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.goalTitle),
        actions: [
          if (goal != null) ...[
            Center(child: Text(l10n.goalDaysLeft(goal.daysLeft), style: Theme.of(context).textTheme.labelLarge)),
            PopupMenuButton<String>(
              key: const Key('goal.menu'),
              onSelected: (v) => v == 'edit' ? _edit(context, ref, state.value!) : _end(context, ref),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(l10n.goalEdit)),
                PopupMenuItem(key: const Key('goal.end'), value: 'end', child: Text(l10n.goalEnd)),
              ],
            ),
          ],
        ],
      ),
      body: state.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(familyGoalProvider(familyId))),
        data: (s) => s.goal == null
            ? HallyEmptyState(
                icon: Icons.flag_rounded,
                title: l10n.goalEmptyTitle,
                body: l10n.goalEmptyBody,
                action: FilledButton(key: const Key('goal.start'), onPressed: () => _edit(context, ref, s), child: Text(l10n.goalStart)),
              )
            : RefreshIndicator(onRefresh: () => ref.refresh(familyGoalProvider(familyId).future), child: GoalBody(goal: s.goal!)),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, FamilyGoalState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final r = await showModalBottomSheet<({String title, String emoji, int target, bool repeat})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GoalSetupSheet(state: state),
    );
    if (r == null) return;
    try {
      await ref.read(familyGoalRepositoryProvider).set(familyId, rewardTitle: r.title, rewardEmoji: r.emoji, target: r.target, repeat: r.repeat);
      ref.invalidate(familyGoalProvider(familyId));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  Future<void> _end(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.goalEndConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
          FilledButton(key: const Key('goal.end.confirm'), onPressed: () => Navigator.pop(context, true), child: Text(l10n.goalEnd)),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(familyGoalRepositoryProvider).end(familyId);
    ref.invalidate(familyGoalProvider(familyId));
  }
}

/// "Bu haftanın hedefi": reward, target (around Hally's suggestion) and repeat.
class GoalSetupSheet extends StatefulWidget {
  const GoalSetupSheet({super.key, required this.state});

  final FamilyGoalState state;

  @override
  State<GoalSetupSheet> createState() => _GoalSetupSheetState();
}

class _GoalSetupSheetState extends State<GoalSetupSheet> {
  final _own = TextEditingController();
  late List<int> _targets;
  String? _preset;
  late int _target;
  bool _repeat = true;

  List<(String, String)> _presets(AppLocalizations l10n) => [('🧺', l10n.goalPicnic), ('🎬', l10n.goalMovie), ('🍕', l10n.goalPizza)];

  @override
  void initState() {
    super.initState();
    final s = widget.state.suggestedTarget;
    _targets = {if (s - 40 >= 10) s - 40, s, s + 40}.toList();
    final g = widget.state.goal;
    _target = g?.target ?? s;
    if (!_targets.contains(_target)) _targets = ([..._targets, _target]..sort());
    _repeat = g?.repeat ?? true;
    if (g != null) _own.text = g.rewardTitle;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = AppLocalizations.of(context);
    final g = widget.state.goal;
    if (_preset == null) {
      final match = _presets(l10n).where((p) => g == null ? p == _presets(l10n).first : p.$2 == g.rewardTitle).firstOrNull;
      _preset = match?.$2 ?? (g == null ? null : '');
      if (match != null) _own.clear();
    }
  }

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  (String, String)? _reward(AppLocalizations l10n) {
    final p = _presets(l10n).where((p) => p.$2 == _preset).firstOrNull;
    if (p != null) return p;
    final own = _own.text.trim();
    return own.isEmpty ? null : (widget.state.goal?.rewardEmoji ?? '🎁', own);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final reward = _reward(l10n);
    Widget option((String, String) p) => Padding(
          padding: const EdgeInsets.only(bottom: HallySpace.sm),
          child: ListTile(
            key: Key('goal.reward.${p.$1}'),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.md)),
            tileColor:
                _preset == p.$2 ? HallyColors.softOf(HallyColors.cherry, theme.brightness) : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            title: Text('${p.$1} ${p.$2}'),
            trailing: _preset == p.$2 ? const Icon(Icons.check_rounded) : null,
            onTap: () => setState(() {
              _preset = p.$2;
              _own.clear();
            }),
          ),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, MediaQuery.viewInsetsOf(context).bottom + HallySpace.md),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(l10n.goalSheetTitle, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: HallySpace.md),
          Text(l10n.goalReward, style: theme.textTheme.labelLarge),
          const SizedBox(height: HallySpace.sm),
          for (final p in _presets(l10n)) option(p),
          TextField(
            key: const Key('goal.reward.own'),
            controller: _own,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l10n.goalOwnReward, prefixIcon: const Icon(Icons.add_rounded)),
            onChanged: (v) => setState(() => _preset = v.trim().isEmpty ? _preset : ''),
          ),
          Text(l10n.goalHowMany, style: theme.textTheme.labelLarge),
          const SizedBox(height: HallySpace.sm),
          Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final t in _targets)
              ChoiceChip(
                  key: Key('goal.target.$t'),
                  label: Text('$t'),
                  avatar: const CherryIcon(size: 16),
                  selected: _target == t,
                  onSelected: (_) => setState(() => _target = t)),
            if (widget.state.lastWeekTotal > 0)
              Text(l10n.goalLastWeek(widget.state.lastWeekTotal), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
          SwitchListTile(
            key: const Key('goal.repeat'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.goalRepeat),
            value: _repeat,
            onChanged: (v) => setState(() => _repeat = v),
          ),
          const SizedBox(height: HallySpace.sm),
          FilledButton(
            key: const Key('goal.save'),
            onPressed: reward == null ? null : () => Navigator.pop(context, (title: reward.$2, emoji: reward.$1, target: _target, repeat: _repeat)),
            child: Text(widget.state.goal == null ? l10n.goalLaunch : l10n.goalSave),
          ),
        ]),
      ),
    );
  }
}

/// Today (parents): the goal at a glance while one runs.
class FamilyGoalCard extends ConsumerWidget {
  const FamilyGoalCard({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(familyGoalProvider(familyId)).valueOrNull?.goal;
    if (goal == null) return const SizedBox.shrink();
    return GoalMiniCard(goal: goal, onTap: () => context.push('/family-goal?familyId=$familyId'));
  }
}

/// One line with the reward, progress and the bar; used on Today and in the child's jar tab.
class GoalMiniCard extends StatelessWidget {
  const GoalMiniCard({super.key, required this.goal, required this.onTap});

  final FamilyGoal goal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    return Card(
      key: const Key('goal.card'),
      margin: const EdgeInsets.only(bottom: HallySpace.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(goal.rewardEmoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l10n.goalTitle, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  Text(goal.rewardTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ]),
              ),
              Text(l10n.goalProgress(goal.total, goal.target), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 2),
              const CherryIcon(size: 16),
            ]),
            const SizedBox(height: HallySpace.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: goal.progress,
                minHeight: 8,
                color: HallyColors.accent(HallyColors.cherry, b),
                backgroundColor: HallyColors.softOf(HallyColors.cherry, b),
              ),
            ),
            const SizedBox(height: 6),
            Text(goal.reached ? l10n.goalReached : l10n.goalMore(goal.missing), style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}
