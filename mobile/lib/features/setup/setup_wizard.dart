import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../assistant/briefing.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'focus.dart';

/// A child typed in step 1, before it is saved.
class _KidDraft {
  _KidDraft(this.color);

  final TextEditingController name = TextEditingController();
  final String color;
  int? birthYear;
}

/// "İlk kurulum": three short, skippable steps after a family is created (or later from Today/Profile).
/// 1 · children (only when the family has none yet), 2 · focus areas, 3 · Today preview + morning summary.
/// [next] is where to go when done: the partner invite after a new family, else back.
class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key, required this.familyId, this.next});

  final String familyId;
  final String? next;

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  final _kids = <_KidDraft>[];
  List<FocusArea>? _areas;
  bool _morning = true;
  int _step = 0;
  bool _busy = false;
  bool? _hadChildren;

  @override
  void initState() {
    super.initState();
    _kids.add(_KidDraft(childColorKeys[0]));
  }

  @override
  void dispose() {
    for (final k in _kids) {
      k.name.dispose();
    }
    super.dispose();
  }

  int get _year => DateTime.now().year;

  List<int> _ages(List<ChildProfile> existing) => [
        for (final c in existing)
          if (c.birthYear != null) _year - c.birthYear!,
        for (final k in _kids)
          if (k.name.text.trim().isNotEmpty && k.birthYear != null) _year - k.birthYear!,
      ];

  void _finish() {
    ref.invalidate(focusProvider(widget.familyId));
    if (!mounted) return;
    if (widget.next case final next?) {
      context.go(next);
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/today');
    }
  }

  /// "Atla": nothing is shaped, Today shows everything, and the one-time card does not come back.
  Future<void> _skip() async {
    setState(() => _busy = true);
    try {
      final current = ref.read(focusProvider(widget.familyId)).valueOrNull?.areas ?? const [];
      await ref.read(focusRepositoryProvider).set(widget.familyId, current);
    } catch (_) {
      // Skipping must never trap anyone in the wizard.
    }
    _finish();
  }

  Future<void> _saveKids() async {
    final repo = ref.read(familyRepositoryProvider);
    for (final k in _kids) {
      final name = k.name.text.trim();
      if (name.isEmpty) continue;
      await repo.addChild(widget.familyId, firstName: name, birthYear: k.birthYear, color: k.color);
    }
    ref.invalidate(familyProvider(widget.familyId));
  }

  Future<void> _next(List<ChildProfile> existing) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      if (_step == 0) {
        await _saveKids();
        _areas ??= suggestFocus(_ages(existing));
        setState(() => _step = 1);
      } else if (_step == 1) {
        setState(() => _step = 2);
      } else {
        await ref.read(focusRepositoryProvider).set(widget.familyId, _areas ?? const []);
        try {
          final briefing = ref.read(briefingRepositoryProvider);
          final current = await briefing.time(widget.familyId);
          if (_morning && current == null) await briefing.setTime(widget.familyId, '07:30');
          if (!_morning && current != null) await briefing.setTime(widget.familyId, null);
        } catch (_) {
          // The morning summary can be set later from the assistant.
        }
        _finish();
        return;
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final family = ref.watch(familyProvider(widget.familyId));
    final existing = family.valueOrNull?.children ?? const <ChildProfile>[];
    if (family.isLoading && _hadChildren == null) return const Scaffold(body: HallyLoading());
    if (_hadChildren == null) {
      _hadChildren = existing.isNotEmpty;
      // Children already there (an invited parent, or Profile → "Sihirbazı yeniden aç"): start at the areas.
      if (_hadChildren!) {
        _step = 1;
        _areas ??= ref.read(focusProvider(widget.familyId)).valueOrNull?.areas.toList();
        if (_areas == null || _areas!.isEmpty) _areas = suggestFocus(_ages(existing));
      }
    }
    final first = _hadChildren! ? 1 : 0;
    final steps = 3 - first;
    final areas = _areas ?? const <FocusArea>[];

    final body = switch (_step) {
      0 => _KidsStep(kids: _kids, year: _year, onAdd: () => setState(() => _kids.add(_KidDraft(childColorKeys[_kids.length % childColorKeys.length]))), onChanged: () => setState(() {})),
      1 => _FocusStep(
          selected: areas,
          hint: _hint(l10n, existing),
          onToggle: (a) => setState(() {
            final list = [...areas];
            if (list.contains(a)) {
              list.remove(a);
            } else if (list.length < maxFocusAreas) {
              list.add(a);
            } else {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(l10n.setupFocusMax(maxFocusAreas))));
            }
            _areas = list;
          }),
        ),
      _ => _PreviewStep(areas: areas, morning: _morning, onMorning: (v) => setState(() => _morning = v)),
    };

    return PopScope(
      canPop: _step == first,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: _step > first
              ? IconButton(key: const Key('setup.back'), icon: const Icon(Icons.chevron_left_rounded), onPressed: () => setState(() => _step--))
              : const Padding(padding: EdgeInsets.only(left: HallySpace.md), child: Center(child: HallyMark(size: 24))),
          actions: [
            if (_step < 2) TextButton(key: const Key('setup.skip'), onPressed: _busy ? null : _skip, child: Text(l10n.setupSkip)),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HallySpace.md + 4, 0, HallySpace.md + 4, HallySpace.md),
                child: Row(
                  children: [
                    for (var i = 0; i < steps; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(
                        child: AnimatedContainer(
                          duration: HallyMotion.medium,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i <= _step - first ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(child: body),
              Padding(
                padding: const EdgeInsets.fromLTRB(HallySpace.md + 4, HallySpace.sm, HallySpace.md + 4, HallySpace.md),
                child: FilledButton(
                  key: const Key('setup.next'),
                  onPressed: _busy ? null : () => _next(existing),
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(switch (_step) {
                          0 => l10n.setupContinue,
                          1 => areas.isEmpty ? l10n.setupContinue : l10n.setupContinueCount(areas.length),
                          _ => l10n.setupStart,
                        }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Ela 8, Deniz 2 yaşında diye … seçtik": why the areas came pre-selected.
  String? _hint(AppLocalizations l10n, List<ChildProfile> existing) {
    final named = <String>[
      for (final c in existing)
        if (c.birthYear != null) l10n.setupHintAge(c.firstName, _year - c.birthYear!),
      for (final k in _kids)
        if (k.name.text.trim().isNotEmpty && k.birthYear != null) l10n.setupHintAge(k.name.text.trim(), _year - k.birthYear!),
    ];
    if (named.isEmpty) return null;
    return l10n.setupHint(named.take(3).join(', '));
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, height: 1.15)),
        const SizedBox(height: 6),
        Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: HallySpace.md),
      ],
    );
  }
}

class _KidsStep extends StatelessWidget {
  const _KidsStep({required this.kids, required this.year, required this.onAdd, required this.onChanged});

  final List<_KidDraft> kids;
  final int year;
  final VoidCallback onAdd;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: HallySpace.md + 4),
      children: [
        _StepTitle(title: l10n.setupKidsTitle, body: l10n.setupKidsBody),
        for (final (i, k) in kids.indexed)
          Card(
            margin: const EdgeInsets.only(bottom: HallySpace.sm + 4),
            child: Padding(
              padding: const EdgeInsets.all(HallySpace.md - 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: childColor(k.color)),
                      ),
                      const SizedBox(width: HallySpace.sm + 2),
                      Expanded(
                        child: TextField(
                          key: Key('setup.kidName.$i'),
                          controller: k.name,
                          maxLength: 40,
                          textCapitalization: TextCapitalization.words,
                          onChanged: (_) => onChanged(),
                          decoration: InputDecoration(hintText: l10n.setupKidName, counterText: ''),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: HallySpace.sm),
                  Text(l10n.setupKidYear, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 40,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        for (var y = year; y >= year - 17; y--)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              key: Key('setup.kidYear.$i.$y'),
                              label: Text(k.birthYear == y ? l10n.setupKidYearAge(y, year - y) : '$y'),
                              selected: k.birthYear == y,
                              onSelected: (on) {
                                k.birthYear = on ? y : null;
                                onChanged();
                              },
                            ),
                          ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        OutlinedButton.icon(
          key: const Key('setup.addKid'),
          onPressed: kids.length >= 8 ? null : onAdd,
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.setupKidAdd),
        ),
        const SizedBox(height: HallySpace.md),
        Text(l10n.setupKidsNone, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: HallySpace.lg),
      ],
    );
  }
}

class _FocusStep extends StatelessWidget {
  const _FocusStep({required this.selected, required this.hint, required this.onToggle});

  final List<FocusArea> selected;
  final String? hint;
  final ValueChanged<FocusArea> onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: HallySpace.md + 4),
      children: [
        _StepTitle(title: l10n.setupFocusTitle, body: l10n.setupFocusBody(maxFocusAreas)),
        if (hint != null)
          Container(
            margin: const EdgeInsets.only(bottom: HallySpace.sm + 4),
            padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm + 4, vertical: HallySpace.sm + 2),
            decoration: BoxDecoration(color: HallyColors.softOf(HallyModule.assistant, brightness), borderRadius: BorderRadius.circular(HallyRadius.md)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, size: 20, color: HallyColors.readableOn(HallyModule.assistant, brightness)),
                const SizedBox(width: HallySpace.sm),
                Expanded(child: Text(hint!, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 9,
          crossAxisSpacing: 9,
          childAspectRatio: 0.92,
          children: [
            for (final a in FocusArea.values)
              _AreaTile(key: Key('setup.area.${a.id}'), area: a, selected: selected.contains(a), onTap: () => onToggle(a)),
          ],
        ),
        const SizedBox(height: HallySpace.lg),
      ],
    );
  }
}

class _AreaTile extends StatelessWidget {
  const _AreaTile({super.key, required this.area, required this.selected, required this.onTap});

  final FocusArea area;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final primary = theme.colorScheme.primary;
    return Semantics(
      selected: selected,
      button: true,
      child: HallyPressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: HallyMotion.fast,
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
          decoration: BoxDecoration(
            color: selected ? HallyColors.softOf(area.color, brightness) : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(HallyRadius.lg),
            border: Border.all(color: selected ? primary : theme.colorScheme.outlineVariant, width: selected ? 2 : 1),
          ),
          child: Stack(
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FocusAreaIcon(area: area, size: 28),
                  const SizedBox(height: 6),
                  Text(
                    area.label(l10n),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
                  ),
                ],
              ),
              if (selected)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded, size: 14, color: theme.colorScheme.onPrimary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewStep extends StatelessWidget {
  const _PreviewStep({required this.areas, required this.morning, required this.onMorning});

  final List<FocusArea> areas;
  final bool morning;
  final ValueChanged<bool> onMorning;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: HallySpace.md + 4),
      children: [
        _StepTitle(title: l10n.setupPreviewTitle, body: areas.isEmpty ? l10n.setupPreviewAll : l10n.setupPreviewBody),
        if (areas.isNotEmpty) ...[
          Text(l10n.focusShortcutsTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: HallySpace.sm),
          FocusShortcutRow(areas: areas, familyId: null),
          const SizedBox(height: HallySpace.md),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final a in areas)
                  ListTile(
                    leading: FocusAreaIcon(area: a, size: 22),
                    title: Text(a.label(l10n)),
                    subtitle: Text(a.shortcuts.map((s) => shortcutLabel(l10n, s.key)).join(' · ')),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: HallySpace.md),
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            key: const Key('setup.morning'),
            value: morning,
            onChanged: onMorning,
            title: Text(l10n.setupMorningTitle),
            subtitle: Text(l10n.setupMorningBody),
          ),
        ),
        const SizedBox(height: HallySpace.lg),
      ],
    );
  }
}

/// "Senin kısayolların": the chosen areas' screens as pastel buttons. [familyId] null = preview (not tappable).
class FocusShortcutRow extends StatelessWidget {
  const FocusShortcutRow({super.key, required this.areas, required this.familyId});

  final List<FocusArea> areas;
  final String? familyId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final items = [for (final a in areas) for (final s in a.shortcuts) (a, s)];
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: HallySpace.sm),
        itemBuilder: (context, i) {
          final (a, s) = items[i];
          final id = familyId;
          return HallyPressable(
            key: Key('focus.shortcut.${s.key}'),
            onTap: id == null ? null : () => context.push(s.routeFor(id)),
            child: Container(
              constraints: const BoxConstraints(minWidth: 88),
              padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm + 4, vertical: HallySpace.sm + 2),
              decoration: BoxDecoration(color: HallyColors.softOf(a.color, brightness), borderRadius: BorderRadius.circular(HallyRadius.md)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(s.icon, size: 22, color: HallyColors.readableOn(a.color, brightness)),
                  const SizedBox(height: 4),
                  Text(shortcutLabel(l10n, s.key), style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
