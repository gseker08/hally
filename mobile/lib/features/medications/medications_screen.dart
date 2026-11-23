import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'medications_repository.dart';

/// "14:05", or "23 Kas 14:05" when it is not today.
String formatDoseTime(BuildContext context, DateTime t, {DateTime? now}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final n = now ?? DateTime.now();
  final sameDay = t.year == n.year && t.month == n.month && t.day == n.day;
  return sameDay ? DateFormat.Hm(locale).format(t) : DateFormat.MMMd(locale).add_Hm().format(t);
}

/// Hours like "6 sa" / "6 h"; minutes when not whole hours.
String formatInterval(AppLocalizations l10n, int minutes) =>
    minutes % 60 == 0 ? l10n.medicationHours(minutes ~/ 60) : l10n.medicationMinutes(minutes);

class MedicationsScreen extends ConsumerStatefulWidget {
  const MedicationsScreen({super.key});

  @override
  ConsumerState<MedicationsScreen> createState() => _MedicationsScreenState();
}

class _MedicationsScreenState extends ConsumerState<MedicationsScreen> {
  // "May be given now" changes with the clock, not only with data.
  late final Timer _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final meds = ref.watch(medicationsProvider(familyId));
    final filter = ref.watch(childFilterProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.medicationsTitle)),
      floatingActionButton: children.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('medication.add'),
              onPressed: () => showMedicationSheet(context, ref, familyId: familyId, children: children),
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.medicationAdd),
            ),
      body: children.isEmpty
          ? HallyEmptyState(icon: Icons.medication_outlined, title: l10n.medicationsTitle, body: l10n.medicationsNoChildren)
          : meds.when(
              loading: () => const HallyLoading(),
              error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(medicationsProvider(familyId))),
              data: (all) {
                final list = filter == null ? all : all.where((m) => m.childId == filter).toList();
                final byId = {for (final c in children) c.id: c};
                return RefreshIndicator(
                  onRefresh: () => ref.refresh(medicationsProvider(familyId).future),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(0, HallySpace.sm, 0, 120),
                    children: [
                      ChildFilterBar(familyId: familyId),
                      if (list.isEmpty)
                        HallyEmptyState(icon: Icons.medication_outlined, title: l10n.medicationsEmpty, body: l10n.medicationsEmptyBody)
                      else
                        for (final m in list)
                          if (byId[m.childId] case final child?)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: HallySpace.md),
                              child: MedicationCard(familyId: familyId, medication: m, child: child, children: children),
                            ),
                      Padding(
                        padding: const EdgeInsets.all(HallySpace.md),
                        child: Text(l10n.medicationDisclaimer, style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class MedicationCard extends ConsumerStatefulWidget {
  const MedicationCard({super.key, required this.familyId, required this.medication, required this.child, required this.children});

  final String familyId;
  final Medication medication;
  final ChildProfile child;
  final List<ChildProfile> children;

  @override
  ConsumerState<MedicationCard> createState() => _MedicationCardState();
}

class _MedicationCardState extends ConsumerState<MedicationCard> {
  bool _busy = false;

  Future<void> _give() async {
    final l10n = AppLocalizations.of(context);
    final repo = ref.read(medicationsRepositoryProvider);
    setState(() => _busy = true);
    try {
      try {
        await repo.give(widget.familyId, widget.medication.id);
      } on DoseWarning catch (w) {
        if (!mounted) return;
        final ok = await _confirmEarly(w);
        if (ok != true) return;
        await repo.give(widget.familyId, widget.medication.id, force: true);
      }
      ref.invalidate(medicationsProvider(widget.familyId));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.medicationGiven(widget.medication.name))));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmEarly(DoseWarning w) {
    final l10n = AppLocalizations.of(context);
    final who = w.lastDose.givenByName ?? l10n.medicationSomeone;
    final at = formatDoseTime(context, w.lastDose.givenAt);
    final next = w.nextAllowedAt == null ? null : formatDoseTime(context, w.nextAllowedAt!);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: HallyColors.apricot),
        title: Text(w.isDailyLimit ? l10n.medicationLimitTitle : l10n.medicationTooSoonTitle),
        content: Text([l10n.medicationLastGivenBy(who, at), if (next != null) l10n.medicationNextAfter(next)].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
          TextButton(key: const Key('medication.force'), onPressed: () => Navigator.pop(context, true), child: Text(l10n.medicationSaveAnyway)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final m = widget.medication;
    final now = DateTime.now();
    final canGive = m.canGiveAt(now);
    final last = m.lastDose;
    return Card(
      child: InkWell(
        key: Key('medication.${m.id}'),
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        onTap: () => showDoseHistory(context, ref, familyId: widget.familyId, medication: m, child: widget.child, children: widget.children),
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md),
          child: Row(
            children: [
              ChildBadge(child: widget.child, size: 36),
              const SizedBox(width: HallySpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.dose == null ? m.name : '${m.name} · ${m.dose}', style: theme.textTheme.titleSmall),
                    Text(
                      last == null
                          ? l10n.medicationNoDoseYet
                          : l10n.medicationLastGivenBy(last.givenByName ?? l10n.medicationSomeone, formatDoseTime(context, last.givenAt, now: now)),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      canGive ? l10n.medicationCanGiveNow : l10n.medicationNextAfter(formatDoseTime(context, m.nextAllowedAt!, now: now)),
                      key: Key('medication.status.${m.id}'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: canGive ? HallyColors.mintDeep : HallyColors.apricot,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HallySpace.sm),
              FilledButton.icon(
                key: Key('medication.give.${m.id}'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: HallySpace.md),
                  backgroundColor: canGive ? null : theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: canGive ? null : theme.colorScheme.onSurface,
                ),
                onPressed: _busy ? null : _give,
                icon: const Icon(Icons.check_rounded),
                label: Text(l10n.medicationGive),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dose history with undo, plus edit and "end course".
Future<void> showDoseHistory(BuildContext context, WidgetRef ref,
    {required String familyId, required Medication medication, required ChildProfile child, required List<ChildProfile> children}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _DoseHistory(familyId: familyId, medication: medication, child: child, children: children),
  );
}

class _DoseHistory extends ConsumerWidget {
  const _DoseHistory({required this.familyId, required this.medication, required this.child, required this.children});

  final String familyId;
  final Medication medication;
  final ChildProfile child;
  final List<ChildProfile> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final m = medication;
    final doses = ref.watch(medicationDosesProvider((familyId, m.id)));
    final rule = [
      l10n.medicationEvery(formatInterval(l10n, m.minIntervalMinutes)),
      if (m.maxDosesPerDay != null) l10n.medicationMaxPerDay(m.maxDosesPerDay!),
    ].join(' · ');
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        children: [
          Row(
            children: [
              ChildBadge(child: child, size: 32),
              const SizedBox(width: HallySpace.sm),
              Expanded(child: Text(m.dose == null ? m.name : '${m.name} · ${m.dose}', style: theme.textTheme.titleLarge)),
            ],
          ),
          const SizedBox(height: HallySpace.xs),
          Text(rule, style: theme.textTheme.bodySmall),
          if (m.notes != null) Text(m.notes!, style: theme.textTheme.bodySmall),
          Wrap(
            spacing: HallySpace.xs,
            children: [
              TextButton.icon(
                key: const Key('medication.edit'),
                onPressed: () async {
                  Navigator.pop(context);
                  await showMedicationSheet(context, ref, familyId: familyId, children: children, medication: m);
                },
                icon: const Icon(Icons.edit_outlined),
                label: Text(l10n.medicationEdit),
              ),
              TextButton.icon(
                key: const Key('medication.end'),
                onPressed: () async {
                  await ref.read(medicationsRepositoryProvider).update(familyId, m.id, MedicationInput(
                        childId: m.childId,
                        name: m.name,
                        dose: m.dose,
                        minIntervalMinutes: m.minIntervalMinutes,
                        maxDosesPerDay: m.maxDosesPerDay,
                        remindNextDose: m.remindNextDose,
                        notes: m.notes,
                        active: false,
                      ));
                  ref.invalidate(medicationsProvider(familyId));
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: Text(l10n.medicationEnd),
              ),
            ],
          ),
          const Divider(),
          Text(l10n.medicationHistory, style: theme.textTheme.labelLarge),
          doses.when(
            loading: () => const Padding(padding: EdgeInsets.all(HallySpace.lg), child: HallyLoading()),
            error: (_, __) => Text(l10n.errorGeneric),
            data: (list) => list.isEmpty
                ? Padding(padding: const EdgeInsets.symmetric(vertical: HallySpace.md), child: Text(l10n.medicationNoDoseYet))
                : Column(
                    children: [
                      for (final d in list)
                        ListTile(
                          key: Key('dose.${d.id}'),
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(d.overrodeWarning ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
                              color: d.overrodeWarning ? HallyColors.apricot : HallyColors.mint),
                          title: Text(formatDoseTime(context, d.givenAt)),
                          subtitle: Text([d.givenByName ?? l10n.medicationSomeone, if (d.note != null) d.note!].join(' · ')),
                          trailing: IconButton(
                            key: Key('dose.delete.${d.id}'),
                            tooltip: l10n.medicationUndoDose,
                            icon: const Icon(Icons.undo_rounded),
                            onPressed: () async {
                              await ref.read(medicationsRepositoryProvider).deleteDose(familyId, m.id, d.id);
                              ref.invalidate(medicationDosesProvider((familyId, m.id)));
                              ref.invalidate(medicationsProvider(familyId));
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

const _intervalChoices = [4, 6, 8, 12, 24];
const _maxChoices = [2, 3, 4, 5];

/// Add or edit a medication. The interval is the parents' own rule; Hally does not suggest one.
Future<void> showMedicationSheet(BuildContext context, WidgetRef ref,
    {required String familyId, required List<ChildProfile> children, Medication? medication}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MedicationSheet(familyId: familyId, children: children, medication: medication),
  );
  if (saved == true) ref.invalidate(medicationsProvider(familyId));
}

class _MedicationSheet extends ConsumerStatefulWidget {
  const _MedicationSheet({required this.familyId, required this.children, this.medication});

  final String familyId;
  final List<ChildProfile> children;
  final Medication? medication;

  @override
  ConsumerState<_MedicationSheet> createState() => _MedicationSheetState();
}

class _MedicationSheetState extends ConsumerState<_MedicationSheet> {
  late final _name = TextEditingController(text: widget.medication?.name ?? '');
  late final _dose = TextEditingController(text: widget.medication?.dose ?? '');
  late final _notes = TextEditingController(text: widget.medication?.notes ?? '');
  late String? _childId = widget.medication?.childId ?? ref.read(childFilterProvider) ?? (widget.children.length == 1 ? widget.children.first.id : null);
  late int? _hours = widget.medication == null ? null : widget.medication!.minIntervalMinutes ~/ 60;
  late int? _max = widget.medication?.maxDosesPerDay;
  late bool _remind = widget.medication?.remindNextDose ?? true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _dose.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (_childId == null || _name.text.trim().isEmpty || _hours == null) {
      setState(() => _error = l10n.medicationMissing);
      return;
    }
    final input = MedicationInput(
      childId: _childId!,
      name: _name.text.trim(),
      dose: _dose.text.trim().isEmpty ? null : _dose.text.trim(),
      minIntervalMinutes: _hours! * 60,
      maxDosesPerDay: _max,
      remindNextDose: _remind,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(medicationsRepositoryProvider);
      final m = widget.medication;
      m == null ? await repo.create(widget.familyId, input) : await repo.update(widget.familyId, m.id, input);
      if (mounted) Navigator.pop(context, true);
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
    final editing = widget.medication != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, MediaQuery.viewInsetsOf(context).bottom + HallySpace.lg),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? l10n.medicationEdit : l10n.medicationAdd, style: theme.textTheme.titleLarge),
            const SizedBox(height: HallySpace.sm),
            if (!editing)
              Wrap(
                spacing: HallySpace.sm,
                children: [
                  for (final c in widget.children)
                    ChoiceChip(
                      key: Key('medication.child.${c.id}'),
                      avatar: ChildBadge(child: c, size: 20),
                      label: Text(c.firstName),
                      selected: _childId == c.id,
                      onSelected: (_) => setState(() => _childId = c.id),
                    ),
                ],
              ),
            TextField(
              key: const Key('medication.name'),
              controller: _name,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.medicationName, hintText: l10n.medicationNameHint),
            ),
            TextField(
              key: const Key('medication.dose'),
              controller: _dose,
              maxLength: 40,
              decoration: InputDecoration(labelText: l10n.medicationDose, hintText: l10n.medicationDoseHint),
            ),
            Text(l10n.medicationInterval, style: theme.textTheme.labelLarge),
            const SizedBox(height: HallySpace.xs),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.xs,
              children: [
                for (final h in _intervalChoices)
                  ChoiceChip(
                    key: Key('medication.interval.$h'),
                    label: Text(l10n.medicationHours(h)),
                    selected: _hours == h,
                    onSelected: (_) => setState(() => _hours = h),
                  ),
              ],
            ),
            const SizedBox(height: HallySpace.sm),
            Text(l10n.medicationMaxLabel, style: theme.textTheme.labelLarge),
            const SizedBox(height: HallySpace.xs),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.xs,
              children: [
                ChoiceChip(label: Text(l10n.medicationNoMax), selected: _max == null, onSelected: (_) => setState(() => _max = null)),
                for (final n in _maxChoices)
                  ChoiceChip(key: Key('medication.max.$n'), label: Text('$n'), selected: _max == n, onSelected: (_) => setState(() => _max = n)),
              ],
            ),
            SwitchListTile(
              key: const Key('medication.remind'),
              contentPadding: EdgeInsets.zero,
              value: _remind,
              onChanged: (v) => setState(() => _remind = v),
              title: Text(l10n.medicationRemind),
            ),
            TextField(
              key: const Key('medication.notes'),
              controller: _notes,
              maxLength: 300,
              maxLines: 2,
              decoration: InputDecoration(labelText: l10n.medicationNotes),
            ),
            Text(l10n.medicationDisclaimer, style: theme.textTheme.bodySmall),
            if (_error != null) ...[
              const SizedBox(height: HallySpace.sm),
              Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.error)),
            ],
            const SizedBox(height: HallySpace.md),
            FilledButton(key: const Key('medication.save'), onPressed: _busy ? null : _save, child: Text(l10n.eventSave)),
          ],
        ),
      ),
    );
  }
}
