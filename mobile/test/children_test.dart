import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/child_photo.dart';
import 'package:hally/features/family/children.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _Kids implements FamilyRepository {
  final calls = <String>[];

  @override
  Future<ChildProfile> addChild(String familyId, {required String firstName, int? birthYear, String? color}) async {
    calls.add('add $firstName $birthYear $color');
    return ChildProfile(id: 'new', firstName: firstName, birthYear: birthYear, color: color ?? 'sky');
  }

  @override
  Future<ChildProfile> updateChild(String familyId, String childId, {required String firstName, int? birthYear, required String color}) async {
    calls.add('update $childId $firstName $color');
    return ChildProfile(id: childId, firstName: firstName, color: color);
  }

  @override
  Future<void> deleteChild(String familyId, String childId) async => calls.add('delete $childId');

  @override
  Future<ChildProfile> setChildPhoto(String familyId, String childId, Uint8List bytes) async {
    calls.add('photo $childId ${bytes.length}');
    return ChildProfile(id: childId, firstName: 'x', photoUrl: '/p?v=2');
  }

  @override
  Future<ChildProfile> deleteChildPhoto(String familyId, String childId) async {
    calls.add('unphoto $childId');
    return ChildProfile(id: childId, firstName: 'x');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky');

// A valid 1x1 PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

const _elaWithPhoto = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky', photoUrl: '/p?v=1');

Widget _host(_Kids repo, {ChildProfile? child}) => ProviderScope(
      overrides: [
        familyRepositoryProvider.overrideWithValue(repo),
        childPhotoProvider.overrideWith((ref, url) async => _png),
        childPhotoPickerProvider.overrideWithValue((context, source) async => _png),
        familyProvider.overrideWith((ref, id) async => const FamilyDetails(id: 'f1', name: 'A', timeZoneId: 'Europe/Istanbul', members: [])),
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
        // Like the app shell: the page lives in a nested navigator above a bottom navigation bar.
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: NavigationBar(
            key: const Key('navBar'),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'A'),
              NavigationDestination(icon: Icon(Icons.child_care), label: 'B'),
            ],
          ),
          body: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Consumer(
                builder: (context, ref, _) => Center(
                  child: TextButton(
                    onPressed: () => showChildSheet(context, ref, familyId: 'f1', child: child, siblings: const [_ela]),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('adding a child suggests a colour no sibling uses', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Kids();
    await tester.pumpWidget(_host(repo));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('child.name')), 'Can');
    await tester.enterText(find.byKey(const Key('child.birthYear')), '2019');
    await tester.tap(find.byKey(const Key('child.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['add Can 2019 mint']);
  });

  testWidgets('a bad birth year is explained, not sent', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Kids();
    await tester.pumpWidget(_host(repo));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('child.name')), 'Can');
    await tester.enterText(find.byKey(const Key('child.birthYear')), '1950');
    await tester.tap(find.byKey(const Key('child.save')));
    await tester.pumpAndSettle();
    expect(find.text('Geçerli bir doğum yılı yaz'), findsOneWidget);
    expect(repo.calls, isEmpty);
  });

  testWidgets('editing changes the colour and deleting asks first', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Kids();
    await tester.pumpWidget(_host(repo, child: _ela));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('child.color.teal')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('child.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['update c1 Ela teal']);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('child.delete')));
    await tester.pumpAndSettle();
    expect(find.text('Ela silinsin mi?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('child.deleteConfirm')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'delete c1');
  });

  testWidgets('a new child can get a photo, uploaded after the child is saved', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Kids();
    await tester.pumpWidget(_host(repo));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Fotoğraf ekle'), findsOneWidget);
    await tester.tap(find.byKey(const Key('child.photo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('child.photo.remove')), findsNothing);
    await tester.tap(find.byKey(const Key('child.photo.gallery')));
    await tester.pumpAndSettle();
    expect(find.text('Fotoğrafı değiştir'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('child.name')), 'Can');
    await tester.tap(find.byKey(const Key('child.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['add Can null mint', 'photo new ${_png.length}']);
  });

  testWidgets('a photo can be removed, and the badge shows it in the meantime', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Kids();
    await tester.pumpWidget(_host(repo, child: _elaWithPhoto));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ChildPhotoCircle), findsOneWidget);

    await tester.tap(find.byKey(const Key('child.photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('child.photo.remove')));
    await tester.pumpAndSettle();
    expect(find.byType(ChildPhotoCircle), findsNothing);
    expect(find.text('Fotoğraf ekle'), findsOneWidget);

    await tester.tap(find.byKey(const Key('child.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['update c1 Ela sky', 'unphoto c1']);
  });

  testWidgets('ChildBadge shows the photo when there is one, else the initial', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [childPhotoProvider.overrideWith((ref, url) async => _png)],
      child: const MaterialApp(home: Row(children: [ChildBadge(child: _elaWithPhoto), ChildBadge(child: _ela)])),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ChildPhotoCircle), findsOneWidget);
    expect(find.text('E'), findsOneWidget);
  });

  testWidgets('the sheet opens above the bottom navigation bar, so Save is never hidden', (tester) async {
    // A short phone: the sheet has to scroll.
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Kids();
    await tester.pumpWidget(_host(repo, child: _ela));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The last button of the sheet is the one that ended up under the bar.
    for (final key in const [Key('child.save'), Key('child.delete')]) {
      final button = find.byKey(key);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, tester.getCenter(button), tester.view.viewId);
      expect(result.path.any((e) => e.target == tester.renderObject(button)), isTrue, reason: '$key must receive the tap, not the navigation bar');
    }

    final save = find.byKey(const Key('child.save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(repo.calls, ['update c1 Ela sky']);
  });

  test('filterByChild keeps whole-family items', () {
    final items = [('a', <String>[]), ('b', ['c1']), ('c', ['c2']), ('d', ['c1', 'c2'])];
    expect(filterByChild(items, (i) => i.$2, 'c1').map((i) => i.$1), ['a', 'b', 'd']);
    expect(filterByChild(items, (i) => i.$2, null), items);
  });
}
