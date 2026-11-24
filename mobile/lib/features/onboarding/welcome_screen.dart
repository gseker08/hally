import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/analytics/analytics.dart';
import '../../core/config/app_config.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Scrolls only when the screen is too short (small phones, landscape); otherwise fills it.
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, viewport) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: viewport.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero: soft powder with floating "what Hally does" cards.
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: HallyColors.softOf(HallyColors.powder, theme.brightness),
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(HallyRadius.xl)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          const Positioned(
                            top: -30,
                            right: -90,
                            child: Opacity(
                              opacity: 0.12,
                              child: HallyMark(size: 320, colors: HallyMarkColors.onLight),
                            ),
                          ),
                          SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.md, HallySpace.lg, 0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const HallyWordmark(height: 34),
                                  const SizedBox(height: HallySpace.lg),
                                  Text(
                                    l10n.appTagline(AppConfig.appName),
                                    style: theme.textTheme.displaySmall?.copyWith(height: 1.05, fontSize: 34),
                                  ),
                                  const SizedBox(height: HallySpace.sm),
                                  Text(
                                    l10n.brandEmotional,
                                    style: theme.textTheme.titleMedium?.copyWith(color: HallyColors.readableOn(HallyColors.powder, theme.brightness)),
                                  ),
                                  const Spacer(),
                                  _FloatingCards(samples: [l10n.welcomeSample1, l10n.welcomeSample2, l10n.welcomeSample3]),
                                  const SizedBox(height: HallySpace.lg),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.lg, HallySpace.lg, HallySpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l10n.welcomeTitle, style: theme.textTheme.headlineSmall),
                          const SizedBox(height: HallySpace.sm),
                          Text(l10n.welcomeBody, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15)),
                          const SizedBox(height: HallySpace.lg),
                          FilledButton(
                            key: const Key('welcome.start'),
                            onPressed: () {
                              ref.read(analyticsProvider).track(AnalyticsEvent.onboardingStarted);
                              context.go('/trust');
                            },
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(l10n.welcomeStart),
                                const SizedBox(width: HallySpace.sm),
                                const Icon(Icons.arrow_forward_rounded)
                              ],
                            ),
                          ),
                          const SizedBox(height: HallySpace.xs),
                          TextButton(onPressed: () => context.go('/join'), child: Text(l10n.welcomeHaveInvite)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three tilted glass cards that preview the product: a found event, a task and an approval.
class _FloatingCards extends StatelessWidget {
  const _FloatingCards({required this.samples});

  final List<String> samples;

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.event_rounded, HallyModule.calendar, -0.035, 0.0),
      (Icons.checkroom_rounded, HallyModule.kids, 0.03, 36.0),
      (Icons.check_circle_rounded, HallyModule.tasks, -0.02, 8.0),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (icon, color, angle, indent)) in items.indexed)
          HallyEntrance(
            index: i + 1,
            child: Padding(
              padding: EdgeInsets.only(left: indent, bottom: HallySpace.sm + 2),
              child: Transform.rotate(
                angle: angle,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(HallyRadius.md),
                    boxShadow: HallyShadows.soft(Brightness.light),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HallyIconBadge(icon: icon, color: color, size: 34),
                      const SizedBox(width: HallySpace.sm + 2),
                      Text(
                        samples[i],
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      if (i == 0) ...[
                        const SizedBox(width: HallySpace.sm),
                        Icon(Icons.auto_awesome, size: 16, color: HallyColors.accent(HallyColors.cherry, Theme.of(context).brightness)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
