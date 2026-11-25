import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../messages/chat_photo.dart';
import '../sleep/sleep_screen.dart' show formatSleepMinutes;
import 'handoff_repository.dart';

/// One line per part of the summary, e.g. "2 öğün · Çorba · Biberon 150 ml". Null when nothing was logged.
({String? food, String? sleep, String? meds, String? screen}) handoffLines(BuildContext context, HandoffSummary s) {
  final l10n = AppLocalizations.of(context);
  final tr = Localizations.localeOf(context).languageCode == 'tr';
  final food = [
    if (s.solids > 0) l10n.handoffMeals(s.solids),
    if (s.foods.isNotEmpty) s.foods.join(', '),
    if (s.bottleMl > 0) l10n.handoffBottle(s.bottleMl),
    if (s.breastMinutes > 0) l10n.handoffBreast(s.breastMinutes),
  ].join(' · ');
  final sleep = s.sleeps.isEmpty ? null : '${s.sleeps.join(', ')} (${formatSleepMinutes(s.sleepMinutes, turkish: tr)})';
  return (
    food: food.isEmpty ? null : food,
    sleep: sleep,
    meds: s.doses.isEmpty ? null : s.doses.join('\n'),
    screen: s.screenMinutes == 0 ? null : formatSleepMinutes(s.screenMinutes, turkish: tr),
  );
}

String handoffIncidentLabel(AppLocalizations l10n, HandoffIncident i) => switch (i) {
      HandoffIncident.fall => l10n.handoffIncidentFall,
      HandoffIncident.fever => l10n.handoffIncidentFever,
      HandoffIncident.other => l10n.handoffIncidentOther,
    };

/// The caregiver's "Günü bitir": the day's logs filled in by Hally, plus incidents, a note and a photo.
class HandoffScreen extends ConsumerStatefulWidget {
  const HandoffScreen({super.key, required this.childId});

  final String childId;

  @override
  ConsumerState<HandoffScreen> createState() => _HandoffScreenState();
}

class _HandoffScreenState extends ConsumerState<HandoffScreen> {
  final _note = TextEditingController();
  final _incidents = <HandoffIncident>{};
  PickedPhoto? _photo;
  bool _loaded = false;
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final source = await askPhotoSource(context);
    if (source == null) return;
    final photo = await ref.read(photoPickerProvider)(source);
    if (photo != null && mounted) setState(() => _photo = photo);
  }

  Future<void> _send(String familyId) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      final repo = ref.read(handoffRepositoryProvider);
      final report = await repo.send(familyId, widget.childId, incidents: _incidents, note: _note.text.trim().isEmpty ? null : _note.text.trim());
      if (_photo case final p?) await repo.addPhoto(familyId, report.id, p.bytes, p.fileName, p.contentType);
      ref.invalidate(handoffDraftProvider((familyId, widget.childId)));
      messenger.showSnackBar(SnackBar(content: Text(l10n.handoffSentSnack)));
      if (mounted && context.canPop()) context.pop();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _edit(String familyId, String route) async {
    await context.push(route);
    ref.invalidate(handoffDraftProvider((familyId, widget.childId)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final child = watchChildren(ref, familyId).where((c) => c.id == widget.childId).firstOrNull;
    final key = (familyId, widget.childId);
    final draft = ref.watch(handoffDraftProvider(key));

    // Start from the report already sent today, so a second send is an update.
    if (!_loaded && draft.valueOrNull != null) {
      _loaded = true;
      if (draft.value!.sent case final sent?) {
        _incidents.addAll(sent.incidents);
        _note.text = sent.note ?? '';
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.handoffTitle)),
      body: draft.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(handoffDraftProvider(key))),
        data: (d) {
          final lines = handoffLines(context, d.summary);
          final sent = d.sent;
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
            children: [
              Text(l10n.handoffIntro(child?.firstName ?? ''), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (sent != null) ...[
                const SizedBox(height: HallySpace.sm),
                HallyPill(
                  key: const Key('handoff.sent'),
                  icon: Icons.check_rounded,
                  label: l10n.handoffSentAt(DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(sent.sentAt)),
                  color: HallyColors.sage,
                ),
              ],
              const SizedBox(height: HallySpace.md),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.xs),
                  child: Column(children: [
                    _SummaryRow(key: const Key('handoff.food'), icon: Icons.restaurant_rounded, color: HallyModule.kids, title: l10n.handoffFood,
                        value: lines.food, onEdit: () => _edit(familyId, '/feeding')),
                    _SummaryRow(key: const Key('handoff.sleep'), icon: Icons.bedtime_rounded, color: HallyModule.sleep, title: l10n.handoffSleep,
                        value: lines.sleep, onEdit: () => _edit(familyId, '/sleep')),
                    _SummaryRow(key: const Key('handoff.meds'), icon: Icons.medication_rounded, color: HallyModule.health, title: l10n.handoffMeds,
                        value: lines.meds, onEdit: () => _edit(familyId, '/medications')),
                    _SummaryRow(key: const Key('handoff.screen'), icon: Icons.phone_android_rounded, color: HallyModule.screenTime, title: l10n.handoffScreen,
                        value: lines.screen, onEdit: () => _edit(familyId, '/screen-time'), last: true),
                  ]),
                ),
              ),
              const SizedBox(height: HallySpace.md),
              Text(l10n.handoffIncidentQuestion, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: HallySpace.sm),
              Wrap(
                spacing: HallySpace.sm,
                runSpacing: HallySpace.sm,
                children: [
                  FilterChip(
                    key: const Key('handoff.incident.none'),
                    label: Text(l10n.handoffIncidentNone),
                    selected: _incidents.isEmpty,
                    onSelected: (_) => setState(_incidents.clear),
                  ),
                  for (final i in HandoffIncident.values)
                    FilterChip(
                      key: Key('handoff.incident.${i.name}'),
                      label: Text(handoffIncidentLabel(l10n, i)),
                      selected: _incidents.contains(i),
                      onSelected: (on) => setState(() => on ? _incidents.add(i) : _incidents.remove(i)),
                    ),
                ],
              ),
              const SizedBox(height: HallySpace.md),
              TextField(
                key: const Key('handoff.note'),
                controller: _note,
                maxLines: 4,
                minLines: 2,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: l10n.handoffNote, hintText: l10n.handoffNoteHint),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('handoff.photo'),
                  onPressed: _pickPhoto,
                  icon: _photo == null
                      ? const Icon(Icons.photo_camera_outlined)
                      : ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(_photo!.bytes, width: 28, height: 28, fit: BoxFit.cover)),
                  label: Text(_photo == null && sent?.hasPhoto != true ? l10n.handoffPhoto : l10n.handoffPhotoChange),
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: draft.hasValue
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, HallySpace.md),
                child: FilledButton(
                  key: const Key('handoff.send'),
                  onPressed: _sending ? null : () => _send(familyId),
                  child: Text(draft.value!.sent == null ? l10n.handoffSend : l10n.handoffResend),
                ),
              ),
            )
          : null,
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({super.key, required this.icon, required this.color, required this.title, required this.value, required this.onEdit, this.last = false});

  final IconData icon;
  final Color color;
  final String title;
  final String? value;
  final VoidCallback onEdit;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: HallySpace.sm + 2),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)))),
      child: Row(
        children: [
          HallyIconBadge(icon: icon, color: color, size: 38),
          const SizedBox(width: HallySpace.sm + 4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              Text(value ?? l10n.handoffNothing, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          TextButton(onPressed: onEdit, child: Text(l10n.handoffEdit)),
        ],
      ),
    );
  }
}
