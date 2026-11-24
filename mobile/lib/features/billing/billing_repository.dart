import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import 'store_gateway_iap.dart';

class PlanLimits {
  const PlanLimits({
    required this.maxAdults,
    required this.scansPerWeek,
    required this.scansPerMonth,
    required this.activeShareLinks,
    required this.remindersPerItem,
  });

  factory PlanLimits.fromJson(Map<String, dynamic> j) => PlanLimits(
        maxAdults: j['maxAdults'] as int,
        scansPerWeek: j['scansPerWeek'] as int,
        scansPerMonth: j['scansPerMonth'] as int,
        activeShareLinks: j['activeShareLinks'] as int,
        remindersPerItem: j['remindersPerItem'] as int,
      );

  /// A limit of 0 or less means unlimited.
  final int maxAdults;
  final int scansPerWeek;
  final int scansPerMonth;
  final int activeShareLinks;
  final int remindersPerItem;
}

class Usage {
  const Usage({required this.adults, required this.scansThisWeek, required this.scansThisMonth, required this.activeShareLinks});

  factory Usage.fromJson(Map<String, dynamic> j) => Usage(
        adults: j['adults'] as int,
        scansThisWeek: j['scansThisWeek'] as int,
        scansThisMonth: j['scansThisMonth'] as int,
        activeShareLinks: j['activeShareLinks'] as int,
      );

  final int adults;
  final int scansThisWeek;
  final int scansThisMonth;
  final int activeShareLinks;
}

class Entitlement {
  const Entitlement({
    required this.plan,
    required this.state,
    this.source,
    this.productId,
    this.expiresAt,
    required this.willRenew,
    required this.trialAvailable,
    required this.purchasedByMe,
    required this.limits,
    required this.usage,
    this.sellingEnabled = true,
  });

  factory Entitlement.fromJson(Map<String, dynamic> j) => Entitlement(
        plan: j['plan'] as String,
        state: j['state'] as String,
        source: j['source'] as String?,
        productId: j['productId'] as String?,
        expiresAt: j['expiresAt'] == null ? null : DateTime.parse(j['expiresAt'] as String).toLocal(),
        willRenew: j['willRenew'] as bool? ?? false,
        trialAvailable: j['trialAvailable'] as bool? ?? false,
        purchasedByMe: j['purchasedByMe'] as bool? ?? false,
        limits: PlanLimits.fromJson(j['limits'] as Map<String, dynamic>),
        usage: Usage.fromJson(j['usage'] as Map<String, dynamic>),
        sellingEnabled: j['sellingEnabled'] as bool? ?? true,
      );

  /// False during the free launch: nothing is sold, so the app shows no plan card or paywall.
  final bool sellingEnabled;
  final String plan; // Free | Plus
  final String state; // Free | Trialing | Active | GracePeriod | Expired
  final String? source; // Trial | AppStore | GooglePlay
  final String? productId;
  final DateTime? expiresAt;
  final bool willRenew;
  final bool trialAvailable;
  final bool purchasedByMe;
  final PlanLimits limits;
  final Usage usage;

  bool get isPlus => plan == 'Plus';
}

class Product {
  const Product({required this.id, required this.period, this.fallbackPrices = const {}});

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        period: j['period'] as String,
        fallbackPrices: (j['fallbackPrices'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v as String)),
      );

  final String id;
  final String period; // monthly | yearly
  final Map<String, String> fallbackPrices;

  bool get yearly => period == 'yearly';
}

class Catalog {
  const Catalog({required this.products, required this.trialDays, required this.free, required this.plus, required this.stores});

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
        products: [for (final p in j['products'] as List<dynamic>) Product.fromJson(p as Map<String, dynamic>)],
        trialDays: j['trialDays'] as int,
        free: PlanLimits.fromJson(j['free'] as Map<String, dynamic>),
        plus: PlanLimits.fromJson(j['plus'] as Map<String, dynamic>),
        stores: [for (final s in j['stores'] as List<dynamic>? ?? const []) s as String],
      );

  final List<Product> products;
  final int trialDays;
  final PlanLimits free;
  final PlanLimits plus;

  /// Stores the server can verify purchases for (AppStore, GooglePlay).
  final List<String> stores;
}

abstract interface class BillingRepository {
  Future<Catalog> catalog();
  Future<Entitlement> entitlement(String familyId);
  Future<Entitlement> startTrial(String familyId);

  /// Sends a store purchase for server-side verification. Also used to restore purchases.
  Future<Entitlement> registerPurchase(String familyId, {required String store, required String productId, required String token});
}

class ApiBillingRepository implements BillingRepository {
  ApiBillingRepository(this._api);

  final ApiClient _api;

  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<Catalog> catalog() => _guard(() async =>
      Catalog.fromJson((await _api.dio.get<Map<String, dynamic>>('/api/v1/billing/catalog')).data!));

  @override
  Future<Entitlement> entitlement(String familyId) => _guard(() async =>
      Entitlement.fromJson((await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/entitlements')).data!));

  @override
  Future<Entitlement> startTrial(String familyId) => _guard(() async =>
      Entitlement.fromJson((await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/subscription/trial')).data!));

  @override
  Future<Entitlement> registerPurchase(String familyId, {required String store, required String productId, required String token}) =>
      _guard(() async => Entitlement.fromJson((await _api.dio.post<Map<String, dynamic>>(
            '/api/v1/families/$familyId/subscription/purchases',
            data: {'store': store, 'productId': productId, 'token': token},
          ))
              .data!));
}

final billingRepositoryProvider = Provider<BillingRepository>((ref) => ApiBillingRepository(ref.watch(apiClientProvider)));

final catalogProvider = FutureProvider<Catalog>((ref) => ref.watch(billingRepositoryProvider).catalog());

/// The signed-in user's primary family entitlement. Invalidate after a trial or purchase.
final entitlementProvider = FutureProvider<Entitlement?>((ref) async {
  final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
  if (familyId == null) return null;
  return ref.watch(billingRepositoryProvider).entitlement(familyId);
});

/// A purchase the store completed on the device. [token] is what the server verifies
/// (StoreKit transaction id / Play purchase token).
class StorePurchaseResult {
  const StorePurchaseResult({required this.store, required this.productId, required this.token});

  final String store; // AppStore | GooglePlay
  final String productId;
  final String token;
}

class StoreUnavailableException implements Exception {}

/// The store accepted the order but the payment is not confirmed yet (for example a slow card or cash payment on
/// Google Play). The purchase arrives later on [StoreGateway.backgroundPurchases].
class StorePendingException implements Exception {}

class StorePurchaseException implements Exception {
  StorePurchaseException(this.message);

  final String? message;

  @override
  String toString() => 'StorePurchaseException: $message';
}

/// Device-side store boundary (StoreKit / Play Billing). Prices shown on the paywall come from here.
abstract interface class StoreGateway {
  bool get available;

  /// Localized price per product id, e.g. {'hally_plus_monthly': '₺79,99'}.
  Future<Map<String, String>> prices(List<String> productIds);

  /// Null when the user cancelled. Throws [StorePendingException] while the payment is still pending.
  Future<StorePurchaseResult?> buy(String productId);

  Future<List<StorePurchaseResult>> restore();

  /// Purchases the store finished outside [buy] and [restore] (a pending payment that cleared, a purchase completed
  /// while the app was closed). [storePurchaseSyncProvider] sends them to the server.
  Stream<StorePurchaseResult> get backgroundPurchases;
}

/// Used where there is no store (tests, desktop, web): buying says the store is not available.
class UnavailableStoreGateway implements StoreGateway {
  @override
  bool get available => false;

  @override
  Future<Map<String, String>> prices(List<String> productIds) async => const {};

  @override
  Future<StorePurchaseResult?> buy(String productId) => throw StoreUnavailableException();

  @override
  Future<List<StorePurchaseResult>> restore() async => const [];

  @override
  Stream<StorePurchaseResult> get backgroundPurchases => const Stream.empty();
}

final storeGatewayProvider = Provider<StoreGateway>((ref) {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return UnavailableStoreGateway();
  final gateway = InAppPurchaseStoreGateway();
  unawaited(gateway.init());
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// Watched by the app root: sends purchases that finished in the background to the server, so a payment that
/// cleared later still unlocks Plus without opening the paywall again.
final storePurchaseSyncProvider = Provider<void>((ref) {
  final sub = ref.watch(storeGatewayProvider).backgroundPurchases.listen((p) async {
    try {
      final familyId = (await ref.read(meProvider.future))?.primaryFamily?.id;
      if (familyId == null) return;
      await ref.read(billingRepositoryProvider).registerPurchase(familyId, store: p.store, productId: p.productId, token: p.token);
      ref.invalidate(entitlementProvider);
    } catch (_) {
      // The store delivers unfinished purchases again on the next start, and "Restore purchases" also works.
    }
  });
  ref.onDispose(sub.cancel);
});
