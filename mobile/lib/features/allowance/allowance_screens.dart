import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../child_mode/child_mode_repository.dart';
import 'allowance.dart';

String _locale(BuildContext context) => Localizations.localeOf(context).toLanguageTag();

String _money(BuildContext context, double amount, String currency) => formatMoney(amount, currency, _locale(context));

final kidSavingsProvider = FutureProvider.autoDispose<ChildSavings>((ref) => ref.watch(childApiProvider).savings());

/// "Bugün", "Dün", else the weekday ("Pazartesi").
String dayLabel(BuildContext context, DateTime day, {DateTime? now}) {
  final l10n = AppLocalizations.of(context);
  final t = now ?? DateTime.now();
  final today = DateTime(t.year, t.month, t.day);
  final d = DateTime(day.year, day.month, day.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return l10n.savingsToday;
  if (diff == 1) return l10n.savingsYesterday;
  if (diff < 7) return DateFormat('EEEE', _locale(context)).format(d);
  return DateFormat('d MMM', _locale(context)).format(d);
}

/// What a ledger line says to a child.
String ledgerTitle(AppLocalizations l10n, LedgerLine line) => switch (line.kind) {
      'Mood' => l10n.savingsLineMood,
      'Bedtime' => l10n.savingsLineBedtime,
      'Bonus' => l10n.savingsLineBonus,
      'Allowance' => line.title == 'weekly' ? l10n.savingsLineWeekly : l10n.savingsLineConverted,
      _ => line.title,
    };

// ─── Child ────────────────────────────────────────────────────────────────────

/// In the jar tab: Birikimim (savings goal with an estimate), "Harçlığa çevir" and Son hareketler.
class KidSavingsSection extends ConsumerWidget {
  const KidSavingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final savings = ref.watch(kidSavingsProvider).valueOrNull;
    if (savings == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final accent = HallyColors.accent(HallyColors.cherry, b);
    final goal = savings.goal;
    final s = savings.settings;
    final pending = savings.pending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (goal == null)
          Card(
            key: const Key('savings.setGoal'),
            margin: const EdgeInsets.only(bottom: HallySpace.md),
            child: ListTile(
              leading: const Text('🎯', style: TextStyle(fontSize: 28)),
              title: Text(l10n.savingsSetGoal, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(l10n.savingsSetGoalBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _editGoal(context, ref, null),
            ),
          )
        else
          InkWell(
            key: const Key('savings.goal'),
            borderRadius: BorderRadius.circular(26),
            onTap: () => _editGoal(context, ref, goal),
            child: Container(
              margin: const EdgeInsets.only(bottom: HallySpace.md),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [HallyColors.softOf(HallyColors.cherry, b), HallyColors.softOf(HallyColors.powder, b)],
                ),
              ),
              child: Column(children: [
                Text(l10n.savingsTitle, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(goal.emoji, style: const TextStyle(fontSize: 48)),
                Text(goal.title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                Text(l10n.savingsProgress(savings.balance.clamp(0, goal.cherries), goal.cherries),
                    style: TextStyle(fontWeight: FontWeight.w700, color: accent)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: LinearProgressIndicator(
                    minHeight: 18,
                    value: (savings.balance / goal.cherries).clamp(0, 1).toDouble(),
                    backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.8),
                    color: accent,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  savings.balance >= goal.cherries
                      ? l10n.savingsReached
                      : savings.weeksToGoal != null
                          ? l10n.savingsEta(savings.weeksToGoal!)
                          : l10n.savingsEtaUnknown,
                  key: const Key('savings.eta'),
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
          ),
        Card(
          margin: const EdgeInsets.only(bottom: HallySpace.md),
          child: Padding(
            padding: const EdgeInsets.all(HallySpace.md),
            child: Row(children: [
              const Text('💰', style: TextStyle(fontSize: 26)),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l10n.savingsConvert, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    pending != null
                        ? l10n.savingsConvertWaiting(pending.cherries, _money(context, pending.amount, pending.currency))
                        : l10n.savingsRate(s.rateCherries, _money(context, s.rateAmount, s.currency)),
                    style: theme.textTheme.bodySmall,
                  ),
                ]),
              ),
              if (pending != null)
                HallyPill(label: l10n.askWaiting, color: HallyColors.butter)
              else
                FilledButton(
                  key: const Key('savings.convert'),
                  // The theme makes buttons full width; in a row it needs its own size.
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: savings.convertible < s.rateCherries ? null : () => _convert(context, ref, savings),
                  child: Text(l10n.savingsConvertButton),
                ),
            ]),
          ),
        ),
        if (savings.recent.isNotEmpty) ...[
          HallySectionHeader(title: l10n.savingsRecent),
          Card(
            margin: const EdgeInsets.only(bottom: HallySpace.md),
            child: Column(children: [
              for (final line in savings.recent)
                ListTile(
                  dense: true,
                  title: Text(ledgerTitle(l10n, line), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(dayLabel(context, line.day)),
                  trailing: Text(
                    line.points > 0 ? '+${line.points}' : '−${-line.points}',
                    style: TextStyle(fontWeight: FontWeight.w800, color: line.points > 0 ? accent : theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ]),
          ),
        ],
      ],
    );
  }

  Future<void> _editGoal(BuildContext context, WidgetRef ref, SavingsGoal? goal) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<(SavingsGoal?,)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GoalSheet(goal: goal),
    );
    if (result == null) return;
    try {
      await ref.read(childApiProvider).setSavingsGoal(result.$1);
      HapticFeedback.mediumImpact();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
    ref.invalidate(kidSavingsProvider);
  }

  Future<void> _convert(BuildContext context, WidgetRef ref, ChildSavings savings) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cherries = await showModalBottomSheet<int>(context: context, showDragHandle: true, builder: (_) => _ConvertSheet(savings: savings));
    if (cherries == null) return;
    try {
      await ref.read(childApiProvider).convert(cherries);
      HapticFeedback.mediumImpact();
      messenger.showSnackBar(SnackBar(content: Text(l10n.savingsConvertSent)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'points.not_enough' ? l10n.pointsNotEnough : l10n.errorGeneric)));
    }
    ref.invalidate(kidSavingsProvider);
  }
}

const _goalEmojis = ['🚲', '🎮', '⚽', '📚', '🧸', '🎨', '🛹', '🎧'];

class _GoalSheet extends StatefulWidget {
  const _GoalSheet({this.goal});

  final SavingsGoal? goal;

  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<_GoalSheet> {
  late String _emoji = widget.goal?.emoji ?? _goalEmojis.first;
  late final _title = TextEditingController(text: widget.goal?.title ?? '');
  late int _cherries = widget.goal?.cherries ?? 300;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.savingsGoalSheet, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: HallySpace.sm),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _goalEmojis)
                ChoiceChip(
                  key: Key('savings.emoji.$e'),
                  label: Text(e, style: const TextStyle(fontSize: 22)),
                  selected: _emoji == e,
                  onSelected: (_) => setState(() => _emoji = e),
                ),
            ]),
            const SizedBox(height: HallySpace.sm),
            TextField(
              key: const Key('savings.title'),
              controller: _title,
              maxLength: 40,
              decoration: InputDecoration(labelText: l10n.savingsGoalName, hintText: l10n.savingsGoalNameHint),
              onChanged: (_) => setState(() {}),
            ),
            Text(l10n.savingsGoalCherries, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              for (final c in const [100, 200, 300, 500, 1000])
                ChoiceChip(
                  key: Key('savings.cherries.$c'),
                  label: Text('$c'),
                  selected: _cherries == c,
                  onSelected: (_) => setState(() => _cherries = c),
                ),
            ]),
            const SizedBox(height: HallySpace.md),
            FilledButton(
              key: const Key('savings.save'),
              onPressed: _title.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, (SavingsGoal(title: _title.text.trim(), emoji: _emoji, cherries: _cherries),)),
              child: Text(l10n.askSave),
            ),
            if (widget.goal != null)
              TextButton(
                key: const Key('savings.clear'),
                onPressed: () => Navigator.pop(context, (null,)),
                child: Text(l10n.savingsGoalClear),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConvertSheet extends StatefulWidget {
  const _ConvertSheet({required this.savings});

  final ChildSavings savings;

  @override
  State<_ConvertSheet> createState() => _ConvertSheetState();
}

class _ConvertSheetState extends State<_ConvertSheet> {
  late int _cherries = widget.savings.settings.rateCherries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = widget.savings.settings;
    final max = widget.savings.convertible;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.savingsConvert, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: HallySpace.md),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.filledTonal(
              key: const Key('convert.less'),
              onPressed: _cherries > s.rateCherries ? () => setState(() => _cherries -= s.rateCherries) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            const SizedBox(width: HallySpace.md),
            Column(children: [
              Text('$_cherries', key: const Key('convert.cherries'), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
              Text(l10n.kidCherryUnit),
            ]),
            const SizedBox(width: HallySpace.md),
            IconButton.filledTonal(
              key: const Key('convert.more'),
              onPressed: _cherries + s.rateCherries <= max ? () => setState(() => _cherries += s.rateCherries) : null,
              icon: const Icon(Icons.add_rounded),
            ),
          ]),
          const SizedBox(height: HallySpace.sm),
          Text('= ${_money(context, s.amountFor(_cherries), s.currency)}',
              key: const Key('convert.amount'), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: HallySpace.sm),
          Text(l10n.savingsConvertHint, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          const SizedBox(height: HallySpace.md),
          FilledButton(key: const Key('convert.send'), onPressed: () => Navigator.pop(context, _cherries), child: Text(l10n.savingsConvertSend)),
        ],
      ),
    );
  }
}

// ─── Parents ──────────────────────────────────────────────────────────────────

/// A waiting conversion with "Ödedim" / "Şimdi değil".
class AllowanceDecisionCard extends ConsumerStatefulWidget {
  const AllowanceDecisionCard({super.key, required this.familyId, required this.request, this.onDone});

  final String familyId;
  final AllowanceRequestItem request;
  final VoidCallback? onDone;

  @override
  ConsumerState<AllowanceDecisionCard> createState() => _AllowanceDecisionCardState();
}

class _AllowanceDecisionCardState extends ConsumerState<AllowanceDecisionCard> {
  bool _busy = false;

  Future<void> _decide(bool paid) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(allowanceRepositoryProvider).decide(widget.familyId, widget.request.id, paid: paid);
      if (paid) messenger.showSnackBar(SnackBar(content: Text(l10n.allowancePaidDone(widget.request.childName))));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(switch (e.code) {
        'allowance.already_decided' => l10n.allowanceAlreadyDecided,
        'points.not_enough' => l10n.allowanceNotEnough,
        _ => l10n.errorGeneric,
      })));
    } finally {
      ref.invalidate(allowanceRequestsProvider(widget.familyId));
      widget.onDone?.call();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final r = widget.request;
    return Card(
      key: Key('allowance.request.${r.id}'),
      margin: const EdgeInsets.only(bottom: HallySpace.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HallyRadius.md),
        side: BorderSide(color: HallyColors.softOf(HallyColors.cherry, b), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            HallyAvatar(name: r.childName, size: 36),
            const SizedBox(width: HallySpace.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.allowanceAsks(r.childName, r.cherries), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('= ${_money(context, r.amount, r.currency)}', style: theme.textTheme.bodySmall),
              ]),
            ),
          ]),
          const SizedBox(height: HallySpace.sm),
          Row(children: [
            Expanded(child: FilledButton(key: Key('allowance.paid.${r.id}'), onPressed: _busy ? null : () => _decide(true), child: Text(l10n.allowancePaid))),
            const SizedBox(width: HallySpace.sm),
            Expanded(
              child: OutlinedButton(key: Key('allowance.later.${r.id}'), onPressed: _busy ? null : () => _decide(false), child: Text(l10n.allowanceLater)),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// On a parent's Today: waiting conversions. Hidden when none.
class ParentAllowanceCard extends ConsumerWidget {
  const ParentAllowanceCard({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(allowanceRequestsProvider(familyId)).valueOrNull ?? const [];
    if (open.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HallySectionHeader(title: l10n.allowanceTitle, color: HallyColors.cherry, count: open.length),
        for (final r in open) AllowanceDecisionCard(key: ValueKey(r.id), familyId: familyId, request: r),
      ],
    );
  }
}

/// `/allowance/:childId`: Kiraz değeri, Haftalık harçlık, waiting requests and the child's goal.
class AllowanceScreen extends ConsumerWidget {
  const AllowanceScreen({super.key, required this.familyId, required this.childId, this.childName});

  final String familyId;
  final String childId;
  final String? childName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final key = (familyId, childId);
    final state = ref.watch(allowanceProvider(key));

    Future<void> save(AllowanceSettings settings) async {
      try {
        await ref.read(allowanceRepositoryProvider).save(familyId, childId, settings);
      } catch (_) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
      ref.invalidate(allowanceProvider(key));
    }

    return Scaffold(
      appBar: AppBar(title: Text(childName == null ? l10n.allowanceTitle : '$childName · ${l10n.allowanceTitle}')),
      body: state.when(
        loading: () => const HallyLoading(),
        error: (e, _) => HallyErrorState(onRetry: () => ref.invalidate(allowanceProvider(key))),
        data: (a) {
          final s = a.settings;
          final open = a.requests.where((r) => r.isPending).toList();
          final done = a.requests.where((r) => !r.isPending).toList();
          return ListView(
            padding: const EdgeInsets.all(HallySpace.md),
            children: [
              Card(
                margin: const EdgeInsets.only(bottom: HallySpace.md),
                child: ListTile(
                  key: const Key('allowance.rate'),
                  title: Text(l10n.allowanceRate, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(l10n.allowanceRateBody),
                  trailing: Text(l10n.allowanceRateValue(s.rateCherries, _money(context, s.rateAmount, s.currency)),
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  onTap: () async {
                    final next = await showDialog<AllowanceSettings>(context: context, builder: (_) => _RateDialog(settings: s));
                    if (next != null) await save(next);
                  },
                ),
              ),
              Card(
                margin: const EdgeInsets.only(bottom: HallySpace.md),
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.allowanceWeekly, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(l10n.allowanceWeeklyBody, style: theme.textTheme.bodySmall),
                    const SizedBox(height: HallySpace.sm),
                    Wrap(spacing: 8, children: [
                      for (final w in const [0, 10, 20, 30])
                        ChoiceChip(
                          key: Key('allowance.weekly.$w'),
                          label: Text(w == 0 ? l10n.allowanceWeeklyOff : '$w'),
                          selected: s.weeklyCherries == w,
                          onSelected: (_) => save(s.copyWith(weeklyCherries: w)),
                        ),
                      if (!const [0, 10, 20, 30].contains(s.weeklyCherries)) ChoiceChip(label: Text('${s.weeklyCherries}'), selected: true),
                    ]),
                  ]),
                ),
              ),
              Card(
                margin: const EdgeInsets.only(bottom: HallySpace.md),
                child: SwitchListTile(
                  key: const Key('allowance.expenses'),
                  title: Text(l10n.allowanceExpenses),
                  subtitle: Text(l10n.allowanceExpensesBody),
                  value: s.addToExpenses,
                  onChanged: (v) => save(s.copyWith(addToExpenses: v)),
                ),
              ),
              if (a.goal case final goal?)
                Card(
                  margin: const EdgeInsets.only(bottom: HallySpace.md),
                  child: ListTile(
                    leading: Text(goal.emoji, style: const TextStyle(fontSize: 28)),
                    title: Text(goal.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(l10n.savingsProgress(a.balance.clamp(0, goal.cherries), goal.cherries)),
                  ),
                ),
              if (open.isNotEmpty) HallySectionHeader(title: l10n.allowancePending, count: open.length),
              for (final r in open) AllowanceDecisionCard(familyId: familyId, request: r, onDone: () => ref.invalidate(allowanceProvider(key))),
              if (done.isNotEmpty) HallySectionHeader(title: l10n.allowanceHistory),
              for (final r in done)
                ListTile(
                  dense: true,
                  title: Text('${r.cherries} → ${_money(context, r.amount, r.currency)}'),
                  subtitle: Text(DateFormat.yMMMd(_locale(context)).format(r.createdAt)),
                  trailing: HallyPill(
                    label: r.status == AllowanceStatus.paid ? l10n.allowanceStatusPaid : l10n.allowanceStatusDeclined,
                    color: r.status == AllowanceStatus.paid ? HallyColors.sage : HallyColors.mist,
                  ),
                ),
              const SizedBox(height: HallySpace.md),
              Text(l10n.allowanceDisclaimer,
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }
}

class _RateDialog extends StatefulWidget {
  const _RateDialog({required this.settings});

  final AllowanceSettings settings;

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  late final _cherries = TextEditingController(text: '${widget.settings.rateCherries}');
  late final _amount = TextEditingController(text: NumberFormat('0.##', 'en').format(widget.settings.rateAmount));

  @override
  void dispose() {
    _cherries.dispose();
    _amount.dispose();
    super.dispose();
  }

  int? get _c => int.tryParse(_cherries.text.trim());
  double? get _a => double.tryParse(_amount.text.trim().replaceAll(',', '.'));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ok = (_c ?? 0) > 0 && (_a ?? 0) > 0;
    return AlertDialog(
      title: Text(l10n.allowanceRate),
      content: Row(children: [
        Expanded(
          child: TextField(
            key: const Key('rate.cherries'),
            controller: _cherries,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.kidCherryUnit),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('=')),
        Expanded(
          child: TextField(
            key: const Key('rate.amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '₺'),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
        FilledButton(
          key: const Key('rate.ok'),
          onPressed: ok ? () => Navigator.pop(context, widget.settings.copyWith(rateCherries: _c, rateAmount: (_a! * 100).round() / 100)) : null,
          child: Text(l10n.askOk),
        ),
      ],
    );
  }
}
