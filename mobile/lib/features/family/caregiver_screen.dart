import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'family_repository.dart';
import 'invite_partner_screen.dart';

/// A parent's view of one caregiver: what they can and can't do, their end date, children and health permission.
class CaregiverScreen extends ConsumerStatefulWidget {
  const CaregiverScreen({super.key, required this.familyId, required this.userId});

  final String familyId;
  final String userId;

  @override
  ConsumerState<CaregiverScreen> createState() => _CaregiverScreenState();
}

class _CaregiverScreenState extends ConsumerState<CaregiverScreen> {
  bool _busy = false;

  Future<void> _save(FamilyMember m, {DateTime? until, bool clearUntil = false, List<String>? childIds, bool? health}) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(familyRepositoryProvider).setCaregiverAccess(
            widget.familyId,
            m.userId,
            CaregiverAccess(
              until: clearUntil ? null : (until ?? m.accessUntil),
              childIds: childIds ?? m.childIds,
              canSeeHealth: health ?? m.canSeeHealth,
            ),
          );
      ref.invalidate(familyProvider(widget.familyId));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.caregiverSaved)));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _period(FamilyMember m, AccessPeriod p) async {
    final now = DateTime.now();
    switch (p) {
      case AccessPeriod.forever:
        await _save(m, clearUntil: true);
      case AccessPeriod.oneMonth:
        await _save(m, until: DateTime(now.year, now.month + 1, now.day, 23, 59));
      case AccessPeriod.threeMonths:
        await _save(m, until: DateTime(now.year, now.month + 3, now.day, 23, 59));
      case AccessPeriod.custom:
        final picked = await showDatePicker(
          context: context,
          initialDate: m.accessUntil ?? now.add(const Duration(days: 30)),
          firstDate: now.add(const Duration(days: 1)),
          lastDate: now.add(const Duration(days: 3 * 365)),
        );
        if (picked != null) await _save(m, until: DateTime(picked.year, picked.month, picked.day, 23, 59));
    }
  }

  Future<void> _remove(FamilyMember m) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.caregiverRemoveConfirm(m.displayName)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancel)),
          FilledButton(key: const Key('caregiver.remove.confirm'), onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.caregiverRemove)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(familyRepositoryProvider).removeCaregiver(widget.familyId, m.userId);
      ref.invalidate(familyProvider(widget.familyId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.caregiverRemoved)));
      context.pop();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final family = ref.watch(familyProvider(widget.familyId)).valueOrNull;
    final m = family?.members.where((x) => x.userId == widget.userId).firstOrNull;
    if (family == null || m == null) return const Scaffold(body: HallyLoading());
    final locale = Localizations.localeOf(context).toLanguageTag();
    final period = m.accessUntil == null ? AccessPeriod.forever : AccessPeriod.custom;

    Widget list(String text, IconData icon, Color color) => Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.sm),
            child: Column(
              children: [
                for (final line in text.split('\n'))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: HallySpace.sm), Expanded(child: Text(line))]),
                  ),
              ],
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(m.displayName),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: HallySpace.md),
            child: HallyPill(label: l10n.roleCaregiver, color: HallyColors.mist),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, HallySpace.xl),
          children: [
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: Text(
                  m.accessUntil == null ? l10n.caregiverDetailNoEnd : l10n.caregiverDetailEnds(formatShortDate(m.accessUntil!, locale)),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            HallySectionHeader(title: l10n.caregiverEndTitle),
            AccessPeriodChips(period: period, customUntil: m.accessUntil, onChanged: (p) => _period(m, p), onPickDate: () => _period(m, AccessPeriod.custom)),
            if (family.children.isNotEmpty) ...[
              HallySectionHeader(title: l10n.inviteCaregiverChildren),
              Wrap(
                spacing: HallySpace.sm,
                runSpacing: HallySpace.sm,
                children: [
                  for (final c in family.children)
                    FilterChip(
                      key: Key('caregiver.child.${c.id}'),
                      label: Text(c.firstName),
                      selected: m.childIds.isEmpty || m.childIds.contains(c.id),
                      onSelected: (on) {
                        final ids = {...(m.childIds.isEmpty ? family.children.map((x) => x.id) : m.childIds)};
                        on ? ids.add(c.id) : ids.remove(c.id);
                        if (ids.isEmpty) return; // a caregiver looks after at least one child
                        _save(m, childIds: ids.length == family.children.length ? const [] : ids.toList());
                      },
                    ),
                ],
              ),
            ],
            HallySectionHeader(title: l10n.caregiverCanTitle),
            list(l10n.caregiverCanList, Icons.check_rounded, HallyColors.readableOn(HallyColors.sage, theme.brightness)),
            HallySectionHeader(title: l10n.caregiverCannotTitle),
            list(l10n.caregiverCannotList, Icons.close_rounded, theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: HallySpace.sm),
            SwitchListTile(
              key: const Key('caregiver.health'),
              contentPadding: EdgeInsets.zero,
              value: m.canSeeHealth,
              onChanged: (v) => _save(m, health: v),
              title: Text(l10n.caregiverHealthTitle),
              subtitle: Text(l10n.caregiverHealthBody),
            ),
            const SizedBox(height: HallySpace.md),
            OutlinedButton.icon(
              key: const Key('caregiver.remove'),
              onPressed: () => _remove(m),
              icon: const Icon(Icons.person_remove_outlined),
              label: Text(l10n.caregiverRemove),
            ),
          ],
        ),
      ),
    );
  }
}
