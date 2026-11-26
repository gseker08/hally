import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart' show isCaregiverProvider;
import 'handoff_repository.dart';
import 'handoff_screen.dart';
import '../../core/locale/units.dart';

/// Caregiver's Today: one "Günü bitir" row per child they look after; a sent report shows a tick and can be updated.
class CaregiverHandoffCard extends ConsumerWidget {
  const CaregiverHandoffCard({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final children = watchChildren(ref, familyId);
    if (children.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const Key('handoff.card'),
      margin: const EdgeInsets.only(top: HallySpace.sm, bottom: HallySpace.sm),
      padding: const EdgeInsets.all(HallySpace.md),
      decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.cherry, b), borderRadius: BorderRadius.circular(HallyRadius.lg)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.nights_stay_rounded, color: HallyColors.readableOn(HallyColors.cherry, b)),
            const SizedBox(width: HallySpace.sm),
            Text(l10n.handoffTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ]),
          for (final c in children) ...[
            const SizedBox(height: HallySpace.sm),
            Builder(builder: (context) {
              final sent = ref.watch(handoffDraftProvider((familyId, c.id))).valueOrNull?.sent;
              return Row(children: [
                Expanded(
                  child: Text(
                    sent != null ? l10n.handoffCardDone(c.firstName) : l10n.handoffCardBody(c.firstName),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: HallySpace.sm),
                sent != null
                    ? OutlinedButton(
                        key: Key('handoff.open.${c.id}'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: () => context.push('/handoff/${c.id}'),
                        child: Text(l10n.handoffEdit),
                      )
                    : FilledButton(
                        key: Key('handoff.open.${c.id}'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: () => context.push('/handoff/${c.id}'),
                        child: Text(l10n.handoffTitle),
                      ),
              ]);
            }),
          ],
        ],
      ),
    );
  }
}

/// Parents' Today: today's caregiver reports until a parent says thanks.
class ParentHandoffCards extends ConsumerWidget {
  const ParentHandoffCards({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = (ref.watch(todayHandoffsProvider(familyId)).valueOrNull ?? const []).where((r) => r.thankedAt == null).toList();
    if (reports.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final r in reports)
        Padding(
          padding: const EdgeInsets.only(top: HallySpace.sm),
          child: HandoffReportCard(
            familyId: familyId,
            report: r,
            onChanged: () => ref.invalidate(todayHandoffsProvider(familyId)),
          ),
        ),
    ]);
  }
}

/// One report as parents see it: four pastel tiles, the incident box (orange, never red), the note, the photo, and
/// "Teşekkürler" / "Mesaj yaz".
class HandoffReportCard extends ConsumerWidget {
  const HandoffReportCard({super.key, required this.familyId, required this.report, this.onChanged, this.actions = true});

  final String familyId;
  final HandoffReport report;
  final VoidCallback? onChanged;
  final bool actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final r = report;
    final s = r.summary;
    final lines = handoffLines(context, s);
    final lang = langOf(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final food = s.solids > 0 ? l10n.handoffMeals(s.solids) : (s.bottleMl > 0 ? l10n.handoffBottle(s.bottleMl) : lines.food);

    Widget tile(String label, String? value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: HallyColors.softOf(color, b), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: HallyColors.readableOn(color, b), fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(value ?? '–', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        );

    Future<void> thanks() async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref.read(handoffRepositoryProvider).thanks(familyId, r.id);
        onChanged?.call();
      } catch (_) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
    }

    return Card(
      key: Key('handoff.report.${r.id}'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HallyRadius.md),
        side: BorderSide(color: HallyColors.softOf(HallyColors.cherry, b), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              HallyAvatar(name: r.byName, size: 36),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l10n.handoffFinished(r.byFirstName), style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${r.childName} · ${actions ? DateFormat.Hm(locale).format(r.sentAt) : DateFormat.MMMEd(locale).format(r.day)}',
                      style: theme.textTheme.bodySmall),
                ]),
              ),
              HallyPill(label: l10n.roleCaregiver, color: HallyColors.mist),
            ]),
            const SizedBox(height: HallySpace.md),
            Row(children: [
              tile(l10n.handoffFood, food, HallyColors.peach),
              const SizedBox(width: HallySpace.sm),
              tile(l10n.handoffSleep, s.sleepMinutes > 0 ? formatSleep(s.sleepMinutes, lang) : null, HallyColors.lavender),
            ]),
            const SizedBox(height: HallySpace.sm),
            Row(children: [
              tile(l10n.handoffMeds, s.doses.isEmpty ? null : l10n.handoffDoses(s.doses.length), HallyColors.powder),
              const SizedBox(width: HallySpace.sm),
              tile(l10n.handoffScreen, lines.screen, HallyColors.mist),
            ]),
            if (r.incidents.isNotEmpty || (r.note?.isNotEmpty ?? false)) ...[
              const SizedBox(height: HallySpace.sm),
              Container(
                key: const Key('handoff.incidentBox'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: r.incidents.isNotEmpty ? HallyColors.softOf(HallyColors.peach, b) : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (r.incidents.isNotEmpty)
                    Text(r.incidents.map((i) => handoffIncidentLabel(l10n, i)).join(' · '),
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.readableOn(HallyColors.peach, b))),
                  if (r.note?.isNotEmpty ?? false) Text(r.note!, style: theme.textTheme.bodyMedium),
                ]),
              ),
            ],
            if (r.hasPhoto) ...[
              const SizedBox(height: HallySpace.sm),
              _ReportPhoto(familyId: familyId, reportId: r.id),
            ],
            if (actions) ...[
              const SizedBox(height: HallySpace.md),
              Row(children: [
                Expanded(
                  child: r.thankedAt == null
                      ? FilledButton(key: Key('handoff.thanks.${r.id}'), style: FilledButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: thanks, child: Text(l10n.handoffThanks))
                      : Center(child: Text(l10n.handoffThanked, style: theme.textTheme.bodyMedium)),
                ),
                const SizedBox(width: HallySpace.sm),
                Expanded(
                  child: OutlinedButton(
                    key: Key('handoff.write.${r.id}'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: () => context.push('/chats/${r.byUserId}', extra: r.byName),
                    child: Text(l10n.handoffWrite),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  static String formatSleep(int minutes, String lang) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final u = durationUnits(lang);
    if (h == 0) return '$m ${u.min}';
    if (m == 0) return '$h ${u.h}';
    return '$h ${u.h} $m ${u.min}';
  }
}

class _ReportPhoto extends ConsumerWidget {
  const _ReportPhoto({required this.familyId, required this.reportId});

  final String familyId;
  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(handoffPhotoProvider((familyId, reportId))).valueOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 160,
        child: bytes == null || bytes.isEmpty
            ? ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4))
            : Image.memory(bytes, fit: BoxFit.cover, width: double.infinity),
      ),
    );
  }
}

/// Every caregiver report, or one child's. Reached from the child's insights page and from the push.
class HandoffHistoryScreen extends ConsumerWidget {
  const HandoffHistoryScreen({super.key, this.childId});

  final String? childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final parent = !ref.watch(isCaregiverProvider);
    final key = (familyId, childId ?? '');
    final data = ref.watch(handoffHistoryProvider(key));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.handoffHistory)),
      body: data.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(handoffHistoryProvider(key))),
        data: (reports) => reports.isEmpty
            ? Center(child: Text(l10n.handoffHistoryEmpty, key: const Key('handoff.history.empty')))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
                itemCount: reports.length,
                separatorBuilder: (_, __) => const SizedBox(height: HallySpace.sm),
                itemBuilder: (_, i) => HandoffReportCard(
                  familyId: familyId,
                  report: reports[i],
                  actions: parent && reports[i].thankedAt == null,
                  onChanged: () => ref.invalidate(handoffHistoryProvider(key)),
                ),
              ),
      ),
    );
  }
}
