import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'focus.dart';
import 'setup_wizard.dart';

/// Profile → "Bugün ekranım": turn areas on and off and drag them into order. Any number may be on here;
/// the four-area limit is only the wizard's nudge to start small.
class TodayFocusScreen extends ConsumerStatefulWidget {
  const TodayFocusScreen({super.key});

  @override
  ConsumerState<TodayFocusScreen> createState() => _TodayFocusScreenState();
}

class _TodayFocusScreenState extends ConsumerState<TodayFocusScreen> {
  /// Every area in display order; the chosen ones first, in their order.
  List<FocusArea>? _order;
  Set<FocusArea>? _on;

  Future<void> _save(String familyId) async {
    final chosen = [for (final a in _order!) if (_on!.contains(a)) a];
    try {
      await ref.read(focusRepositoryProvider).set(familyId, chosen);
      ref.invalidate(focusProvider(familyId));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final focus = ref.watch(focusProvider(familyId));
    if (_order == null) {
      final f = focus.valueOrNull;
      if (f == null) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.focusSettingsTitle)),
          body: focus.hasError ? HallyErrorState(onRetry: () => ref.invalidate(focusProvider(familyId))) : const HallyLoading(),
        );
      }
      _order = [...f.areas, ...FocusArea.values.where((a) => !f.areas.contains(a))];
      _on = f.areas.toSet();
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.focusSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
        children: [
          Text(l10n.focusSettingsBody, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (_on!.isEmpty) ...[
            const SizedBox(height: HallySpace.sm),
            Text(l10n.focusSettingsAll, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: HallySpace.md),
          Card(
            margin: EdgeInsets.zero,
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                setState(() => _order!.insert(to, _order!.removeAt(from)));
                _save(familyId);
              },
              children: [
                for (final (i, a) in _order!.indexed)
                  ListTile(
                    key: ValueKey(a.id),
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.drag_indicator_rounded, color: theme.colorScheme.outline),
                          const SizedBox(width: HallySpace.sm),
                          FocusAreaIcon(area: a, size: 20),
                        ],
                      ),
                    ),
                    title: Text(a.label(l10n)),
                    trailing: Switch(
                      key: Key('focus.toggle.${a.id}'),
                      value: _on!.contains(a),
                      onChanged: (v) {
                        setState(() => v ? _on!.add(a) : _on!.remove(a));
                        _save(familyId);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: HallySpace.md),
          OutlinedButton(
            key: const Key('focus.rerunWizard'),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SetupWizardScreen(familyId: familyId)));
              if (mounted) setState(() => _order = null);
            },
            child: Text(l10n.focusRerunWizard),
          ),
        ],
      ),
    );
  }
}

/// Aile → "Tüm özellikler": every area with its screens, so nothing hidden from Today is out of reach.
class AllFeaturesScreen extends ConsumerWidget {
  const AllFeaturesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    return Scaffold(
      appBar: AppBar(title: Text(l10n.allFeaturesTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
        children: [
          for (final a in FocusArea.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: HallySpace.md, bottom: HallySpace.sm),
              child: Row(
                children: [
                  FocusAreaIcon(area: a, size: 20),
                  const SizedBox(width: HallySpace.sm),
                  Text(a.label(l10n), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            FocusShortcutRow(areas: [a], familyId: familyId),
          ],
          const SizedBox(height: HallySpace.lg),
          TextButton(onPressed: () => context.push('/today-focus'), child: Text(l10n.focusSettingsTitle)),
        ],
      ),
    );
  }
}
