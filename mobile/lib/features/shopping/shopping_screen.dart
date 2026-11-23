import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'shopping_repository.dart';

/// The family's shared shopping list: type to add (several at once with commas or new lines), tick to buy.
class ShoppingScreen extends ConsumerStatefulWidget {
  const ShoppingScreen({super.key});

  @override
  ConsumerState<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends ConsumerState<ShoppingScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _adding = false;
  bool _showChecked = false;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _add(String familyId) async {
    final l10n = AppLocalizations.of(context);
    final text = _input.text.trim();
    if (text.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      final result = await ref.read(shoppingProvider(familyId).notifier).add(text);
      _input.clear();
      if (result.alreadyOnList.isNotEmpty) {
        _snack(l10n.shoppingAlreadyOnList(result.alreadyOnList.map((i) => i.text).join(', ')));
      }
    } catch (_) {
      _snack(l10n.errorGeneric);
    } finally {
      if (mounted) setState(() => _adding = false);
      _focus.requestFocus();
    }
  }

  Future<void> _headingOut(String familyId) async {
    final l10n = AppLocalizations.of(context);
    try {
      final sent = await ref.read(shoppingRepositoryProvider).headingOut(familyId);
      _snack(sent ? l10n.shoppingHeadingOutSent : l10n.shoppingHeadingOutAlready);
    } catch (_) {
      _snack(l10n.errorGeneric);
    }
  }

  Future<void> _editQuantity(String familyId, ShoppingItem item) async {
    final l10n = AppLocalizations.of(context);
    final value = await showDialog<String>(context: context, builder: (_) => _QuantityDialog(item: item));
    if (value == null) return;
    try {
      await ref.read(shoppingProvider(familyId).notifier).edit(item.id, quantity: value.trim());
    } catch (_) {
      _snack(l10n.errorGeneric);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final list = ref.watch(shoppingProvider(familyId));
    final controller = ref.read(shoppingProvider(familyId).notifier);

    Widget tile(ShoppingItem item) => Dismissible(
          key: Key('shopping.item.${item.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: HallySpace.lg),
            color: theme.colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.delete_outline_rounded),
          ),
          onDismissed: (_) => controller.delete(item.id).catchError((_) => _snack(l10n.errorGeneric)),
          child: CheckboxListTile(
            key: Key('shopping.check.${item.id}'),
            value: item.isChecked,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: HallyColors.mint,
            onChanged: (_) => controller.toggle(item).catchError((_) => _snack(l10n.errorGeneric)),
            title: Text(
              item.text,
              style: item.isChecked
                  ? theme.textTheme.bodyLarge?.copyWith(decoration: TextDecoration.lineThrough, color: theme.colorScheme.onSurfaceVariant)
                  : theme.textTheme.bodyLarge,
            ),
            subtitle: item.isChecked
                ? (item.checkedByName == null ? null : Text(l10n.shoppingBoughtBy(item.checkedByName!)))
                : (item.addedByName == null ? null : Text(l10n.shoppingAddedBy(item.addedByName!))),
            secondary: item.isChecked
                ? null
                : ActionChip(
                    key: Key('shopping.qty.${item.id}'),
                    label: Text(item.quantity ?? '+'),
                    onPressed: () => _editQuantity(familyId, item),
                  ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.shoppingTitle),
        actions: [
          IconButton(
            key: const Key('shopping.headingOut'),
            tooltip: l10n.shoppingHeadingOut,
            icon: const Icon(Icons.directions_walk_rounded),
            onPressed: () => _headingOut(familyId),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, HallySpace.sm),
            child: TextField(
              key: const Key('shopping.input'),
              controller: _input,
              focusNode: _focus,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _add(familyId),
              decoration: InputDecoration(
                hintText: l10n.shoppingHint,
                prefixIcon: const Icon(Icons.add_shopping_cart_rounded),
                suffixIcon: IconButton(
                  key: const Key('shopping.add'),
                  tooltip: l10n.shoppingAdd,
                  onPressed: _adding ? null : () => _add(familyId),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ),
          ),
          Expanded(
            child: list.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(shoppingProvider(familyId))),
              data: (data) => data.open.isEmpty && data.checked.isEmpty
                  ? HallyEmptyState(icon: Icons.shopping_basket_outlined, title: l10n.shoppingEmpty, body: l10n.shoppingEmptyBody)
                  : RefreshIndicator(
                      onRefresh: controller.refresh,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: HallySpace.xxl),
                        children: [
                          if (data.open.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(HallySpace.md),
                              child: Text(l10n.shoppingAllDone, style: theme.textTheme.titleMedium?.copyWith(color: HallyColors.mintDeep)),
                            ),
                          for (final item in data.open) tile(item),
                          if (data.checked.isNotEmpty) ...[
                            const Divider(),
                            ListTile(
                              key: const Key('shopping.checkedHeader'),
                              title: Text(l10n.shoppingBought(data.checked.length), style: theme.textTheme.labelLarge),
                              leading: Icon(_showChecked ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                              onTap: () => setState(() => _showChecked = !_showChecked),
                              trailing: TextButton(
                                key: const Key('shopping.clear'),
                                onPressed: () => controller.clearChecked().catchError((_) => _snack(l10n.errorGeneric)),
                                child: Text(l10n.shoppingClear),
                              ),
                            ),
                            if (_showChecked) for (final item in data.checked) tile(item),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Owns its text controller, so the controller lives as long as the dialog's closing animation.
class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.item});

  final ShoppingItem item;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final _controller = TextEditingController(text: widget.item.quantity ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.item.text),
      content: TextField(
        key: const Key('shopping.quantity'),
        controller: _controller,
        autofocus: true,
        maxLength: 20,
        decoration: InputDecoration(labelText: l10n.shoppingQuantity, hintText: l10n.shoppingQuantityHint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
        TextButton(key: const Key('shopping.quantitySave'), onPressed: () => Navigator.pop(context, _controller.text), child: Text(l10n.eventSave)),
      ],
    );
  }
}
