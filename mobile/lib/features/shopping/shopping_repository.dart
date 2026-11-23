import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

class ShoppingItem {
  const ShoppingItem({required this.id, required this.text, this.quantity, this.addedByName, this.checkedAt, this.checkedByName});

  factory ShoppingItem.fromJson(Map<String, dynamic> j) => ShoppingItem(
        id: j['id'] as String,
        text: j['text'] as String,
        quantity: j['quantity'] as String?,
        addedByName: j['addedByName'] as String?,
        checkedAt: j['checkedAt'] is String ? DateTime.parse(j['checkedAt'] as String).toLocal() : null,
        checkedByName: j['checkedByName'] as String?,
      );

  final String id;
  final String text;
  final String? quantity;
  final String? addedByName;
  final DateTime? checkedAt;
  final String? checkedByName;

  bool get isChecked => checkedAt != null;
}

class ShoppingList {
  const ShoppingList({this.open = const [], this.checked = const []});

  factory ShoppingList.fromJson(Map<String, dynamic> j) => ShoppingList(
        open: [for (final i in j['open'] as List) ShoppingItem.fromJson(i as Map<String, dynamic>)],
        checked: [for (final i in j['checked'] as List) ShoppingItem.fromJson(i as Map<String, dynamic>)],
      );

  final List<ShoppingItem> open;
  final List<ShoppingItem> checked;
}

/// Result of adding: what was new, and what was already on the list (not added twice).
class ShoppingAddResult {
  const ShoppingAddResult({required this.added, required this.alreadyOnList, required this.list});

  final List<ShoppingItem> added;
  final List<ShoppingItem> alreadyOnList;
  final ShoppingList list;
}

abstract interface class ShoppingRepository {
  Future<ShoppingList> get(String familyId);

  /// [text] may hold several items: "süt, ekmek" or one per line.
  Future<ShoppingAddResult> add(String familyId, String text, {String? quantity});
  Future<ShoppingList> setChecked(String familyId, String itemId, bool checked);
  Future<ShoppingList> edit(String familyId, String itemId, {String? text, String? quantity});
  Future<ShoppingList> delete(String familyId, String itemId);
  Future<ShoppingList> clearChecked(String familyId);

  /// Returns false when a "heading out" was already sent in the last 15 minutes.
  Future<bool> headingOut(String familyId);
}

class ApiShoppingRepository implements ShoppingRepository {
  ApiShoppingRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _url(String familyId) => '/api/v1/families/$familyId/shopping';

  Future<ShoppingList> _list(Future<Response<Map<String, dynamic>>> request) async => ShoppingList.fromJson((await request).data!);

  @override
  Future<ShoppingList> get(String familyId) => _call(() => _list(_api.dio.get<Map<String, dynamic>>(_url(familyId))));

  @override
  Future<ShoppingAddResult> add(String familyId, String text, {String? quantity}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_url(familyId)}/items', data: {'text': text, 'quantity': quantity});
        final d = res.data!;
        return ShoppingAddResult(
          added: [for (final i in d['added'] as List) ShoppingItem.fromJson(i as Map<String, dynamic>)],
          alreadyOnList: [for (final i in d['alreadyOnList'] as List) ShoppingItem.fromJson(i as Map<String, dynamic>)],
          list: ShoppingList.fromJson(d['list'] as Map<String, dynamic>),
        );
      });

  @override
  Future<ShoppingList> setChecked(String familyId, String itemId, bool checked) =>
      _call(() => _list(_api.dio.patch<Map<String, dynamic>>('${_url(familyId)}/items/$itemId', data: {'checked': checked})));

  @override
  Future<ShoppingList> edit(String familyId, String itemId, {String? text, String? quantity}) =>
      _call(() => _list(_api.dio.patch<Map<String, dynamic>>('${_url(familyId)}/items/$itemId', data: {'text': text, 'quantity': quantity})));

  @override
  Future<ShoppingList> delete(String familyId, String itemId) =>
      _call(() => _list(_api.dio.delete<Map<String, dynamic>>('${_url(familyId)}/items/$itemId')));

  @override
  Future<ShoppingList> clearChecked(String familyId) => _call(() => _list(_api.dio.post<Map<String, dynamic>>('${_url(familyId)}/clear-checked')));

  @override
  Future<bool> headingOut(String familyId) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_url(familyId)}/heading-out');
        return res.data?['sent'] as bool? ?? true;
      });
}

final shoppingRepositoryProvider = Provider<ShoppingRepository>((ref) => ApiShoppingRepository(ref.watch(apiClientProvider)));

/// The family's list. Each change answers with the whole list, which replaces the state at once; changes from
/// the other parent arrive live, and the list reloads every 30 seconds while the live connection is down.
class ShoppingController extends AutoDisposeFamilyAsyncNotifier<ShoppingList, String> {
  ShoppingRepository get _repo => ref.read(shoppingRepositoryProvider);

  @override
  Future<ShoppingList> build(String familyId) async {
    final realtime = ref.watch(chatRealtimeProvider);
    final live = realtime.shoppingEvents.where((e) => e['familyId'] == familyId).listen((_) => refresh());
    final poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!realtime.isConnected) refresh();
    });
    ref.onDispose(() {
      live.cancel();
      poll.cancel();
    });
    return _repo.get(familyId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.get(arg));
    } catch (_) {
      // Keep the list we show.
    }
  }

  Future<ShoppingAddResult> add(String text, {String? quantity}) async {
    final result = await _repo.add(arg, text, quantity: quantity);
    state = AsyncData(result.list);
    return result;
  }

  /// Ticks the box at once (the shop has bad signal) and puts it back if the server says no.
  Future<void> toggle(ShoppingItem item) async {
    final before = state.valueOrNull;
    if (before != null) {
      final now = DateTime.now();
      final flipped = ShoppingItem(id: item.id, text: item.text, quantity: item.quantity, addedByName: item.addedByName, checkedAt: item.isChecked ? null : now);
      state = AsyncData(item.isChecked
          ? ShoppingList(open: [...before.open, flipped], checked: before.checked.where((i) => i.id != item.id).toList())
          : ShoppingList(open: before.open.where((i) => i.id != item.id).toList(), checked: [flipped, ...before.checked]));
    }
    try {
      state = AsyncData(await _repo.setChecked(arg, item.id, !item.isChecked));
    } catch (_) {
      if (before != null) state = AsyncData(before);
      rethrow;
    }
  }

  Future<void> delete(String itemId) async => state = AsyncData(await _repo.delete(arg, itemId));
  Future<void> clearChecked() async => state = AsyncData(await _repo.clearChecked(arg));
  Future<void> edit(String itemId, {String? text, String? quantity}) async => state = AsyncData(await _repo.edit(arg, itemId, text: text, quantity: quantity));
}

final shoppingProvider = AsyncNotifierProvider.autoDispose.family<ShoppingController, ShoppingList, String>(ShoppingController.new);
