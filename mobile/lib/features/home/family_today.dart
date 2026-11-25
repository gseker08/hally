import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import '../kids/kids_screen.dart' show kidsSelectedProvider;
import '../planning/planning_repository.dart';

/// "Ailem bugün": everyone in the family at a glance, right under the day's counts on Today.
/// Children show what is tagged with them today and open their page on the Kids tab; adults show the tasks
/// assigned to them and open the Family tab. Used to live at the bottom of the Family tab only.
class FamilyTodayCard extends ConsumerWidget {
  const FamilyTodayCard({super.key, required this.familyId, required this.data});

  final String familyId;
  final TodayData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider(familyId)).valueOrNull;
    if (family == null) return const SizedBox.shrink();
    final caregiver = ref.watch(isCaregiverProvider);
    final adults = caregiver ? const <FamilyMember>[] : family.members;
    if (family.children.isEmpty && adults.length < 2) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tasks = [...data.overdue, ...data.dueToday];

    final people = <Widget>[
      for (final c in family.children)
        _Person(
          key: Key('today.family.child.${c.id}'),
          avatar: ChildBadge(child: c, size: 36),
          name: c.firstName,
          ring: childColor(c.color),
          line: _line(
            l10n,
            tasks.where((t) => t.childIds.contains(c.id)).length,
            data.events.where((e) => e.childIds.contains(c.id)).length,
          ),
          onTap: () {
            ref.read(kidsSelectedProvider.notifier).state = c.id;
            context.go('/kids');
          },
        ),
      for (final m in adults)
        _Person(
          key: Key('today.family.member.${m.userId}'),
          avatar: HallyAvatar(name: m.displayName, size: 36),
          name: m.displayName.trim().split(' ').first,
          ring: theme.colorScheme.outlineVariant,
          line: _line(l10n, tasks.where((t) => t.assigneeUserId == m.userId).length, 0),
          onTap: () => context.go('/family'),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: HallySpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, size: 16, color: HallyColors.accent(HallyColors.cherry, theme.brightness)),
              const SizedBox(width: 6),
              Expanded(child: Text(l10n.familyTodayTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
              if (!caregiver)
                TextButton(
                  key: const Key('today.family.all'),
                  onPressed: () => context.go('/family'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text(l10n.familyTodayAll), const Icon(Icons.chevron_right_rounded, size: 18)],
                  ),
                ),
            ],
          ),
          const SizedBox(height: HallySpace.xs),
          SizedBox(
            height: 66,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              // Room for the chips' soft shadow, which the list would otherwise clip.
              padding: const EdgeInsets.only(bottom: 6),
              clipBehavior: Clip.none,
              itemCount: people.length,
              separatorBuilder: (_, __) => const SizedBox(width: HallySpace.sm),
              itemBuilder: (_, i) => people[i],
            ),
          ),
        ],
      ),
    );
  }

  static String _line(AppLocalizations l10n, int tasks, int events) =>
      tasks == 0 && events == 0
          ? l10n.familyTodayFree
          : [if (tasks > 0) l10n.familyTodayTasks(tasks), if (events > 0) l10n.familyTodayEvents(events)].join(' · ');
}

class _Person extends StatelessWidget {
  const _Person({super.key, required this.avatar, required this.name, required this.ring, required this.line, required this.onTap});

  final Widget avatar;
  final String name;
  final Color ring;
  final String line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '$name, $line',
      excludeSemantics: true,
      child: HallyPressable(
        onTap: onTap,
        borderRadius: 18,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ring, width: 1.5),
            boxShadow: HallyShadows.soft(theme.brightness),
          ),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: HallySpace.sm),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(line, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
