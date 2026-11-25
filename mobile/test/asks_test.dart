import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/asks/ask_screens.dart';
import 'package:hally/features/asks/asks.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _friend = AskPreset(id: 'p1', emoji: '🏠', title: 'Arkadaşıma gidebilir miyim?', question: 'Kimin evine?', options: ['Zeynep', 'Can']);
const _game = AskPreset(id: 'p2', emoji: '🎮', title: '15 dk daha oyun', screenMinutes: 15);

ChildAskItem _item(String id, {AskStatus status = AskStatus.pending, String title = 'Arkadaşıma gidebilir miyim?', String? detail, String? note, String? by}) =>
    ChildAskItem(
      id: id,
      childId: 'c1',
      childName: 'Ela',
      emoji: '🏠',
      title: title,
      detail: detail,
      status: status,
      note: note,
      answeredByName: by,
      createdAt: DateTime(2026, 11, 25, 15, 42),
    );

class _KidApi implements ChildApi {
  ChildAsks current = const ChildAsks(presets: [_friend, _game]);
  final sent = <String>[];

  @override
  Future<ChildAsks> asks(String lang) async => current;

  @override
  Future<ChildAsks> ask({String? presetId, String? text, String? detail, required String lang}) async {
    sent.add('${presetId ?? text} ${detail ?? ''}'.trim());
    if (presetId == 'p2' && current.asks.any((a) => a.isPending && a.title == _game.title)) {
      throw ApiException(422, 'ask.already_pending', 'pending');
    }
    final preset = [_friend, _game].where((p) => p.id == presetId).firstOrNull;
    current = ChildAsks(presets: current.presets, asks: [_item('a${sent.length}', title: preset?.title ?? text!, detail: detail), ...current.asks]);
    return current;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Repo implements AsksRepository {
  List<ChildAskItem> items = [_item('a1', detail: 'Zeynep')];
  final answers = <String>[];
  List<AskPreset>? saved;
  bool late = false;

  @override
  Future<List<ChildAskItem>> list(String familyId) async => items;

  @override
  Future<ChildAskItem> answer(String familyId, String askId, {required bool yes, String? note}) async {
    if (late) throw ApiException(409, 'ask.already_answered', 'Mehmet already answered.');
    answers.add('$askId $yes ${note ?? '-'}');
    final done = _item(askId, status: yes ? AskStatus.yes : AskStatus.no, detail: 'Zeynep', note: note, by: 'Ayşe');
    items = [done];
    return done;
  }

  @override
  Future<List<AskPreset>> presets(String familyId, String lang) async => [_friend, _game];

  @override
  Future<List<AskPreset>> savePresets(String familyId, List<AskPreset> presets) async => saved = presets;
}

Widget _app(Widget home, {ChildApi? kid, AsksRepository? repo}) => ProviderScope(
      overrides: [
        if (kid != null) childApiProvider.overrideWithValue(kid),
        if (repo != null) asksRepositoryProvider.overrideWithValue(repo),
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
        home: home,
      ),
    );

void main() {
  testWidgets('the child picks a friend and the request waits for the parents', (tester) async {
    final api = _KidApi();
    await tester.pumpWidget(_app(const KidAsksScreen(), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Birine dokun, annene ve babana gitsin.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ask.preset.p1')));
    await tester.pumpAndSettle();
    expect(find.text('Kimin evine?'), findsOneWidget);
    // Nothing picked yet: Gönder waits for an answer.
    expect(tester.widget<FilledButton>(find.byKey(const Key('ask.send'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('ask.option.Zeynep')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask.send')));
    await tester.pumpAndSettle();

    expect(api.sent, ['p1 Zeynep']);
    expect(find.text('Arkadaşıma gidebilir miyim? · Zeynep'), findsOneWidget);
    expect(find.text('Bekliyor'), findsWidgets);
    // A request that waits can't be sent again.
    expect(tester.widget<InkWell>(find.descendant(of: find.byKey(const Key('ask.preset.p1')), matching: find.byType(InkWell))).onTap, isNull);

    // A preset without a question goes straight away; the child can also write one.
    await tester.tap(find.byKey(const Key('ask.preset.p2')));
    await tester.pumpAndSettle();
    expect(api.sent.last, 'p2');
    await tester.tap(find.byKey(const Key('ask.own')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ask.own.text')), 'Dondurma yiyebilir miyim?');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask.own.send')));
    await tester.pumpAndSettle();
    expect(api.sent.last, 'Dondurma yiyebilir miyim?');
  });

  testWidgets('the answer and the note show up for the child', (tester) async {
    final api = _KidApi()
      ..current = ChildAsks(presets: const [_friend], asks: [_item('a1', status: AskStatus.yes, detail: 'Zeynep', note: "Saat 6'da evde ol 😊", by: 'Ayşe')]);
    await tester.pumpWidget(_app(const KidAsksScreen(), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Evet'), findsOneWidget);
    expect(find.text("Ayşe: Saat 6'da evde ol 😊"), findsOneWidget);
  });

  testWidgets('a parent answers with a note from Today', (tester) async {
    final repo = _Repo();
    await tester.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ParentAsksCard(familyId: 'f1'))), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('Çocukların istekleri'), findsOneWidget);
    expect(find.text('🏠 Arkadaşıma gidebilir miyim? · Zeynep'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ask.note.a1')), "Saat 6'da evde ol");
    await tester.tap(find.byKey(const Key('ask.yes.a1')));
    await tester.pumpAndSettle();

    expect(repo.answers, ["a1 true Saat 6'da evde ol"]);
    expect(find.text('Evet dedin. Ela hemen görecek.'), findsOneWidget);
    // Answered: the card leaves Today.
    expect(find.byKey(const Key('ask.a1')), findsNothing);
  });

  testWidgets('second to answer hears that the other parent already did', (tester) async {
    final repo = _Repo()..late = true;
    await tester.pumpWidget(_app(const AsksScreen(familyId: 'f1'), repo: repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ask.no.a1')));
    await tester.pumpAndSettle();
    expect(find.text('Diğer ebeveyn bu isteği zaten yanıtladı.'), findsOneWidget);
  });

  testWidgets('parents edit the ready-made list', (tester) async {
    final repo = _Repo();
    await tester.pumpWidget(_app(const AskPresetsScreen(familyId: 'f1'), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('+15 dk ekran'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preset.delete.1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('preset.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('preset.title')), 'Bisiklete binebilir miyim?');
    await tester.pump();
    await tester.tap(find.byKey(const Key('preset.ok')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('presets.save')));
    await tester.pumpAndSettle();

    expect(repo.saved!.map((p) => p.title), ['Arkadaşıma gidebilir miyim?', 'Bisiklete binebilir miyim?']);
    expect(repo.saved!.first.options, ['Zeynep', 'Can']);
  });

  test('request pushes open the requests page', () {
    expect(pushRoute({'kind': 'ChildAsk'}), '/asks');
    expect(pushRoute({'kind': 'ChildAskAnswered'}), '/asks');
  });
}
