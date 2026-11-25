import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/billing/billing_repository.dart';
import 'package:hally/features/billing/paywall_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

const _free = PlanLimits(maxAdults: 2, scansPerWeek: 3, scansPerMonth: 0, activeShareLinks: 3, remindersPerItem: 1);
const _plus = PlanLimits(maxAdults: 6, scansPerWeek: 0, scansPerMonth: 100, activeShareLinks: 0, remindersPerItem: 5);

Entitlement _entitlement({bool plus = false, bool trialAvailable = true, int scans = 3}) => Entitlement(
      plan: plus ? 'Plus' : 'Free',
      state: plus ? 'Trialing' : 'Free',
      source: plus ? 'GooglePlay' : null,
      productId: plus ? 'hally_plus_yearly' : null,
      expiresAt: plus ? DateTime(2026, 11, 20) : null,
      willRenew: plus,
      trialAvailable: trialAvailable,
      purchasedByMe: plus,
      purchasedByName: plus ? 'Ayşe' : null,
      purchasedByInFamily: plus,
      canPurchase: !plus,
      limits: plus ? _plus : _free,
      usage: Usage(adults: 2, scansThisWeek: scans, scansThisMonth: scans, activeShareLinks: 1),
    );

/// What a second parent sees while Ayşe's yearly plan covers the family.
Entitlement _coveredBy(String name, {bool payerInFamily = true}) => Entitlement(
      plan: 'Plus',
      state: 'Active',
      source: 'GooglePlay',
      productId: 'hally_plus_yearly',
      expiresAt: DateTime(2027, 12, 12),
      willRenew: true,
      trialAvailable: false,
      purchasedByMe: false,
      purchasedByName: name,
      purchasedByInFamily: payerInFamily,
      canPurchase: !payerInFamily,
      limits: _plus,
      usage: const Usage(adults: 2, scansThisWeek: 0, scansThisMonth: 12, activeShareLinks: 1),
    );

class _FakeBilling implements BillingRepository {
  _FakeBilling({this.trialAvailable = true, this.fixed});

  final bool trialAvailable;

  /// Answer every entitlement request with this (another parent's plan, a refused trial...).
  final Entitlement? fixed;
  var trials = 0;
  final purchases = <String>[];

  @override
  Future<Catalog> catalog() async => const Catalog(
        products: [Product(id: 'hally_plus_monthly', period: 'monthly'), Product(id: 'hally_plus_yearly', period: 'yearly')],
        trialDays: 7,
        free: _free,
        plus: _plus,
        stores: [],
      );

  @override
  Future<Entitlement> entitlement(String familyId) async =>
      fixed ?? _entitlement(plus: trials > 0 || purchases.isNotEmpty, trialAvailable: trialAvailable && trials == 0 && purchases.isEmpty);

  @override
  Future<Entitlement> startTrial(String familyId) async {
    trials++;
    return _entitlement(plus: true, trialAvailable: false);
  }

  @override
  Future<Entitlement> registerPurchase(String familyId, {required String store, required String productId, required String token}) async {
    purchases.add('$store:$productId:$token');
    return _entitlement(plus: true, trialAvailable: false);
  }
}

class _FakeStore implements StoreGateway {
  final bought = <String>[];

  @override
  bool get available => true;

  @override
  Future<Map<String, String>> prices(List<String> productIds) async => {'hally_plus_monthly': '₺139,99', 'hally_plus_yearly': '₺1.399,99'};

  @override
  Future<StorePurchaseResult?> buy(String productId, {bool withTrial = false}) async {
    bought.add(withTrial ? '$productId+trial' : productId);
    return StorePurchaseResult(store: 'GooglePlay', productId: productId, token: 'tok-1');
  }

  @override
  Future<List<StorePurchaseResult>> restore() async => const [];

  @override
  Stream<StorePurchaseResult> get backgroundPurchases => const Stream.empty();
}

/// Home has a button that fails with a 402 like the API does, so the paywall opens through the real helper.
Widget _app(_FakeBilling billing, {StoreGateway? store, String start = '/'}) {
  final router = GoRouter(
    initialLocation: start,
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const Key('home.scan'),
              onPressed: () => openPaywallIfLimited(context, ApiException(402, 'plan.scan_limit', 'limit', trigger: 'scan_limit')),
              child: const Text('scan'),
            ),
          ),
        ),
      ),
      GoRoute(path: '/paywall', builder: (_, s) => PaywallScreen(trigger: s.uri.queryParameters['trigger']!)),
      GoRoute(path: '/plan', builder: (_, __) => const PlanScreen()),
    ],
  );
  return ProviderScope(
    overrides: [
      meProvider.overrideWith((ref) async => _me),
      billingRepositoryProvider.overrideWithValue(billing),
      if (store != null) storeGatewayProvider.overrideWithValue(store),
    ],
    child: MaterialApp.router(
      theme: buildHallyTheme(Brightness.light),
      locale: const Locale('tr'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('free launch: the server says nothing is sold', () {
    Map<String, dynamic> json({bool? selling}) => {
          'plan': 'Free',
          'state': 'Free',
          'trialAvailable': false,
          'limits': {'maxAdults': 6, 'scansPerWeek': 0, 'scansPerMonth': 100, 'activeShareLinks': 0, 'remindersPerItem': 5},
          'usage': {'adults': 1, 'scansThisWeek': 0, 'scansThisMonth': 0, 'activeShareLinks': 0},
          if (selling != null) 'sellingEnabled': selling,
        };
    expect(Entitlement.fromJson(json(selling: false)).sellingEnabled, isFalse);
    expect(Entitlement.fromJson(json()).sellingEnabled, isTrue, reason: 'older servers sell');
  });

  testWidgets('a 402 opens the paywall with the reason, and the free week goes through the store trial offer', (tester) async {
    _phone(tester);
    final billing = _FakeBilling();
    final store = _FakeStore();
    await tester.pumpWidget(_app(billing, store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home.scan')));
    await tester.pumpAndSettle();
    expect(find.text('Bu haftaki 3 ücretsiz taramayı kullandın'), findsOneWidget);
    expect(find.text('Haftada 3', skipOffstage: false), findsOneWidget, reason: 'free column of the comparison');
    expect(find.text('Ayda 100', skipOffstage: false), findsOneWidget);
    expect(find.byKey(const Key('paywall.steps')), findsOneWidget);
    expect(find.text('7 gün ücretsiz, sonra ₺1.399,99 / yıl', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Ücretsiz deneme her aile için bir kez'), findsOneWidget);

    await tester.tap(find.byKey(const Key('paywall.trial')));
    await tester.pumpAndSettle();
    expect(store.bought, ['hally_plus_yearly+trial']);
    expect(billing.purchases, ['GooglePlay:hally_plus_yearly:tok-1']);
    expect(billing.trials, 0, reason: 'the old card-less server trial is not used');
    expect(find.text('Family Plus denemen başladı'), findsOneWidget);
    expect(find.byKey(const Key('home.scan')), findsOneWidget, reason: 'the paywall closes after the trial starts');
  });

  testWidgets('after the trial, buying goes through the store and the server', (tester) async {
    _phone(tester);
    final billing = _FakeBilling(trialAvailable: false);
    await tester.pumpWidget(_app(billing, store: _FakeStore(), start: '/paywall?trigger=adult_limit'));
    await tester.pumpAndSettle();

    expect(find.text('Ücretsiz planda aile 2 yetişkinle sınırlı'), findsOneWidget);
    expect(find.byKey(const Key('paywall.trial')), findsNothing);
    expect(find.text('₺1.399,99 / yıl', skipOffstage: false), findsOneWidget);

    final monthly = find.byKey(const Key('paywall.product.hally_plus_monthly'), skipOffstage: false);
    await tester.ensureVisible(monthly);
    await tester.pumpAndSettle();
    await tester.tap(monthly);
    await tester.pumpAndSettle();
    expect(find.textContaining('Ücretsiz deneme daha önce kullanıldı'), findsOneWidget);
    await tester.tap(find.byKey(const Key('paywall.buy')));
    await tester.pumpAndSettle();
    expect(billing.purchases, ['GooglePlay:hally_plus_monthly:tok-1']);
  });

  testWidgets('a second parent sees the family plan and cannot pay again', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeBilling(fixed: _coveredBy('Ayşe')), store: _FakeStore(), start: '/plan'));
    await tester.pumpAndSettle();
    expect(find.text('Family Plus · Aile planı'), findsOneWidget);
    expect(find.text('Ayşe ödüyor · yıllık'), findsOneWidget);
    expect(find.textContaining('ayrıca ödemene gerek yok'), findsOneWidget);
    expect(find.byKey(const Key('plan.upgrade')), findsNothing);
    expect(find.byKey(const Key('plan.takeOver')), findsNothing);

    await tester.pumpWidget(_app(_FakeBilling(fixed: _coveredBy('Ayşe')), store: _FakeStore(), start: '/paywall?trigger=plan_screen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('paywall.buy')), findsNothing);
    expect(find.byKey(const Key('paywall.trial')), findsNothing);
    expect(find.text('Family Plus zaten tüm aileyi kapsıyor.'), findsOneWidget);
  });

  testWidgets('when the payer left, the remaining parent can take the plan over', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeBilling(fixed: _coveredBy('Ayşe', payerInFamily: false)), store: _FakeStore(), start: '/plan'));
    await tester.pumpAndSettle();
    expect(find.text('Ödeyen kişi aileden ayrıldı'), findsOneWidget);
    expect(find.byKey(const Key('plan.takeOver')), findsOneWidget);
  });

  testWidgets('a second free week is noticed: Plus waits for the first payment', (tester) async {
    _phone(tester);
    final denied = Entitlement(
      plan: 'Free',
      state: 'TrialDenied',
      source: 'GooglePlay',
      productId: 'hally_plus_monthly',
      expiresAt: DateTime(2026, 12, 2),
      willRenew: true,
      trialAvailable: false,
      purchasedByMe: true,
      purchasedByName: 'Mehmet',
      purchasedByInFamily: true,
      canPurchase: false,
      limits: _free,
      usage: const Usage(adults: 2, scansThisWeek: 1, scansThisMonth: 1, activeShareLinks: 0),
    );
    await tester.pumpWidget(_app(_FakeBilling(fixed: denied), start: '/plan'));
    await tester.pumpAndSettle();
    expect(find.text('Ücretsiz deneme bu ailede kullanıldı'), findsOneWidget);
    expect(find.textContaining('Paket'), findsWidgets);
    expect(find.byKey(const Key('plan.upgrade')), findsNothing);
  });

  test('entitlement reads the family plan fields', () {
    final e = Entitlement.fromJson({
      'plan': 'Plus',
      'state': 'Active',
      'source': 'AppStore',
      'productId': 'hally_plus_monthly',
      'trialAvailable': false,
      'purchasedByMe': false,
      'purchasedByName': 'Ayşe',
      'purchasedByInFamily': false,
      'canPurchase': true,
      'limits': {'maxAdults': 6, 'scansPerWeek': 0, 'scansPerMonth': 100, 'activeShareLinks': 0, 'remindersPerItem': 5},
      'usage': {'adults': 1, 'scansThisWeek': 0, 'scansThisMonth': 0, 'activeShareLinks': 0},
    });
    expect(e.purchasedByName, 'Ayşe');
    expect(e.payerLeft, isTrue);
    expect(e.canPurchase, isTrue);
  });

  testWidgets('without a store, buying says the store is not available', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeBilling(trialAvailable: false), start: '/paywall?trigger=plan_screen'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('paywall.buy')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mağaza şu an bu cihazda kullanılamıyor'), findsOneWidget);
  });

  testWidgets('plan screen shows usage against the free limits', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeBilling(), start: '/plan'));
    await tester.pumpAndSettle();

    expect(find.text('Ücretsiz plandasın'), findsOneWidget);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('7 gün ücretsiz başla'), findsOneWidget);
  });
}
