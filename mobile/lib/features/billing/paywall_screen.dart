import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/analytics/analytics.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/family_repository.dart';
import 'billing_repository.dart';

/// Opens the paywall when [error] is a plan limit (HTTP 402). Returns true when it did,
/// so callers can skip their generic error message.
bool openPaywallIfLimited(BuildContext context, Object error) {
  if (error is! ApiException || !error.needsPlus) return false;
  context.push('/paywall?trigger=${error.trigger ?? 'limit'}');
  return true;
}

/// Family Plus offer. Shown at natural moments (4th weekly scan, 3rd adult, 2nd reminder on an item, 4th helper link)
/// and from the plan screen. Never blocks viewing existing data: closing it always works.
///
/// One plan per family: one parent pays and everyone in the family is covered. The first time a family subscribes
/// it gets the store's 7-day free-trial offer (card in the store, the chosen package starts on day 8); after that,
/// only the plain package is offered.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key, required this.trigger});

  final String trigger;

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  String? _selected;
  bool _busy = false;
  Map<String, String> _prices = const {};

  @override
  void initState() {
    super.initState();
    ref.read(analyticsProvider).track(AnalyticsEvent.paywallViewed, {'trigger': widget.trigger});
    _loadPrices();
  }

  Future<void> _loadPrices() async {
    try {
      final catalog = await ref.read(catalogProvider.future);
      final prices = await ref.read(storeGatewayProvider).prices([for (final p in catalog.products) p.id]);
      if (mounted) setState(() => _prices = prices);
    } catch (_) {
      // Prices are optional decoration; the store sheet shows the real price.
    }
  }

  String? _familyId() => ref.read(meProvider).valueOrNull?.primaryFamily?.id;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buy(Product product, {bool withTrial = false}) => _run(() async {
        final familyId = _familyId();
        if (familyId == null) return;
        final l10n = AppLocalizations.of(context);
        final messenger = ScaffoldMessenger.of(context);
        ref.read(analyticsProvider).track(AnalyticsEvent.purchaseStarted, {'product': product.id});
        try {
          final purchase = await ref.read(storeGatewayProvider).buy(product.id, withTrial: withTrial);
          if (purchase == null) return; // cancelled in the store sheet
          await ref.read(billingRepositoryProvider)
              .registerPurchase(familyId, store: purchase.store, productId: purchase.productId, token: purchase.token);
          ref.invalidate(entitlementProvider);
          messenger.showSnackBar(SnackBar(content: Text(withTrial ? l10n.paywallTrialStarted : l10n.paywallWelcomePlus)));
          if (mounted) context.pop(true);
        } on ApiException catch (e) {
          // Another parent's plan already covers the family (the server refuses a second payment).
          ref.invalidate(entitlementProvider);
          messenger.showSnackBar(SnackBar(content: Text(e.status == 409 ? l10n.paywallFamilyCovered : l10n.errorGeneric)));
        } on StoreUnavailableException {
          messenger.showSnackBar(SnackBar(content: Text(l10n.paywallStoreSoon)));
        } on StorePendingException {
          messenger.showSnackBar(SnackBar(content: Text(l10n.paywallPending)));
        } catch (_) {
          messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
        }
      });

  Future<void> _restore() => _run(() async {
        final familyId = _familyId();
        if (familyId == null) return;
        final l10n = AppLocalizations.of(context);
        final messenger = ScaffoldMessenger.of(context);
        try {
          final purchases = await ref.read(storeGatewayProvider).restore();
          Entitlement? last;
          for (final p in purchases) {
            last = await ref.read(billingRepositoryProvider).registerPurchase(familyId, store: p.store, productId: p.productId, token: p.token);
          }
          ref.invalidate(entitlementProvider);
          messenger.showSnackBar(SnackBar(content: Text(last?.isPlus == true ? l10n.paywallWelcomePlus : l10n.paywallNothingToRestore)));
          if (last?.isPlus == true && mounted) context.pop(true);
        } catch (_) {
          messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
        }
      });

  String _headline(AppLocalizations l10n, Catalog catalog) => switch (widget.trigger) {
        'scan_limit' => l10n.paywallScanLimit(catalog.free.scansPerWeek),
        'adult_limit' => l10n.paywallAdultLimit(catalog.free.maxAdults),
        'share_link_limit' => l10n.paywallShareLimit(catalog.free.activeShareLinks),
        'advanced_reminder' => l10n.paywallReminderLimit,
        _ => l10n.paywallTitle,
      };

  void _close() {
    ref.read(analyticsProvider).track(AnalyticsEvent.paywallDismissed, {'trigger': widget.trigger});
    context.pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final catalog = ref.watch(catalogProvider);
    final entitlement = ref.watch(entitlementProvider).valueOrNull;
    final store = ref.watch(storeGatewayProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(key: const Key('paywall.close'), tooltip: l10n.paywallNotNow, icon: const Icon(Icons.close_rounded), onPressed: _close),
      ),
      body: catalog.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(catalogProvider)),
        data: (c) {
          final products = c.products;
          final selected = _selected ?? (products.where((p) => p.yearly).firstOrNull ?? products.firstOrNull)?.id;
          final trial = entitlement?.trialAvailable ?? false;
          final canBuy = entitlement?.canPurchase ?? true;
          final apple = !kIsWeb && Platform.isIOS;
          final small = Theme.of(context).textTheme.bodySmall;
          return HallyPage(
            bottom: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!canBuy)
                  // A caregiver, or another parent's plan already covers the family: nothing to buy here.
                  Text(
                    entitlement!.isPlus ? l10n.paywallFamilyCovered : l10n.paywallParentsOnly,
                    key: const Key('paywall.notForMe'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall,
                  )
                else if (trial)
                  FilledButton(
                    key: const Key('paywall.trial'),
                    onPressed: _busy || selected == null ? null : () => _buy(products.firstWhere((p) => p.id == selected), withTrial: true),
                    child: Text(l10n.paywallStartTrial(c.trialDays)),
                  )
                else
                  FilledButton(
                    key: const Key('paywall.buy'),
                    onPressed: _busy || selected == null ? null : () => _buy(products.firstWhere((p) => p.id == selected)),
                    child: Text(l10n.paywallSubscribe),
                  ),
                if (canBuy) ...[
                  const SizedBox(height: HallySpace.xs),
                  Text(
                    trial ? (apple ? l10n.paywallTrialNoteApple : l10n.paywallTrialNote) : '${l10n.paywallTrialUsed} ${l10n.paywallRenewNote}',
                    textAlign: TextAlign.center,
                    style: small,
                  ),
                  TextButton(key: const Key('paywall.restore'), onPressed: _busy || !store.available ? null : _restore, child: Text(l10n.paywallRestore)),
                ],
              ],
            ),
            children: [
              HallyEntrance(child: _Hero(title: _headline(l10n, c), subtitle: l10n.paywallSubtitle)),
              if (trial && canBuy) ...[
                const SizedBox(height: HallySpace.md),
                HallyEntrance(index: 1, child: _TrialSteps(days: c.trialDays)),
              ],
              const SizedBox(height: HallySpace.md),
              for (final (i, p) in products.indexed)
                HallyEntrance(
                  index: i + 2,
                  child: _ProductTile(
                    product: p,
                    price: _prices[p.id] ?? _fallbackPrice(p),
                    trialDays: trial ? c.trialDays : null,
                    selected: p.id == selected,
                    onTap: () => setState(() => _selected = p.id),
                  ),
                ),
              const SizedBox(height: HallySpace.sm),
              HallyEntrance(index: products.length + 2, child: _Comparison(free: c.free, plus: c.plus)),
            ],
          );
        },
      ),
    );
  }

  String? _fallbackPrice(Product p) {
    if (p.fallbackPrices.isEmpty) return null;
    final currency = NumberFormat.simpleCurrency(locale: Localizations.localeOf(context).toString()).currencyName;
    return p.fallbackPrices[currency] ?? p.fallbackPrices.values.first;
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(HallySpace.lg),
      decoration: BoxDecoration(
        gradient: HallyGradients.hero,
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        boxShadow: HallyShadows.glow(HallyColors.cherry),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 36),
          const SizedBox(height: HallySpace.sm),
          Text(title, key: const Key('paywall.headline'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white)),
          const SizedBox(height: HallySpace.xs),
          Text(subtitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _Comparison extends StatelessWidget {
  const _Comparison({required this.free, required this.plus});

  final PlanLimits free;
  final PlanLimits plus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String n(int v) => v <= 0 ? l10n.planUnlimited : '$v';
    String scans(PlanLimits l) => l.scansPerWeek > 0 ? l10n.planPerWeek(l.scansPerWeek) : l.scansPerMonth > 0 ? l10n.planPerMonth(l.scansPerMonth) : l10n.planUnlimited;
    final rows = [
      (l10n.planRowAdults, n(free.maxAdults), n(plus.maxAdults)),
      (l10n.planRowScans, scans(free), scans(plus)),
      (l10n.planRowLinks, n(free.activeShareLinks), n(plus.activeShareLinks)),
      (l10n.planRowReminders, n(free.remindersPerItem), n(plus.remindersPerItem)),
    ];
    final style = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Table(
          columnWidths: const {0: FlexColumnWidth(2.2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.2)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(children: [
              const SizedBox(),
              Text(l10n.planFree, style: style.labelLarge, textAlign: TextAlign.center),
              Text(l10n.planPlus, style: style.labelLarge?.copyWith(color: HallyColors.cherry), textAlign: TextAlign.center),
            ]),
            for (final (label, f, p) in rows)
              TableRow(children: [
                Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(label, style: style.bodyMedium)),
                Text(f, style: style.bodyMedium, textAlign: TextAlign.center),
                Text(p, style: style.bodyMedium?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
              ]),
          ],
        ),
      ),
    );
  }
}

/// Today: start free · 7 days: everything on · day 8: the chosen package starts.
class _TrialSteps extends StatelessWidget {
  const _TrialSteps({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget step(String title, String note) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: HallySpace.sm, horizontal: HallySpace.xs),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(HallyRadius.md)),
            child: Column(
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontFamily: HallyFonts.display, fontWeight: FontWeight.w700)),
                Text(note, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
              ],
            ),
          ),
        );
    return Row(
      key: const Key('paywall.steps'),
      children: [
        step(l10n.paywallStepToday, l10n.paywallStepTodayNote),
        const SizedBox(width: HallySpace.xs),
        step(l10n.paywallStepDays(days), l10n.paywallStepDaysNote),
        const SizedBox(width: HallySpace.xs),
        step(l10n.paywallStepStart(days + 1), l10n.paywallStepStartNote),
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.price, this.trialDays, required this.selected, required this.onTap});

  final Product product;
  final String? price;

  /// Set while the family can still use its free week: "7 gün ücretsiz, sonra ₺599,99 / yıl".
  final int? trialDays;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HallySpace.sm),
      child: HallyPressable(
        onTap: onTap,
        child: AnimatedContainer(
          key: Key('paywall.product.${product.id}'),
          duration: HallyMotion.fast,
          padding: const EdgeInsets.all(HallySpace.md),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(HallyRadius.md),
            border: Border.all(color: selected ? HallyColors.cherry : theme.dividerColor, width: selected ? 2 : 1),
          ),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: HallyColors.cherry),
              const SizedBox(width: HallySpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.yearly ? l10n.paywallYearly : l10n.paywallMonthly, style: theme.textTheme.titleMedium),
                    Text(_priceLine(l10n), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (product.yearly) HallyPill(label: l10n.paywallYearlyBadge, color: HallyColors.mint),
            ],
          ),
        ),
      ),
    );
  }

  String _priceLine(AppLocalizations l10n) {
    final p = price;
    if (p == null) return l10n.paywallPriceInStore;
    final perPeriod = product.yearly ? l10n.paywallPerYear(p) : l10n.paywallPerMonth(p);
    return trialDays == null ? perPeriod : l10n.paywallTrialThen(trialDays!, perPeriod);
  }
}

/// Current plan, usage this week and a way to upgrade. Reached from the Family tab.
class PlanScreen extends ConsumerWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entitlement = ref.watch(entitlementProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.planTitle)),
      body: entitlement.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(entitlementProvider)),
        data: (e) {
          if (e == null) return const HallyLoading();
          final dateFormat = DateFormat.yMMMd(Localizations.localeOf(context).toString());
          final ends = e.expiresAt == null ? '' : dateFormat.format(e.expiresAt!);
          final status = switch (e.state) {
            'Trialing' when e.fromStore && e.willRenew => l10n.planStatusTrialRenews(ends),
            'Trialing' => l10n.planStatusTrial(ends),
            'Active' when e.willRenew => l10n.planStatusRenews(ends),
            'Active' => l10n.planStatusEnds(ends),
            'GracePeriod' => l10n.planStatusGrace,
            'TrialDenied' => l10n.planTrialDeniedStatus(ends),
            _ => l10n.planStatusFree,
          };
          final l = e.limits;
          final u = e.usage;
          String of(int used, int limit) => limit <= 0 ? '$used' : '$used / $limit';
          final name = e.purchasedByName;
          final covered = e.isPlus && !e.payerLeft;
          final holder = covered ? _holder(l10n, e) : null;
          final theme = Theme.of(context);
          return RefreshIndicator(
            onRefresh: () => ref.refresh(entitlementProvider.future),
            child: ListView(
              padding: const EdgeInsets.all(HallySpace.md),
              children: [
                if (e.payerLeft && e.isPlus)
                  _Notice(
                    key: const Key('plan.payerLeft'),
                    icon: Icons.warning_amber_rounded,
                    color: HallyColors.apricot,
                    title: l10n.planPayerLeftTitle,
                    body: l10n.planPayerLeftBody(name ?? '', ends),
                  ),
                if (e.trialDenied)
                  _Notice(
                    key: const Key('plan.trialDenied'),
                    icon: Icons.manage_search_rounded,
                    color: HallyColors.butter,
                    title: l10n.planTrialDeniedTitle,
                    body: l10n.planTrialDeniedBody(ends),
                  ),
                Card(
                  color: covered ? HallyColors.softOf(HallyColors.cherry, theme.brightness) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(HallySpace.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            HallyIconBadge(
                              icon: e.isPlus ? Icons.workspace_premium_rounded : Icons.favorite_rounded,
                              color: e.isPlus ? HallyColors.cherry : HallyColors.mint,
                            ),
                            const SizedBox(width: HallySpace.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(covered ? l10n.planFamilyPlus : e.isPlus ? l10n.planPlus : l10n.planFree,
                                      key: const Key('plan.title'), style: theme.textTheme.titleMedium),
                                  if (holder != null)
                                    Text(holder, key: const Key('plan.holder'),
                                        style: theme.textTheme.bodyMedium?.copyWith(color: HallyColors.cherryStrong, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: HallySpace.sm),
                        Text(status, key: const Key('plan.status'), style: theme.textTheme.bodyMedium),
                        if (covered) ...[
                          const SizedBox(height: HallySpace.sm),
                          _CoveredMembers(),
                        ],
                      ],
                    ),
                  ),
                ),
                if (covered)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: HallySpace.xs),
                    child: Text(
                      !e.purchasedByMe && e.fromStore && name != null ? l10n.planCoveredNote(name) : l10n.planCoveredEveryone,
                      key: const Key('plan.coveredNote'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (e.trialDenied)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: HallySpace.xs),
                    child: Text(l10n.planTrialDeniedHint, style: theme.textTheme.bodySmall),
                  ),
                HallySectionHeader(title: l10n.planUsage),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(l10n.planRowScans),
                        trailing: Text(l.scansPerWeek > 0 ? of(u.scansThisWeek, l.scansPerWeek) : of(u.scansThisMonth, l.scansPerMonth),
                            key: const Key('plan.scans')),
                        subtitle: Text(l.scansPerWeek > 0 ? l10n.planThisWeek : l10n.planThisMonth),
                      ),
                      ListTile(title: Text(l10n.planRowAdults), trailing: Text(of(u.adults, l.maxAdults))),
                      ListTile(title: Text(l10n.planRowLinks), trailing: Text(of(u.activeShareLinks, l.activeShareLinks))),
                    ],
                  ),
                ),
                const SizedBox(height: HallySpace.md),
                if (e.payerLeft && e.canPurchase) ...[
                  Text(l10n.planPayerLeftHint, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                  const SizedBox(height: HallySpace.sm),
                  FilledButton(
                    key: const Key('plan.takeOver'),
                    onPressed: () => context.push('/paywall?trigger=plan_screen'),
                    child: Text(l10n.planTakeOver),
                  ),
                ] else if (!e.isPlus && !e.trialDenied && e.canPurchase)
                  FilledButton(
                    key: const Key('plan.upgrade'),
                    onPressed: () => context.push('/paywall?trigger=plan_screen'),
                    child: Text(e.trialAvailable ? l10n.paywallStartTrial(ref.watch(catalogProvider).valueOrNull?.trialDays ?? 7) : l10n.paywallSubscribe),
                  )
                else if (!e.isPlus && !e.canPurchase)
                  Text(l10n.paywallParentsOnly, style: theme.textTheme.bodySmall, textAlign: TextAlign.center)
                else if (e.fromStore && e.purchasedByMe)
                  Text(e.source == 'AppStore' ? l10n.planManageApple : l10n.planManageGoogle,
                      style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "Ayşe ödüyor · yıllık", "Sen ödüyorsun · aylık", or who started the trial.
String? _holder(AppLocalizations l10n, Entitlement e) {
  final name = e.purchasedByName;
  if (e.state == 'Trialing' && !e.fromStore) return name == null ? null : l10n.planTrialBy(name);
  final who = e.purchasedByMe ? l10n.planPaidByMe : name == null ? null : l10n.planPaidBy(name);
  if (who == null) return null;
  return e.fromStore ? '$who · ${e.yearly ? l10n.planYearlySuffix : l10n.planMonthlySuffix}' : who;
}

/// Everyone the family plan covers: parents and caregivers by name.
class _CoveredMembers extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    final members = familyId == null ? null : ref.watch(familyProvider(familyId)).valueOrNull?.members;
    if (members == null || members.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Wrap(
      key: const Key('plan.members'),
      spacing: HallySpace.xs,
      runSpacing: HallySpace.xs,
      children: [
        for (final m in members)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(12)),
            child: Text(
              m.isCaregiver ? '${m.displayName} (${l10n.planCaregiverTag}) ✓' : '${m.displayName} ✓',
              style: theme.textTheme.labelMedium?.copyWith(color: m.isCaregiver ? HallyColors.sky : HallyColors.cherryStrong),
            ),
          ),
      ],
    );
  }
}

/// A soft coloured notice at the top of the plan screen.
class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.color, required this.title, required this.body});

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final fg = HallyColors.readableOn(color, b);
    return Container(
      margin: const EdgeInsets.only(bottom: HallySpace.sm),
      padding: const EdgeInsets.all(HallySpace.md),
      decoration: BoxDecoration(color: HallyColors.softOf(color, b), borderRadius: BorderRadius.circular(HallyRadius.lg)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg),
          const SizedBox(width: HallySpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(color: fg, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
