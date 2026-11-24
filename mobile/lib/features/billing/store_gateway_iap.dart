import 'dart:async';
import 'dart:io' show Platform;

import 'package:in_app_purchase/in_app_purchase.dart';

import 'billing_repository.dart';

/// [StoreGateway] on top of the official in_app_purchase plugin (Play Billing on Android, StoreKit 2 on iPhone).
///
/// The server is the source of truth: this class only asks the store to sell and hands back what the server needs
/// to verify (Play purchase token / App Store transaction id). Purchases the store reports outside a [buy] or
/// [restore] call (a "pending" card payment that clears later, a purchase finished after the app was killed) are
/// emitted on [backgroundPurchases] so they still reach the server.
class InAppPurchaseStoreGateway implements StoreGateway {
  InAppPurchaseStoreGateway({InAppPurchase? iap, String? store, this.restoreWindow = const Duration(seconds: 2)})
      : _iap = iap ?? InAppPurchase.instance,
        _store = store ?? (Platform.isIOS ? 'AppStore' : 'GooglePlay');

  final InAppPurchase _iap;
  final String _store;

  /// The store does not say when a restore is finished; results that arrive within this window count.
  final Duration restoreWindow;

  final _details = <String, ProductDetails>{};
  final _background = StreamController<StorePurchaseResult>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _sub;
  Future<void>? _ready;
  bool _available = false;

  Completer<StorePurchaseResult?>? _buying;
  String? _buyingProduct;
  List<StorePurchaseResult>? _restored;

  /// Starts listening to the store. Safe to call more than once.
  Future<void> init() => _ready ??= () async {
        _sub = _iap.purchaseStream.listen(_onUpdates, onError: (Object e) => _failBuy(e));
        try {
          _available = await _iap.isAvailable();
        } catch (_) {
          _available = false; // no Play Store (some emulators) or StoreKit unavailable
        }
      }();

  void dispose() {
    _sub?.cancel();
    _background.close();
  }

  @override
  bool get available => _available;

  @override
  Stream<StorePurchaseResult> get backgroundPurchases => _background.stream;

  @override
  Future<Map<String, String>> prices(List<String> productIds) async {
    await init();
    if (!_available || productIds.isEmpty) return const {};
    final response = await _iap.queryProductDetails(productIds.toSet());
    // A Play subscription comes back once per base plan/offer; the first one is the base plan.
    for (final d in response.productDetails) {
      _details.putIfAbsent(d.id, () => d);
    }
    return {for (final d in _details.values) d.id: d.price};
  }

  @override
  Future<StorePurchaseResult?> buy(String productId) async {
    await init();
    if (!_available) throw StoreUnavailableException();
    if (!_details.containsKey(productId)) await prices([productId]);
    final details = _details[productId];
    if (details == null) throw StoreUnavailableException(); // product not set up in the store yet

    final completer = Completer<StorePurchaseResult?>();
    _buying = completer;
    _buyingProduct = productId;
    try {
      final started = await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: details));
      if (!started && !completer.isCompleted) completer.complete(null);
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
    }
    try {
      return await completer.future;
    } finally {
      _buying = null;
      _buyingProduct = null;
    }
  }

  @override
  Future<List<StorePurchaseResult>> restore() async {
    await init();
    if (!_available) return const [];
    final found = <StorePurchaseResult>[];
    _restored = found;
    try {
      await _iap.restorePurchases();
      await Future<void>.delayed(restoreWindow);
    } finally {
      _restored = null;
    }
    final byToken = {for (final p in found) p.token: p};
    return byToken.values.toList();
  }

  Future<void> _onUpdates(List<PurchaseDetails> updates) async {
    for (final p in updates) {
      final mine = _buying != null && !_buying!.isCompleted && p.productID == _buyingProduct;
      switch (p.status) {
        case PurchaseStatus.pending:
          if (mine) _buying!.completeError(StorePendingException());
        case PurchaseStatus.canceled:
          if (mine) _buying!.complete(null);
        case PurchaseStatus.error:
          if (mine) _buying!.completeError(StorePurchaseException(p.error?.message));
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          final result = _toResult(p);
          if (result != null) {
            if (p.status == PurchaseStatus.restored && _restored != null) {
              _restored!.add(result);
            } else if (mine) {
              _buying!.complete(result);
            } else {
              _background.add(result);
            }
          }
      }
      // Tell the store the app has the purchase, or StoreKit keeps re-delivering it. On Android the server also
      // acknowledges after verifying; a second acknowledgement is harmless.
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {
          // Delivered again on the next start; the server verification is what grants Plus.
        }
      }
    }
  }

  StorePurchaseResult? _toResult(PurchaseDetails p) {
    // Android: the Play purchase token. iPhone (StoreKit 2): the transaction id the App Store Server API looks up.
    final token = _store == 'GooglePlay' ? p.verificationData.serverVerificationData : p.purchaseID;
    if (token == null || token.isEmpty) return null;
    return StorePurchaseResult(store: _store, productId: p.productID, token: token);
  }

  void _failBuy(Object e) {
    final b = _buying;
    if (b != null && !b.isCompleted) b.completeError(e);
  }
}
