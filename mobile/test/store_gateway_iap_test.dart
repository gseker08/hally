import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hally/features/billing/billing_repository.dart';
import 'package:hally/features/billing/store_gateway_iap.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// Stands in for the store plugin: tests push purchase updates the way Play Billing / StoreKit would.
class _FakeIap implements InAppPurchase {
  final updates = StreamController<List<PurchaseDetails>>.broadcast();
  final completed = <String>[];
  bool storeAvailable = true;
  void Function(PurchaseParam)? onBuy;
  void Function()? onRestore;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => updates.stream;

  @override
  Future<bool> isAvailable() async => storeAvailable;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async => ProductDetailsResponse(
        productDetails: [
          for (final id in identifiers)
            ProductDetails(id: id, title: id, description: '', price: id.contains('yearly') ? '₺599,99' : '₺79,99', rawPrice: 0, currencyCode: 'TRY'),
        ],
        notFoundIDs: const [],
      );

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    onBuy?.call(purchaseParam);
    return true;
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async => onRestore?.call();

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async => completed.add(purchase.productID);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

PurchaseDetails _purchase(String productId, PurchaseStatus status, {String token = 'play-token', String? id = 'GPA.1'}) =>
    PurchaseDetails(
      purchaseID: id,
      productID: productId,
      verificationData: PurchaseVerificationData(localVerificationData: '', serverVerificationData: token, source: 'google_play'),
      transactionDate: null,
      status: status,
    )..pendingCompletePurchase = status == PurchaseStatus.purchased || status == PurchaseStatus.restored;

void main() {
  test('prices come from the store, localized', () async {
    final gateway = InAppPurchaseStoreGateway(iap: _FakeIap(), store: 'GooglePlay');
    expect(await gateway.prices(['hally_plus_monthly', 'hally_plus_yearly']),
        {'hally_plus_monthly': '₺79,99', 'hally_plus_yearly': '₺599,99'});
    expect(gateway.available, isTrue);
  });

  test('a Play purchase returns the purchase token for the server and is completed', () async {
    final iap = _FakeIap();
    iap.onBuy = (p) => scheduleMicrotask(() => iap.updates.add([_purchase(p.productDetails.id, PurchaseStatus.purchased, token: 'tok-42')]));
    final gateway = InAppPurchaseStoreGateway(iap: iap, store: 'GooglePlay');

    final result = await gateway.buy('hally_plus_monthly');
    expect(result!.store, 'GooglePlay');
    expect(result.token, 'tok-42');
    await pumpEventQueue();
    expect(iap.completed, ['hally_plus_monthly']);
  });

  test('on iPhone the transaction id is the token', () async {
    final iap = _FakeIap();
    iap.onBuy = (p) => scheduleMicrotask(() => iap.updates.add([_purchase(p.productDetails.id, PurchaseStatus.purchased, id: '2000000123')]));
    final result = await InAppPurchaseStoreGateway(iap: iap, store: 'AppStore').buy('hally_plus_yearly');
    expect(result!.token, '2000000123');
  });

  test('cancel returns null; a pending payment says so and arrives later in the background', () async {
    final iap = _FakeIap();
    final gateway = InAppPurchaseStoreGateway(iap: iap, store: 'GooglePlay');

    iap.onBuy = (p) => scheduleMicrotask(() => iap.updates.add([_purchase(p.productDetails.id, PurchaseStatus.canceled)]));
    expect(await gateway.buy('hally_plus_monthly'), isNull);

    iap.onBuy = (p) => scheduleMicrotask(() => iap.updates.add([_purchase(p.productDetails.id, PurchaseStatus.pending)]));
    await expectLater(gateway.buy('hally_plus_monthly'), throwsA(isA<StorePendingException>()));

    final later = gateway.backgroundPurchases.first;
    iap.updates.add([_purchase('hally_plus_monthly', PurchaseStatus.purchased, token: 'cleared')]);
    expect((await later).token, 'cleared');
  });

  test('restore collects restored purchases once per token', () async {
    final iap = _FakeIap();
    iap.onRestore = () => iap.updates.add([
          _purchase('hally_plus_yearly', PurchaseStatus.restored, token: 'a'),
          _purchase('hally_plus_yearly', PurchaseStatus.restored, token: 'a'),
        ]);
    final gateway = InAppPurchaseStoreGateway(iap: iap, store: 'GooglePlay', restoreWindow: const Duration(milliseconds: 10));
    final restored = await gateway.restore();
    expect(restored.map((p) => p.token), ['a']);
  });

  test('no store on the device: buying says unavailable', () async {
    final gateway = InAppPurchaseStoreGateway(iap: _FakeIap()..storeAvailable = false, store: 'GooglePlay');
    await expectLater(gateway.buy('hally_plus_monthly'), throwsA(isA<StoreUnavailableException>()));
  });
}
