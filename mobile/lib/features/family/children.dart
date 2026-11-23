import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import 'family_repository.dart';

/// Colour keys the API accepts, in the order new children get them. Red (brand) and orange (delays)
/// are left out on purpose so a child's colour never reads as an alert.
const childColorKeys = ['sky', 'mint', 'lavender', 'sun', 'teal', 'indigo'];

Color childColor(String key) => switch (key) {
      'mint' => HallyColors.mint,
      'lavender' => const Color(0xFF8E7CDB),
      'sun' => const Color(0xFFD4A21A),
      'teal' => const Color(0xFF1E9AA0),
      'indigo' => const Color(0xFF5C6BC0),
      _ => HallyColors.sky,
    };

/// The child selected in the filter bar on Today, Calendar and Tasks (null = everyone). Shared so the
/// choice follows the parent from screen to screen.
final childFilterProvider = StateProvider<String?>((ref) => null);

/// Keeps only items tagged with [childId]. Untagged (whole-family) items show under "Hepsi" only: mixing them
/// into every child's list made one child look like they had everything.
List<T> filterByChild<T>(List<T> items, List<String> Function(T) childIdsOf, String? childId) =>
    childId == null ? items : items.where((i) => childIdsOf(i).contains(childId)).toList();

/// Children of the family, or an empty list while it loads.
List<ChildProfile> watchChildren(WidgetRef ref, String familyId) => ref.watch(familyProvider(familyId)).valueOrNull?.children ?? const [];

/// Round initial badge in the child's colour.
class ChildBadge extends StatelessWidget {
  const ChildBadge({super.key, required this.child, this.size = 22});

  final ChildProfile child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = child.firstName.trim().isEmpty ? '?' : child.firstName.trim().characters.first.toUpperCase();
    return Tooltip(
      message: child.firstName,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: childColor(child.color)),
        child: Text(initial, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.5, height: 1)),
      ),
    );
  }
}

/// Small overlapping badges for the children an item is tagged with. Renders nothing for whole-family items.
class ChildBadges extends ConsumerWidget {
  const ChildBadges({super.key, required this.familyId, required this.childIds, this.size = 22});

  final String familyId;
  final List<String> childIds;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (childIds.isEmpty) return const SizedBox.shrink();
    final byId = {for (final c in watchChildren(ref, familyId)) c.id: c};
    final tagged = [for (final id in childIds) if (byId[id] != null) byId[id]!];
    if (tagged.isEmpty) return const SizedBox.shrink();
    final shown = tagged.take(3).toList();
    return SizedBox(
      width: size + (shown.length - 1) * size * 0.6,
      height: size,
      child: Stack(
        children: [
          for (final (i, c) in shown.indexed)
            Positioned(
              left: i * size * 0.6,
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1.5)),
                child: ChildBadge(child: c, size: size),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Everyone · Ela · Can" chips. Hidden until the family has at least two children: with one child there is
/// nothing to tell apart.
class ChildFilterBar extends ConsumerWidget {
  const ChildFilterBar({super.key, required this.familyId, this.padding = const EdgeInsets.symmetric(horizontal: HallySpace.md)});

  final String familyId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final children = watchChildren(ref, familyId);
    if (children.length < 2) return const SizedBox.shrink();
    var selected = ref.watch(childFilterProvider);
    if (selected != null && !children.any((c) => c.id == selected)) selected = null;
    void select(String? id) => ref.read(childFilterProvider.notifier).state = id;

    return SizedBox(
      height: 48,
      child: ListView(
        key: const Key('childFilter'),
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: [
          ChoiceChip(
            key: const Key('childFilter.all'),
            label: Text(l10n.childFilterAll),
            selected: selected == null,
            onSelected: (_) => select(null),
          ),
          for (final c in children) ...[
            const SizedBox(width: HallySpace.sm),
            ChoiceChip(
              key: Key('childFilter.${c.id}'),
              avatar: ChildBadge(child: c, size: 20),
              label: Text(c.firstName),
              selected: selected == c.id,
              selectedColor: HallyColors.softOf(childColor(c.color), Theme.of(context).brightness),
              onSelected: (on) => select(on ? c.id : null),
            ),
          ],
        ],
      ),
    );
  }
}

/// Multi-select chips for tagging a task or event with children. Nothing selected means the whole family.
class ChildPicker extends StatelessWidget {
  const ChildPicker({super.key, required this.children, required this.selected, required this.onChanged});

  final List<ChildProfile> children;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: HallySpace.sm),
        Text(l10n.childPickerLabel, style: theme.textTheme.labelLarge),
        const SizedBox(height: HallySpace.xs),
        Wrap(
          spacing: HallySpace.sm,
          runSpacing: HallySpace.xs,
          children: [
            for (final c in children)
              FilterChip(
                key: Key('childPicker.${c.id}'),
                avatar: ChildBadge(child: c, size: 20),
                label: Text(c.firstName),
                selected: selected.contains(c.id),
                showCheckmark: false,
                selectedColor: HallyColors.softOf(childColor(c.color), theme.brightness),
                onSelected: (on) => onChanged(on ? {...selected, c.id} : ({...selected}..remove(c.id))),
              ),
          ],
        ),
        Text(selected.isEmpty ? l10n.childPickerWholeFamily : '', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// Add or edit a child: first name, optional birth year and colour. Returns true when something changed.
Future<bool> showChildSheet(BuildContext context, WidgetRef ref, {required String familyId, ChildProfile? child, required List<ChildProfile> siblings}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ChildSheet(familyId: familyId, child: child, siblings: siblings),
  );
  if (changed == true) ref.invalidate(familyProvider(familyId));
  return changed == true;
}

class _ChildSheet extends ConsumerStatefulWidget {
  const _ChildSheet({required this.familyId, required this.child, required this.siblings});

  final String familyId;
  final ChildProfile? child;
  final List<ChildProfile> siblings;

  @override
  ConsumerState<_ChildSheet> createState() => _ChildSheetState();
}

class _ChildSheetState extends ConsumerState<_ChildSheet> {
  late final _name = TextEditingController(text: widget.child?.firstName ?? '');
  late final _year = TextEditingController(text: widget.child?.birthYear?.toString() ?? '');
  late String _color = widget.child?.color ??
      childColorKeys.firstWhere((k) => !widget.siblings.any((s) => s.color == k), orElse: () => childColorKeys.first);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = AppLocalizations.of(context).errorGeneric;
        });
      }
    }
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    final yearText = _year.text.trim();
    final year = yearText.isEmpty ? null : int.tryParse(yearText);
    final now = DateTime.now().year;
    if (name.isEmpty) {
      setState(() => _error = l10n.childNameRequired);
      return;
    }
    if (yearText.isNotEmpty && (year == null || year < now - 25 || year > now)) {
      setState(() => _error = l10n.childBirthYearInvalid);
      return;
    }
    final repo = ref.read(familyRepositoryProvider);
    final child = widget.child;
    _run(() => child == null
        ? repo.addChild(widget.familyId, firstName: name, birthYear: year, color: _color)
        : repo.updateChild(widget.familyId, child.id, firstName: name, birthYear: year, color: _color));
  }

  Future<void> _delete(ChildProfile child) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.childDeleteTitle(child.firstName)),
        content: Text(l10n.childDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
          FilledButton(key: const Key('child.deleteConfirm'), onPressed: () => Navigator.pop(context, true), child: Text(l10n.childDelete)),
        ],
      ),
    );
    if (ok == true) await _run(() => ref.read(familyRepositoryProvider).deleteChild(widget.familyId, child.id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final child = widget.child;
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, MediaQuery.viewInsetsOf(context).bottom + HallySpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(child == null ? l10n.childAdd : l10n.childEdit, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.md),
          TextField(
            key: const Key('child.name'),
            controller: _name,
            autofocus: child == null,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: l10n.childName, helperText: l10n.childNameHelp),
          ),
          TextField(
            key: const Key('child.birthYear'),
            controller: _year,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: InputDecoration(labelText: l10n.childBirthYear),
          ),
          Text(l10n.childColor, style: theme.textTheme.labelLarge),
          const SizedBox(height: HallySpace.sm),
          Wrap(
            spacing: HallySpace.sm,
            children: [
              for (final key in childColorKeys)
                Semantics(
                  selected: key == _color,
                  button: true,
                  child: InkResponse(
                    key: Key('child.color.$key'),
                    onTap: () => setState(() => _color = key),
                    child: AnimatedContainer(
                      duration: HallyMotion.fast,
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: childColor(key),
                        border: Border.all(color: key == _color ? theme.colorScheme.onSurface : Colors.transparent, width: 3),
                      ),
                      child: key == _color ? const Icon(Icons.check_rounded, color: Colors.white, size: 20) : null,
                    ),
                  ),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: HallySpace.sm),
            Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 18, color: HallyColors.error),
                const SizedBox(width: HallySpace.xs),
                Expanded(child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error))),
              ],
            ),
          ],
          const SizedBox(height: HallySpace.lg),
          FilledButton(key: const Key('child.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
          if (child != null)
            TextButton.icon(
              key: const Key('child.delete'),
              onPressed: _busy ? null : () => _delete(child),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(l10n.childDelete),
            ),
        ],
      ),
    );
  }
}
