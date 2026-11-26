import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/core/locale/app_language.dart';
import 'package:hally/features/family/language_sheet.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _MemoryLanguage implements LanguageStorage {
  AppLanguage stored = AppLanguage.system;

  @override
  Future<AppLanguage> read() async => stored;

  @override
  Future<void> write(AppLanguage language) async => stored = language;
}

class _FakeAuth implements AuthRepository {
  final updates = <String>[];

  @override
  Future<void> updateLocale(String displayName, String locale) async => updates.add('$displayName|$locale');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Shell extends ConsumerWidget {
  const _Shell();

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        theme: buildHallyTheme(Brightness.light),
        locale: ref.watch(languageProvider).locale,
        localeResolutionCallback: (device, _) => resolveDeviceLocale(device),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () => showLanguageSheet(context),
                child: Text(AppLocalizations.of(context).languageTitle),
              ),
            ),
          ),
        ),
      );
}

void main() {
  test('supported device languages are used, the rest get English', () {
    expect(resolveDeviceLocale(const Locale('en', 'GB')), const Locale('en'));
    expect(resolveDeviceLocale(const Locale('tr', 'TR')), const Locale('tr'));
    expect(resolveDeviceLocale(const Locale('de', 'AT')), const Locale('de'));
    expect(resolveDeviceLocale(const Locale('in', 'ID')), const Locale('id'));
    expect(resolveDeviceLocale(const Locale('xx')), const Locale('en'));
    expect(resolveDeviceLocale(null), const Locale('en'));
  });

  test('every supported language has a picker entry, a speech locale and translations', () {
    for (final code in supportedLanguageCodes) {
      expect(AppLanguage.fromCode(code).code, code);
      expect(speechLocaleFor(code), startsWith('${code}_'));
      expect(lookupAppLocalizations(Locale(code)).localeName, code);
    }
  });

  test('stored codes map back to a choice, unknown ones follow the phone', () {
    expect(AppLanguage.fromCode('en'), AppLanguage.en);
    expect(AppLanguage.fromCode('tr'), AppLanguage.tr);
    expect(AppLanguage.fromCode(null), AppLanguage.system);
    expect(AppLanguage.fromCode('xx'), AppLanguage.system);
  });

  testWidgets('picking English switches the app, saves the choice and updates the profile', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.localeTestValue = const Locale('tr', 'TR');
    tester.platformDispatcher.localesTestValue = const [Locale('tr', 'TR')];
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final storage = _MemoryLanguage();
    final auth = _FakeAuth();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        languageStorageProvider.overrideWithValue(storage),
        initialLanguageProvider.overrideWithValue(AppLanguage.tr),
        deviceLocaleProvider.overrideWithValue(const Locale('tr')),
        authRepositoryProvider.overrideWithValue(auth),
        meProvider.overrideWith((ref) async => const Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [])),
      ],
      child: const _Shell(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Dil'), findsOneWidget);

    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language.en')));
    await tester.pumpAndSettle();

    expect(find.text('Language'), findsOneWidget);
    expect(storage.stored, AppLanguage.en);
    expect(auth.updates, ['Ayşe|en']);

    // Back to the phone language: the phone is Turkish, so the app and the profile go back to Turkish.
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language.system')));
    await tester.pumpAndSettle();
    expect(find.text('Dil'), findsOneWidget);
    expect(storage.stored, AppLanguage.system);

    // German, picked by its own name.
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language.de')));
    await tester.pumpAndSettle();
    expect(find.text('Sprache'), findsOneWidget);
    expect(storage.stored, AppLanguage.de);
  });
}
