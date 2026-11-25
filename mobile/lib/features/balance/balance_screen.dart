import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'balance_repository.dart';

/// The order and colours of the stacked bar: tasks, school run, feeding, shopping, medicine.
const balanceKindColors = [HallyColors.lavender, HallyColors.sage, HallyColors.peach, HallyColors.mist, HallyColors.cherry];

/// "Bu hafta kim ne yaptı?": one stacked bar per adult of what they marked done in Hally, and a gentle nudge when one
/// parent carries most of it. Parents only.
class BalanceScreen extends ConsumerStatefulWidget {
  const BalanceScreen({super.key});

  @override
  ConsumerState<BalanceScreen> createState() => _BalanceScreenState();
}

class _BalanceScreenState extends ConsumerState<BalanceScreen> {
  BalanceRange _range = BalanceRange.thisWeek;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final key = (familyId, _range);
    final data = ref.watch(familyBalanceProvider(key));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.balanceTitle)),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(familyBalanceProvider(key).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
          children: [
            SegmentedButton<BalanceRange>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: BalanceRange.thisWeek, label: Text(l10n.balanceThisWeek, key: const Key('balance.thisWeek'))),
                ButtonSegment(value: BalanceRange.lastWeek, label: Text(l10n.balanceLastWeek, key: const Key('balance.lastWeek'))),
                ButtonSegment(value: BalanceRange.fourWeeks, label: Text(l10n.balanceFourWeeks, key: const Key('balance.fourWeeks'))),
              ],
              selected: {_range},
              onSelectionChanged: (v) => setState(() => _range = v.first),
            ),
            const SizedBox(height: HallySpace.md),
            ...data.when(
              loading: () => [const Padding(padding: EdgeInsets.all(HallySpace.xl), child: HallyLoading())],
              error: (_, __) => [HallyErrorState(onRetry: () => ref.invalidate(familyBalanceProvider(key)))],
              data: (d) => [
                _Chart(balance: d),
                if (d.suggestion != null && _range == BalanceRange.thisWeek) ...[
                  const SizedBox(height: HallySpace.md),
                  _SuggestionCard(suggestion: d.suggestion!, isMe: d.suggestion!.heavyUserId == ref.watch(meProvider).valueOrNull?.id),
                ],
                const SizedBox(height: HallySpace.md),
                Text(
                  l10n.balanceFootnote,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.balance});

  final FamilyBalance balance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final most = balance.members.fold(0, (a, m) => m.total > a ? m.total : a);
    final kinds = [l10n.balanceKindTasks, l10n.balanceKindSchoolRuns, l10n.balanceKindFeedings, l10n.balanceKindShopping, l10n.balanceKindMedications];

    return Card(
      key: const Key('balance.chart'),
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (balance.total == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: HallySpace.md),
                child: Text(l10n.balanceEmpty, key: const Key('balance.empty'), style: theme.textTheme.bodyMedium),
              ),
            for (final m in balance.members) ...[
              Row(
                key: Key('balance.member.${m.userId}'),
                children: [
                  HallyAvatar(name: m.name, size: 34),
                  const SizedBox(width: HallySpace.sm),
                  Flexible(child: Text(m.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: HallySpace.xs + 2),
                  HallyPill(
                    label: m.isCaregiver ? l10n.roleCaregiver : l10n.roleParent,
                    color: m.isCaregiver ? HallyColors.mist : HallyColors.powder,
                  ),
                  const Spacer(),
                  Text('${m.total}', key: Key('balance.total.${m.userId}'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 6),
              _Bar(parts: m.parts, max: most, brightness: b),
              const SizedBox(height: HallySpace.md),
            ],
            Wrap(
              spacing: HallySpace.md,
              runSpacing: 6,
              children: [
                for (final (i, k) in kinds.indexed)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: HallyColors.accent(balanceKindColors[i], b), borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(width: 5),
                    Text(k, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ]),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A stacked bar whose full width is the busiest adult's total, so bars compare at a glance.
class _Bar extends StatelessWidget {
  const _Bar({required this.parts, required this.max, required this.brightness});

  final List<int> parts;
  final int max;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final total = parts.fold(0, (a, p) => a + p);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 20,
        child: Row(
          children: [
            for (final (i, p) in parts.indexed)
              if (p > 0) Expanded(flex: p, child: ColoredBox(color: HallyColors.accent(balanceKindColors[i], brightness))),
            if (max - total > 0) Expanded(flex: max - total, child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4))),
            if (max == 0) Expanded(child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4))),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion, required this.isMe});

  final BalanceSuggestion suggestion;

  /// Only the busy parent gets the "ask by message" button: the draft is written in their voice.
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final s = suggestion;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = s.date == null ? null : DateFormat.EEEE(locale).format(s.date!);
    final duty = s.kind == 'PickUp' ? l10n.balanceDutyPickUp : l10n.balanceDutyDropOff;
    final ask = day == null ? l10n.balanceAskGeneric(s.toName) : l10n.balanceAskRun(day, duty, s.toName);
    final draft = day == null ? l10n.balanceDraftGeneric : l10n.balanceDraftRun(day, duty);
    final fg = HallyColors.readableOn(HallyColors.lavender, b);

    return Container(
      key: const Key('balance.suggestion'),
      padding: const EdgeInsets.all(HallySpace.md),
      decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.lavender, b), borderRadius: BorderRadius.circular(HallyRadius.lg)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.balance_rounded, color: fg),
          const SizedBox(width: HallySpace.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.balanceHeavy(s.heavyName, s.sharePercent), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(ask, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (isMe) ...[
                const SizedBox(height: HallySpace.sm + 2),
                FilledButton.icon(
                  key: const Key('balance.ask'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44), backgroundColor: HallyColors.accent(HallyColors.lavender, b)),
                  onPressed: () => context.push(Uri(path: '/chats/${s.toUserId}', queryParameters: {'draft': draft}).toString(), extra: s.toName),
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                  label: Text(l10n.balanceSuggestTo),
                ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
