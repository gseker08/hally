import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'expenses_repository.dart';

const expenseCategories = ['School', 'Health', 'Clothes', 'Activity', 'Food', 'Other'];

String expenseCategoryLabel(AppLocalizations l10n, String c) => switch (c) {
      'School' => l10n.expensesCatSchool,
      'Health' => l10n.expensesCatHealth,
      'Clothes' => l10n.expensesCatClothes,
      'Activity' => l10n.expensesCatActivity,
      'Food' => l10n.expensesCatFood,
      _ => l10n.expensesCatOther,
    };

IconData expenseCategoryIcon(String c) => switch (c) {
      'School' => Icons.school_rounded,
      'Health' => Icons.local_hospital_rounded,
      'Clothes' => Icons.checkroom_rounded,
      'Activity' => Icons.sports_soccer_rounded,
      'Food' => Icons.restaurant_rounded,
      _ => Icons.receipt_long_rounded,
    };

NumberFormat _money(BuildContext context) => NumberFormat.currency(locale: Localizations.localeOf(context).toLanguageTag(), symbol: '₺', decimalDigits: 2);

String _monthKey(DateTime m) => '${m.year.toString().padLeft(4, '0')}-${m.month.toString().padLeft(2, '0')}';

/// Shared family spending: who paid what this month, an equal split between the adults, and who owes whom.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  Future<void> _act(String familyId, Future<void> Function(ExpensesRepository repo) action) async {
    try {
      await action(ref.read(expensesRepositoryProvider));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    }
    ref.invalidate(expenseMonthProvider((familyId, _monthKey(_month))));
  }

  Future<void> _settle(String familyId, SettleSuggestion s) async {
    final l10n = AppLocalizations.of(context);
    final money = _money(context);
    final amount = TextEditingController(text: s.amount.toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Scrolls instead of overflowing on short screens, with the keyboard open or large text.
        scrollable: true,
        title: Text(l10n.expensesSettleTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.expensesOwes(s.fromName, s.toName, money.format(s.amount))),
            TextField(
              key: const Key('expenses.settleAmount'),
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: l10n.expensesAmount),
            ),
            const SizedBox(height: HallySpace.sm),
            Text(l10n.expensesNoMoneyMoves, style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(key: const Key('expenses.settleSave'), onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.expensesSettle)),
        ],
      ),
    );
    final value = parseExpenseAmount(amount.text);
    amount.dispose();
    if (ok == true && value != null) await _act(familyId, (r) => r.settle(familyId, toUserId: s.toUserId, amount: value));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final me = ref.watch(meProvider).valueOrNull;
    final familyId = me?.primaryFamily?.id;
    if (me == null || familyId == null) return const Scaffold(body: HallyLoading());
    final key = (familyId, _monthKey(_month));
    final data = ref.watch(expenseMonthProvider(key));
    final money = _money(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = DateTime.now();
    final isThisMonth = _month.year == now.year && _month.month == now.month;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.expensesTitle)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('expenses.add'),
        onPressed: () async {
          final m = data.valueOrNull;
          final added = await showAddExpenseSheet(context,
              familyId: familyId,
              meId: me.id,
              adults: m?.balances ?? const [],
              initialDate: isThisMonth ? DateTime(now.year, now.month, now.day) : _month);
          if (added != null && mounted) setState(() => _month = DateTime(added.year, added.month));
          ref.invalidate(expenseMonthProvider((familyId, _monthKey(_month))));
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.expensesAdd),
      ),
      body: data.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(expenseMonthProvider(key))),
        data: (m) {
          final s = m.suggestion;
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('expenses.prev'),
                    onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Expanded(child: Text(DateFormat.yMMMM(locale).format(_month), textAlign: TextAlign.center, style: theme.textTheme.titleMedium)),
                  IconButton(
                    key: const Key('expenses.next'),
                    onPressed: isThisMonth ? null : () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              Card(
                color: HallyColors.softOf(HallyColors.mint, Theme.of(context).brightness),
                child: Padding(
                  padding: const EdgeInsets.all(HallySpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(money.format(m.total), key: const Key('expenses.total'),
                          style: theme.textTheme.headlineSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w800)),
                      Text(l10n.expensesMonthTotal, style: theme.textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: HallySpace.sm),
                      if (m.balances.length < 2)
                        Text(l10n.expensesSolo, style: theme.textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface))
                      else if (s == null)
                        Text(l10n.expensesAllSquare, key: const Key('expenses.square'), style: theme.textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface))
                      else ...[
                        Text(l10n.expensesOwes(s.fromName, s.toName, money.format(s.amount)), key: const Key('expenses.suggestion'),
                            style: theme.textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface)),
                        if (s.fromUserId == me.id) ...[
                          const SizedBox(height: HallySpace.sm),
                          FilledButton.icon(
                            key: const Key('expenses.settle'),
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                            onPressed: () => _settle(familyId, s),
                            icon: const Icon(Icons.handshake_rounded),
                            label: Text(l10n.expensesSettle),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              if (m.byCategory.isNotEmpty) ...[
                const SizedBox(height: HallySpace.sm),
                Wrap(
                  spacing: HallySpace.sm,
                  runSpacing: HallySpace.xs,
                  children: [
                    for (final e in m.byCategory.entries)
                      Chip(avatar: Icon(expenseCategoryIcon(e.key), size: 18), label: Text('${expenseCategoryLabel(l10n, e.key)} ${money.format(e.value)}')),
                  ],
                ),
              ],
              const SizedBox(height: HallySpace.md),
              if (m.expenses.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: HallySpace.sm), child: Text(l10n.expensesNone)),
              for (final e in m.expenses)
                Dismissible(
                  key: Key('expenses.item.${e.id}'),
                  direction: DismissDirection.endToStart,
                  background: _deleteBackground(),
                  onDismissed: (_) => _act(familyId, (r) => r.delete(familyId, e.id)),
                  child: Card(
                    child: ListTile(
                      leading: HallyIconBadge(icon: expenseCategoryIcon(e.category), color: HallyColors.mint),
                      title: Text(e.title),
                      subtitle: Text([
                        DateFormat.MMMd(locale).format(e.date),
                        l10n.expensesPaidByLine(e.paidByName ?? '?', money.format(e.myShare)),
                      ].join(' · ')),
                      trailing: Text(money.format(e.amount), style: theme.textTheme.titleSmall),
                    ),
                  ),
                ),
              if (m.settlements.isNotEmpty) ...[
                const SizedBox(height: HallySpace.md),
                Text(l10n.expensesPayments, style: theme.textTheme.titleMedium),
                for (final p in m.settlements)
                  Dismissible(
                    key: Key('expenses.settlement.${p.id}'),
                    direction: DismissDirection.endToStart,
                    background: _deleteBackground(),
                    onDismissed: (_) => _act(familyId, (r) => r.deleteSettlement(familyId, p.id)),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.handshake_rounded, color: HallyColors.mintDeep),
                      title: Text('${p.fromName ?? '?'} → ${p.toName ?? '?'}'),
                      subtitle: Text(DateFormat.MMMd(locale).format(p.date)),
                      trailing: Text(money.format(p.amount), style: theme.textTheme.titleSmall),
                    ),
                  ),
              ],
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

/// "12,50", "12.5" or "1.250,00" to a positive amount with at most 2 decimals; null when invalid.
double? parseExpenseAmount(String text) {
  var t = text.trim().replaceAll(' ', '');
  if (t.contains(',')) t = t.replaceAll('.', '').replaceAll(',', '.');
  final v = double.tryParse(t);
  if (v == null || v <= 0 || v > 1000000) return null;
  return (v * 100).roundToDouble() / 100;
}

/// Add an expense. Returns its date when saved.
Future<DateTime?> showAddExpenseSheet(BuildContext context,
        {required String familyId, required String meId, required List<ExpenseBalance> adults, required DateTime initialDate}) =>
    showModalBottomSheet<DateTime>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AddExpenseSheet(familyId: familyId, meId: meId, adults: adults, initialDate: initialDate),
    );

class _AddExpenseSheet extends ConsumerStatefulWidget {
  const _AddExpenseSheet({required this.familyId, required this.meId, required this.adults, required this.initialDate});

  final String familyId;
  final String meId;
  final List<ExpenseBalance> adults;
  final DateTime initialDate;

  @override
  ConsumerState<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends ConsumerState<_AddExpenseSheet> {
  final _title = TextEditingController();
  final _amount = TextEditingController();
  String _category = 'Other';
  late String _paidBy = widget.meId;
  late DateTime _date = widget.initialDate;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final title = _title.text.trim();
    final amount = parseExpenseAmount(_amount.text);
    if (title.isEmpty || amount == null) {
      setState(() => _error = title.isEmpty ? l10n.pointsTitleRequired : l10n.expensesAmountInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(expensesRepositoryProvider).add(widget.familyId, title: title, amount: amount, category: _category, date: _date, paidByUserId: _paidBy);
      if (mounted) Navigator.pop(context, _date);
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
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('expenses.title'),
              controller: _title,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.expensesWhat),
            ),
            TextField(
              key: const Key('expenses.amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: InputDecoration(labelText: l10n.expensesAmount),
            ),
            const SizedBox(height: HallySpace.md),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.xs,
              children: [
                for (final c in expenseCategories)
                  ChoiceChip(
                    key: Key('expenses.cat.$c'),
                    avatar: Icon(expenseCategoryIcon(c), size: 18),
                    label: Text(expenseCategoryLabel(l10n, c)),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            if (widget.adults.length > 1) ...[
              const SizedBox(height: HallySpace.md),
              Text(l10n.expensesPaidBy, style: theme.textTheme.titleSmall),
              Wrap(
                spacing: HallySpace.sm,
                children: [
                  for (final a in widget.adults)
                    ChoiceChip(
                      key: Key('expenses.payer.${a.userId}'),
                      label: Text(a.name),
                      selected: _paidBy == a.userId,
                      onSelected: (_) => setState(() => _paidBy = a.userId),
                    ),
                ],
              ),
            ],
            const SizedBox(height: HallySpace.sm),
            ListTile(
              key: const Key('expenses.date'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_rounded),
              title: Text(DateFormat.yMMMd(locale).format(_date)),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(now.year - 2), lastDate: now);
                if (picked != null) setState(() => _date = picked);
              },
            ),
            if (_error != null) Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error)),
            const SizedBox(height: HallySpace.md),
            FilledButton(key: const Key('expenses.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
          ],
        ),
      ),
    );
  }
}
