import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/features/shopping/shopping_repository.dart';
import 'package:hally/features/shopping/shopping_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeShopping implements ShoppingRepository {
  final calls = <String>[];
  var open = <ShoppingItem>[];
  var checked = <ShoppingItem>[];
  bool failNextCheck = false;

  ShoppingList get _list => ShoppingList(open: open, checked: checked);

  @override
  Future<ShoppingList> get(String familyId) async => _list;

  @override
  Future<ShoppingAddResult> add(String familyId, String text, {String? quantity}) async {
    calls.add('add $text');
    final added = <ShoppingItem>[];
    final already = <ShoppingItem>[];
    for (final part in text.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty)) {
      final dup = open.where((i) => i.text.toLowerCase() == part.toLowerCase()).firstOrNull;
      if (dup != null) {
        already.add(dup);
      } else {
        final item = ShoppingItem(id: 'i${open.length + checked.length + 1}', text: part, addedByName: 'Ayşe');
        open = [...open, item];
        added.add(item);
      }
    }
    return ShoppingAddResult(added: added, alreadyOnList: already, list: _list);
  }

  @override
  Future<ShoppingList> setChecked(String familyId, String itemId, bool value) async {
    calls.add('check $itemId $value');
    if (failNextCheck) {
      failNextCheck = false;
      throw Exception('offline');
    }
    final all = [...open, ...checked];
    final item = all.firstWhere((i) => i.id == itemId);
    final flipped = ShoppingItem(id: item.id, text: item.text, checkedAt: value ? DateTime.now() : null, checkedByName: value ? 'Ayşe' : null);
    open = [for (final i in open) if (i.id != itemId) i, if (!value) flipped];
    checked = [if (value) flipped, for (final i in checked) if (i.id != itemId) i];
    return _list;
  }

  @override
  Future<ShoppingList> edit(String familyId, String itemId, {String? text, String? quantity}) async {
    calls.add('edit $itemId $quantity');
    open = [for (final i in open) i.id == itemId ? ShoppingItem(id: i.id, text: i.text, quantity: quantity) : i];
    return _list;
  }

  @override
  Future<ShoppingList> delete(String familyId, String itemId) async {
    calls.add('delete $itemId');
    open = open.where((i) => i.id != itemId).toList();
    return _list;
  }

  @override
  Future<ShoppingList> clearChecked(String familyId) async {
    calls.add('clear');
    checked = [];
    return _list;
  }

  @override
  Future<bool> headingOut(String familyId) async {
    calls.add('out');
    return true;
  }
}

class _Live implements ChatRealtime {
  final shopping = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<ChatMessageEvent> get events => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get screenTimeEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get medicationEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get shoppingEvents => shopping.stream;
  @override
  Stream<Map<String, dynamic>> get sleepEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get feedingEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get studyEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get pointsEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get habitsEvents => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> dispose() => shopping.close();
}

Widget _app(_FakeShopping repo, _Live live) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        shoppingRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(live),
      ],
      child: MaterialApp(
        theme: buildHallyTheme(Brightness.light),
        locale: const Locale('tr'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ShoppingScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('the heading-out push opens the list', () {
    expect(pushRoute({'kind': 'ShoppingHeadingOut'}), '/shopping');
  });

  testWidgets('add several, skip duplicates, tick, clear', (tester) async {
    _phone(tester);
    final repo = _FakeShopping();
    await tester.pumpWidget(_app(repo, _Live()));
    await tester.pumpAndSettle();
    expect(find.text('Liste boş'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('shopping.input')), 'Süt, ekmek');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Süt'), findsOneWidget);
    expect(find.text('ekmek'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('shopping.input')), 'süt');
    await tester.tap(find.byKey(const Key('shopping.add')));
    await tester.pumpAndSettle();
    expect(find.text('Zaten listede: Süt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shopping.check.i1')));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('check i1 true'));
    expect(find.text('Alınanlar (1)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shopping.clear')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'clear');
    expect(find.text('Alınanlar (1)'), findsNothing);

    await tester.tap(find.byKey(const Key('shopping.headingOut')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'out');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed tick is put back, and the partner\'s additions arrive live', (tester) async {
    _phone(tester);
    final repo = _FakeShopping()..open = [const ShoppingItem(id: 'a', text: 'Elma')];
    final live = _Live();
    await tester.pumpWidget(_app(repo, live));
    await tester.pumpAndSettle();

    repo.failNextCheck = true;
    await tester.tap(find.byKey(const Key('shopping.check.a')));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('shopping.check.a'))).value, isFalse);
    expect(find.text('Bir şeyler ters gitti. Tekrar dener misin?'), findsOneWidget);

    repo.open = [...repo.open, const ShoppingItem(id: 'b', text: 'Peynir', addedByName: 'Mehmet')];
    live.shopping.add({'familyId': 'f1'});
    await tester.pumpAndSettle();
    expect(find.text('Peynir'), findsOneWidget);
    expect(find.text('Mehmet ekledi'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shopping.qty.b')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shopping.quantity')), '500 g');
    await tester.tap(find.byKey(const Key('shopping.quantitySave')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'edit b 500 g');
    expect(find.text('500 g'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
