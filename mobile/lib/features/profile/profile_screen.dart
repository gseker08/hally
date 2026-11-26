import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';
import '../billing/billing_repository.dart';
import '../family/family_repository.dart';
import '../family/language_sheet.dart';
import '../notifications/push.dart';

/// The signed-in parent's avatar; opens Profile and settings. Sits top-right on every tab.
class ProfileButton extends ConsumerWidget {
  const ProfileButton({super.key, this.size = 38, this.ring = false});

  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final name = ref.watch(meProvider).valueOrNull?.displayName ?? '';
    return Semantics(
      button: true,
      label: l10n.profileTitle,
      child: HallyPressable(
        key: const Key('profile.open'),
        onTap: () => context.push('/profile'),
        child: HallyAvatar(name: name, size: size, ring: ring),
      ),
    );
  }
}

/// Personal settings: plan, language, helper links, privacy and sign-out. These used to sit at the bottom of the
/// Family tab; they are about the signed-in parent, not the family's shared work.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final me = ref.watch(meProvider).valueOrNull;
    if (me == null) return const Scaffold(body: HallyLoading());
    final family = me.primaryFamily == null ? null : ref.watch(familyProvider(me.primaryFamily!.id)).valueOrNull;
    final role = family?.members.where((m) => m.userId == me.id).firstOrNull?.role;

    Widget tile(Key key, IconData icon, Color color, String title, String? subtitle, VoidCallback onTap) => ListTile(
          key: key,
          leading: HallyIconBadge(icon: icon, color: color, size: 40),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
        children: [
          Row(
            children: [
              HallyAvatar(name: me.displayName, size: 60),
              const SizedBox(width: HallySpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(me.displayName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    if (family != null)
                      Text(
                        role == null ? family.name : '${family.name} · ${role == 'Caregiver' ? l10n.roleCaregiver : l10n.roleParent}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HallySpace.lg),
          // Free launch: nothing is sold yet, so there is no plan to show.
          if (ref.watch(entitlementProvider).valueOrNull?.sellingEnabled ?? true) ...[
            _PlanCard(entitlement: ref.watch(entitlementProvider).valueOrNull),
            const SizedBox(height: HallySpace.md),
          ],
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                if (role != 'Caregiver')
                  tile(const Key('profile.todayFocus'), Icons.dashboard_customize_rounded, HallyColors.cherry, l10n.focusSettingsTitle,
                      l10n.focusSettingsSubtitle, () => context.push('/today-focus')),
                tile(const Key('profile.tips'), Icons.lightbulb_rounded, HallyColors.butter, l10n.tipSettingsTitle, l10n.tipSettingsSubtitle,
                    () => context.push('/tips-settings')),
                tile(const Key('family.language'), Icons.translate_rounded, HallyColors.apricot, l10n.languageTitle,
                    languageLabel(l10n, ref.watch(languageProvider)), () => showLanguageSheet(context)),
                tile(const Key('family.helperLinks'), Icons.volunteer_activism_rounded, HallyColors.mint, l10n.familyHelperLinks,
                    l10n.familyHelperLinksBody, () => context.push('/share-links')),
                tile(const Key('family.privacy'), Icons.shield_rounded, HallyColors.sky, l10n.privacyTitle, l10n.familyPrivacyBody,
                    () => context.push('/privacy')),
              ],
            ),
          ),
          const SizedBox(height: HallySpace.lg),
          Center(
            child: TextButton.icon(
              key: const Key('profile.signOut'),
              icon: const Icon(Icons.logout_rounded),
              label: Text(l10n.signOut),
              onPressed: () async {
                await ref.read(pushControllerProvider)?.unregister();
                await ref.read(authRepositoryProvider).signOut();
                ref.invalidate(meProvider);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Current plan with this week's scans; opens the plan screen.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.entitlement});

  final Entitlement? entitlement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final e = entitlement;
    final plus = e?.isPlus ?? false;
    final subtitle = e == null
        ? null
        : plus
            ? (e.state == 'Trialing'
                ? l10n.planTrialShort
                : !e.purchasedByMe && e.purchasedByInFamily && e.purchasedByName != null
                    ? l10n.planFamilyShort(e.purchasedByName!)
                    : l10n.planPlusShort)
            : l10n.planFreeUsage(e.usage.scansThisWeek, e.limits.scansPerWeek);
    final b = Theme.of(context).brightness;
    final fg = HallyColors.readableOn(HallyColors.butter, b);
    final ink = Theme.of(context).colorScheme.onSurface;
    return HallyPressable(
      key: const Key('family.plan'),
      onTap: () => context.push('/plan'),
      child: Container(
        padding: const EdgeInsets.all(HallySpace.md),
        decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.butter, b), borderRadius: BorderRadius.circular(HallyRadius.lg)),
        child: Row(
          children: [
            Icon(Icons.workspace_premium_rounded, color: fg, size: 28),
            const SizedBox(width: HallySpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plus ? l10n.planPlus : l10n.planFree,
                      style: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 16, fontFamily: HallyFonts.display)),
                  if (subtitle != null) Text(subtitle, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: fg),
          ],
        ),
      ),
    );
  }
}
