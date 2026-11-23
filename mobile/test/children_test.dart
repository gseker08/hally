import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/design/theme.dart';
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
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky');

Widget _host(_Kids repo, {ChildProfile? child}) => ProviderScope(
      overrides: [
        familyRepositoryProvider.overrideWithValue(repo),
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
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showChildSheet(context, ref, familyId: 'f1', child: child, siblings: const [_ela]),
                child: const Text('open'),
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

  test('filterByChild keeps only items tagged with the child', () {
    final items = [('a', <String>[]), ('b', ['c1']), ('c', ['c2']), ('d', ['c1', 'c2'])];
    expect(filterByChild(items, (i) => i.$2, 'c1').map((i) => i.$1), ['b', 'd']);
    expect(filterByChild(items, (i) => i.$2, 'c2').map((i) => i.$1), ['c', 'd']);
    expect(filterByChild(items, (i) => i.$2, null), items);
  });
}
