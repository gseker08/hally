import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../capture/capture_sheet.dart';
import '../family/family_repository.dart';
import '../share/share_listener.dart';

/// Tabs: Today · Calendar · Add (raised centre action, opens the add sheet) · Kids · Family.
/// The assistant opens from the "Ask Hally" bar on Today; settings open from the avatar on every tab.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Caregivers get no Add button (planning and AI capture are for parents) and Messages in place of Family.
    final caregiver = ref.watch(isCaregiverProvider);
    void go(int branch) {
      HapticFeedback.selectionClick();
      shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
    }

    return Scaffold(
      extendBody: true,
      body: ShareListener(child: shell),
      bottomNavigationBar: HallyNavBar(
        currentIndex: shell.currentIndex,
        items: [
          HallyNavItem(icon: Icons.wb_sunny_outlined, activeIcon: Icons.wb_sunny_rounded, label: l10n.tabToday),
          HallyNavItem(icon: Icons.calendar_month_outlined, activeIcon: Icons.calendar_month_rounded, label: l10n.tabCalendar),
          HallyNavItem(icon: Icons.child_care_outlined, activeIcon: Icons.child_care_rounded, label: l10n.tabKids),
          if (caregiver)
            HallyNavItem(icon: Icons.forum_outlined, activeIcon: Icons.forum_rounded, label: l10n.chatsTitle)
          else
            HallyNavItem(icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: l10n.tabFamily),
        ],
        centerLabel: caregiver ? null : l10n.tabCapture,
        onTap: go,
        onCenterTap: () {
          HapticFeedback.mediumImpact();
          showCaptureSheet(context, ref);
        },
      ),
    );
  }
}

class HallyNavItem {
  const HallyNavItem({required this.icon, required this.activeIcon, required this.label});

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// Floating rounded bar with tabs split evenly around a raised cherry add button.
class HallyNavBar extends StatelessWidget {
  const HallyNavBar({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.centerLabel,
    required this.onTap,
    required this.onCenterTap,
  });

  final int currentIndex;
  final List<HallyNavItem> items;
  /// Null hides the raised Add button (caregivers).
  final String? centerLabel;
  final ValueChanged<int> onTap;
  final VoidCallback onCenterTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, HallySpace.sm),
      child: SizedBox(
        height: 84,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            Container(
              height: 68,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: dark ? 0.97 : 0.98),
                borderRadius: BorderRadius.circular(HallyRadius.lg + 4),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: HallyShadows.float(theme.brightness),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < items.length ~/ 2; i++)
                    Expanded(child: _Tab(item: items[i], selected: currentIndex == i, onTap: () => onTap(i))),
                  if (centerLabel != null) const SizedBox(width: 76),
                  for (var i = items.length ~/ 2; i < items.length; i++)
                    Expanded(child: _Tab(item: items[i], selected: currentIndex == i, onTap: () => onTap(i))),
                ],
              ),
            ),
            if (centerLabel != null)
            Positioned(
              top: 0,
              child: Semantics(
                button: true,
                label: centerLabel,
                child: GestureDetector(
                  key: const Key('tab.capture'),
                  onTap: onCenterTap,
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          color: HallyColors.accent(HallyColors.cherry, theme.brightness),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: theme.colorScheme.surface, width: 4),
                          boxShadow: HallyShadows.glow(HallyColors.cherry),
                        ),
                        child: Icon(Icons.add_rounded, color: dark ? HallyColors.canvasDark : Colors.white, size: 32),
                      ),
                      const SizedBox(height: 2),
                      Text(centerLabel!, style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.selected, required this.onTap});

  final HallyNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? HallyColors.accent(HallyColors.cherry, theme.brightness) : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: HallyMotion.medium,
              curve: HallyMotion.curve,
              padding: EdgeInsets.symmetric(horizontal: selected ? 18 : 10, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? HallyColors.softOf(HallyColors.cherry, theme.brightness).withValues(alpha: 0.7) : Colors.transparent,
                borderRadius: BorderRadius.circular(HallyRadius.pill),
              ),
              child: Icon(selected ? item.activeIcon : item.icon, color: color, size: 24),
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
