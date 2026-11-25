import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../messages/messages_repository.dart';
import '../profile/profile_screen.dart';
import '../messages/chats_screen.dart';
import 'family_repository.dart';
import 'invite_partner_screen.dart';

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    // A caregiver's fourth tab is Messages: family settings, invites and money are for parents.
    if (ref.watch(isCaregiverProvider)) return const ChatsScreen();

    final family = ref.watch(familyProvider(familyId));
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabFamily),
        actions: const [ProfileButton(), SizedBox(width: HallySpace.sm)],
      ),
      body: family.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(familyProvider(familyId))),
        data: (f) {
          final unread = ref.watch(chatListProvider(f.id)).valueOrNull?.totalUnread ?? 0;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(familyProvider(familyId).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
              children: [
                HallyEntrance(child: _FamilyHero(family: f)),
                if (f.members.length > 1) ...[
                  const SizedBox(height: HallySpace.md),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      key: const Key('family.chats'),
                      leading: const HallyIconBadge(icon: Icons.forum_rounded, color: HallyModule.messages, size: 40),
                      title: Text(l10n.chatsTitle),
                      subtitle: Text(l10n.familyChatsBody),
                      trailing: Badge(
                        isLabelVisible: unread > 0,
                        label: Text('$unread'),
                        backgroundColor: HallyColors.accent(HallyColors.cherry, Theme.of(context).brightness),
                        child: const Icon(Icons.chevron_right_rounded),
                      ),
                      onTap: () async {
                        await context.push('/chats');
                        ref.invalidate(chatListProvider(f.id));
                      },
                    ),
                  ),
                ],
                HallySectionHeader(title: l10n.familyMembers, count: f.members.length),
                for (final (i, m) in f.members.indexed)
                  HallyEntrance(
                    index: i + 1,
                    child: Card(
                      child: InkWell(
                        key: Key('family.member.${m.userId}'),
                        borderRadius: BorderRadius.circular(HallyRadius.lg),
                        onTap: m.isCaregiver ? () => context.push('/family/${f.id}/caregiver/${m.userId}') : null,
                        child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: HallySpace.md - 2, vertical: HallySpace.sm + 2),
                        child: Row(
                          children: [
                            HallyAvatar(name: m.displayName, size: 40),
                            const SizedBox(width: HallySpace.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.displayName, style: Theme.of(context).textTheme.titleMedium),
                                  if (m.isCaregiver)
                                    Text(_caregiverLine(context, m, f), style: Theme.of(context).textTheme.bodySmall),
                                ],
                              ),
                            ),
                            HallyPill(
                              label: m.isCaregiver ? l10n.roleCaregiver : l10n.roleParent,
                              color: m.isCaregiver ? HallyColors.mist : HallyColors.powder,
                            ),
                            if (m.isCaregiver) const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                      ),
                    ),
                  ),
                const SizedBox(height: HallySpace.sm),
                HallyPressable(
                  onTap: () => context.push('/family/${f.id}/invite'),
                  child: Container(
                    padding: const EdgeInsets.all(HallySpace.md),
                    decoration: BoxDecoration(
                      color: HallyColors.softOf(HallyColors.mint, Theme.of(context).brightness),
                      borderRadius: BorderRadius.circular(HallyRadius.lg),
                    ),
                    child: Row(
                      children: [
                        const HallyIconBadge(icon: Icons.person_add_alt_1_rounded, color: HallyColors.mint, size: 42),
                        const SizedBox(width: HallySpace.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.familyInviteMore, style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(l10n.familyInviteBody, style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: HallyColors.readableOn(HallyColors.mint, Theme.of(context).brightness)),
                      ],
                    ),
                  ),
                ),
                HallySectionHeader(title: l10n.familyTogether),
                HallyTileGrid(
                  children: [
                    _SharedTile(key: const Key('family.shopping'), icon: Icons.shopping_basket_rounded, color: HallyModule.shopping,
                        title: l10n.shoppingTitle, body: l10n.shoppingBody, route: '/shopping'),
                    _SharedTile(key: const Key('family.schoolRun'), icon: Icons.directions_car_rounded, color: HallyModule.duties,
                        title: l10n.dutiesTitle, body: l10n.dutiesBody, route: '/school-run'),
                    _SharedTile(key: const Key('family.expenses'), icon: Icons.account_balance_wallet_rounded, color: HallyModule.expenses,
                        title: l10n.expensesTitle, body: l10n.expensesBody, route: '/expenses'),
                    _SharedTile(key: const Key('family.weeklyCard'), icon: Icons.auto_awesome_rounded, color: HallyColors.lavender,
                        title: l10n.familyWeeklyCard, body: l10n.familyWeeklyCardBody, route: '/weekly-card'),
                    _SharedTile(key: const Key('family.balance'), icon: Icons.balance_rounded, color: HallyColors.lavender,
                        title: l10n.balanceTileTitle, body: l10n.balanceTileBody, route: '/balance'),
                    _SharedTile(key: const Key('family.goal'), icon: Icons.flag_rounded, color: HallyColors.cherry,
                        title: l10n.goalTitle, body: l10n.goalTileBody, route: '/family-goal?familyId=${f.id}'),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "Ela, Deniz · Bitiş: 31 Mart 2027" for a caregiver row.
String _caregiverLine(BuildContext context, FamilyMember m, FamilyDetails f) {
  final l10n = AppLocalizations.of(context);
  final names = m.childIds.isEmpty
      ? l10n.caregiverAllChildren
      : f.children.where((c) => m.childIds.contains(c.id)).map((c) => c.firstName).join(', ');
  if (m.accessUntil == null) return names;
  return '$names · ${l10n.caregiverEnds(formatShortDate(m.accessUntil!, Localizations.localeOf(context).toLanguageTag()))}';
}

class _SharedTile extends StatelessWidget {
  const _SharedTile({super.key, required this.icon, required this.color, required this.title, required this.body, required this.route});

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final fg = HallyColors.readableOn(color, b);
    return HallyPressable(
      onTap: () => context.push(route),
      child: Container(
        padding: const EdgeInsets.all(HallySpace.md - 2),
        decoration: BoxDecoration(
          color: HallyColors.softOf(color, b),
          borderRadius: BorderRadius.circular(HallyRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: b == Brightness.dark ? 0.35 : 0.7), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: fg),
            ),
            const SizedBox(height: HallySpace.sm + 2),
            const Spacer(),
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(body, style: theme.textTheme.bodySmall?.copyWith(color: fg), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

/// Soft powder card with the family name and overlapping member avatars.
class _FamilyHero extends StatelessWidget {
  const _FamilyHero({required this.family});

  final FamilyDetails family;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final shown = family.members.take(5).toList();
    final b = theme.brightness;
    return Container(
      decoration: BoxDecoration(
        color: HallyColors.softOf(HallyColors.powder, b),
        borderRadius: BorderRadius.circular(HallyRadius.lg + 4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned(
            right: -30,
            bottom: -50,
            child: Opacity(
              opacity: 0.16,
              child: HallyMark(size: 170, colors: HallyMarkColors.onLight),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(HallySpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 48,
                  child: Stack(
                    children: [
                      for (final (i, m) in shown.indexed)
                        Positioned(left: i * 32.0, child: HallyAvatar(name: m.displayName, size: 48, ring: true)),
                    ],
                  ),
                ),
                const SizedBox(height: HallySpace.md),
                Text(family.name, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: HallySpace.xs),
                Row(
                  children: [
                    Icon(Icons.favorite_rounded, size: 16, color: HallyColors.accent(HallyColors.cherry, b)),
                    const SizedBox(width: 6),
                    Text(
                      l10n.familyHeroBody(family.members.length),
                      style: TextStyle(color: HallyColors.readableOn(HallyColors.powder, b), fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
