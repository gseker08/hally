import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import 'child_photo.dart';
import 'family_repository.dart';

/// Colour keys the API accepts, in the order new children get them. Red (brand) and orange (delays)
/// are left out on purpose so a child's colour never reads as an alert.
const childColorKeys = ['sky', 'mint', 'lavender', 'sun', 'teal', 'indigo'];

Color childColor(String key) => switch (key) {
      'mint' => HallyColors.childMint,
      'lavender' => HallyColors.childLavender,
      'sun' => HallyColors.childSun,
      'teal' => HallyColors.childTeal,
      'indigo' => HallyColors.childIndigo,
      _ => HallyColors.childSky,
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

/// Round badge for a child: their photo in a ring of their colour, or their initial on their colour.
class ChildBadge extends StatelessWidget {
  const ChildBadge({super.key, required this.child, this.size = 22});

  final ChildProfile child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = child.photoUrl;
    return Tooltip(
      message: child.firstName,
      child: url == null
          ? ChildInitial(child: child, size: size)
          : Consumer(builder: (context, ref, _) {
              final photo = ref.watch(childPhotoProvider(url)).valueOrNull;
              if (photo == null) return ChildInitial(child: child, size: size);
              return ChildPhotoCircle(bytes: photo, color: childColor(child.color), size: size);
            }),
    );
  }
}

/// The child's initial on their colour.
class ChildInitial extends StatelessWidget {
  const ChildInitial({super.key, required this.child, required this.size});

  final ChildProfile child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = child.firstName.trim().isEmpty ? '?' : child.firstName.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: childColor(child.color)),
      child: Text(initial, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.5, height: 1)),
    );
  }
}

/// A photo in a circle with a ring of [color].
class ChildPhotoCircle extends StatelessWidget {
  const ChildPhotoCircle({super.key, required this.bytes, required this.color, required this.size});

  final Uint8List bytes;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ring = size < 30 ? 1.5 : size * 0.06;
    final decode = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(ring),
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: ClipOval(
        child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: decode, width: size, height: size),
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
    useRootNavigator: true,
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

  /// A new photo picked in this sheet (PNG), not uploaded yet.
  Uint8List? _newPhoto;

  /// The parent chose to remove the current photo.
  bool _removePhoto = false;

  bool get _hasPhoto => _newPhoto != null || (widget.child?.photoUrl != null && !_removePhoto);

  Future<void> _pickPhoto() async {
    final action = await askChildPhotoAction(context, hasPhoto: _hasPhoto);
    if (action == null || !mounted) return;
    if (action == ChildPhotoAction.remove) {
      setState(() {
        _newPhoto = null;
        _removePhoto = true;
      });
      return;
    }
    final source = action == ChildPhotoAction.camera ? ImageSource.camera : ImageSource.gallery;
    final Uint8List? bytes;
    try {
      bytes = await ref.read(childPhotoPickerProvider)(context, source);
    } catch (_) {
      // No camera permission or the picker failed: say so, keep the sheet.
      if (mounted) setState(() => _error = AppLocalizations.of(context).errorGeneric);
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() {
      _newPhoto = bytes;
      _removePhoto = false;
      _error = null;
    });
  }

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
    } on _PhotoUploadFailed {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = AppLocalizations.of(context).childPhotoFailed;
        });
      }
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
    final photo = _newPhoto;
    final remove = _removePhoto && child?.photoUrl != null;
    _run(() async {
      final saved = child == null
          ? await repo.addChild(widget.familyId, firstName: name, birthYear: year, color: _color)
          : await repo.updateChild(widget.familyId, child.id, firstName: name, birthYear: year, color: _color);
      try {
        if (photo != null) {
          await repo.setChildPhoto(widget.familyId, saved.id, photo);
        } else if (remove) {
          await repo.deleteChildPhoto(widget.familyId, saved.id);
        }
      } catch (_) {
        // The child itself is saved; refresh the list so the parent sees it, and say the photo did not make it.
        ref.invalidate(familyProvider(widget.familyId));
        throw _PhotoUploadFailed();
      }
    });
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
    // Scrolls when the keyboard is up or the screen is short, so Save is always reachable.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          HallySpace.lg, 0, HallySpace.lg, MediaQuery.viewInsetsOf(context).bottom + MediaQuery.paddingOf(context).bottom + HallySpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(child == null ? l10n.childAdd : l10n.childEdit, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.md),
          _PhotoField(
            child: child,
            name: _name,
            color: childColor(_color),
            newPhoto: _newPhoto,
            removed: _removePhoto,
            onTap: _busy ? null : _pickPhoto,
          ),
          const SizedBox(height: HallySpace.md),
          TextField(
            key: const Key('child.name'),
            controller: _name,
            autofocus: child == null,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: l10n.childName),
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

class _PhotoUploadFailed implements Exception {}

/// Round photo area at the top of the child sheet: the photo (new, current or none) in a ring of the chosen colour,
/// with a camera badge. Tapping it offers camera, gallery and remove.
class _PhotoField extends ConsumerWidget {
  const _PhotoField({required this.child, required this.name, required this.color, required this.newPhoto, required this.removed, required this.onTap});

  final ChildProfile? child;
  final TextEditingController name;
  final Color color;
  final Uint8List? newPhoto;
  final bool removed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    const size = 88.0;
    final url = removed ? null : child?.photoUrl;
    final current = url == null ? null : ref.watch(childPhotoProvider(url)).valueOrNull;
    final bytes = newPhoto ?? current;
    final hasPhoto = newPhoto != null || url != null;

    Widget avatar;
    if (bytes != null) {
      avatar = ChildPhotoCircle(bytes: bytes, color: color, size: size);
    } else {
      avatar = ValueListenableBuilder<TextEditingValue>(
        valueListenable: name,
        builder: (context, value, _) {
          final text = value.text.trim();
          return Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: HallyColors.softOf(color, theme.brightness), border: Border.all(color: color, width: 3)),
            child: text.isEmpty
                ? Icon(Icons.add_a_photo_rounded, color: color, size: 32)
                : Text(text.characters.first.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 36, height: 1)),
          );
        },
      );
    }

    return Column(
      children: [
        Semantics(
          button: true,
          label: hasPhoto ? l10n.childPhotoChange : l10n.childPhotoAdd,
          child: InkResponse(
            key: const Key('child.photo'),
            onTap: onTap,
            radius: size / 2 + 8,
            child: SizedBox.square(
              dimension: size + 4,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  avatar,
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.surface, border: Border.all(color: theme.colorScheme.outlineVariant)),
                      child: Icon(Icons.photo_camera_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        TextButton(
          key: const Key('child.photo.button'),
          onPressed: onTap,
          child: Text(hasPhoto ? l10n.childPhotoChange : l10n.childPhotoAdd),
        ),
        Text(l10n.childPhotoPrivacy, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
      ],
    );
  }
}
