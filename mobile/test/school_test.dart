import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/features/school/school.dart';
import 'package:hally/features/school/school_screens.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky');

/// Monday 23 November 2026: tomorrow (Tuesday) is a school day.
final _monday = DateTime(2026, 11, 23);

class _FakeSchool implements SchoolRepository {
  final calls = <String>[];
  var settings = const SchoolSettings(bellTimes: ['08:30', '09:20', '10:10'], dailyItems: ['🍎 Beslenme'], reminderTime: '19:30');
  var lessons = <Lesson>[
    const Lesson(id: 'l1', childId: 'c1', weekday: 1, period: 1, subject: 'Matematik'),
    const Lesson(id: 'l2', childId: 'c1', weekday: 1, period: 3, subject: 'Beden Eğitimi', items: ['👟 Eşofman']),
  ];
  var packed = <String>{};
  DateTime? readyAt;

  SchoolState get _state => SchoolState(
        today: _monday,
        settings: settings,
        lessons: lessons,
        bags: [
          Bag(
            childId: 'c1',
            childName: 'Ela',
            day: _monday.add(const Duration(days: 1)),
            subjects: const ['Matematik'],
            items: [
              for (final i in ['👟 Eşofman', '🍎 Beslenme'])
                BagItem(key: i, kind: 'Item', text: i, subjects: i.startsWith('👟') ? const ['Beden Eğitimi'] : const [], packed: packed.contains(i)),
              BagItem(key: 'exam:e1', kind: 'Exam', text: 'Fen', examDate: _monday.add(const Duration(days: 4)), packed: packed.contains('exam:e1')),
            ],
            readyAt: readyAt,
          ),
        ],
      );

  @override
  Future<SchoolState> get(String familyId) async => _state;

  @override
  Future<SchoolState> saveSettings(String familyId, SchoolSettings s) async {
    calls.add('settings ${s.bellTimes.join(',')} ${s.reminderTime} ${s.childPhone}');
    settings = s;
    return _state;
  }

  @override
  Future<SchoolState> addBreak(String familyId, String title, DateTime from, DateTime to) async => _state;

  @override
  Future<SchoolState> deleteBreak(String familyId, String breakId) async => _state;

  @override
  Future<SchoolState> setLesson(String familyId, {required String childId, required int weekday, required int period, String? subject, List<String> items = const []}) async {
    calls.add('lesson $weekday/$period $subject ${items.join(',')}');
    lessons = [
      ...lessons.where((l) => !(l.weekday == weekday && l.period == period)),
      if ((subject ?? '').isNotEmpty) Lesson(id: 'n$weekday$period', childId: childId, weekday: weekday, period: period, subject: subject!, items: items),
    ];
    return _state;
  }

  @override
  Future<SchoolState> copy(String familyId, {required String fromChildId, required String toChildId}) async => _state;

  @override
  Future<SchoolState> pack(String familyId, String childId, String key, bool on) async {
    calls.add('pack $key $on');
    on ? packed.add(key) : packed.remove(key);
    return _state;
  }

  @override
  Future<SchoolState> ready(String familyId, String childId) async {
    calls.add('ready $childId');
    packed.addAll(['👟 Eşofman', '🍎 Beslenme', 'exam:e1']);
    readyAt = DateTime.now();
    return _state;
  }
}

Widget _app(_FakeSchool repo, Widget home) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        schoolRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
        familyProvider.overrideWith((ref, id) async => const FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [_ela])),
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

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('bells, item emojis and subject colours', () {
    expect(nextBell([]), '08:30');
    expect(nextBell(['08:30', '09:20']), '10:10');
    expect(itemEmoji('👟 Eşofman'), '👟');
    expect(itemEmoji('Eşofman'), isNull);
    expect(subjectColorKey('Matematik'), subjectColorKey('Matematik'));
    expect(subjectColorKey('Beden Eğitimi'), 'powder');
  });

  test('the evening push opens the child\'s timetable', () {
    expect(pushRoute({'kind': 'SchoolBag', 'targetId': 'c1'}), '/timetable?child=c1');
  });

  testWidgets('the week shows lessons; a new period takes the items its subject already has', (tester) async {
    _phone(tester);
    final repo = _FakeSchool();
    await tester.pumpWidget(_app(repo, const TimetableScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Matematik'), findsOneWidget);
    expect(find.text('Beden Eğitimi'), findsOneWidget);
    expect(find.text('👟'), findsOneWidget);
    expect(find.text('Yarın çantaya'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable.cell.4.2')));
    await tester.pumpAndSettle();
    expect(find.text('Perşembe · 2. ders'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lesson.subject.Beden Eğitimi')).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('lesson.save')));
    await tester.tap(find.byKey(const Key('lesson.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['lesson 4/2 Beden Eğitimi 👟 Eşofman']);
    expect(find.text('Beden Eğitimi'), findsNWidgets(2));
  });

  testWidgets('ticking the bag and Hazırladık', (tester) async {
    _phone(tester);
    final repo = _FakeSchool();
    await tester.pumpWidget(_app(repo, const Scaffold(body: SingleChildScrollView(child: TodayBagCards(familyId: 'f1')))));
    await tester.pumpAndSettle();

    expect(find.text('Yarın çantaya · Ela'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bagItem.👟 Eşofman')));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bag.c1.done')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['pack 👟 Eşofman true', 'ready c1']);
    expect(find.text('Çanta hazır'), findsOneWidget);
    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets('settings add a bell and turn the child\'s phone list off', (tester) async {
    _phone(tester);
    final repo = _FakeSchool();
    await tester.pumpWidget(_app(repo, const SchoolSettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('3 · 10:10'), findsOneWidget);
    await tester.tap(find.byKey(const Key('school.bell.add')));
    await tester.pumpAndSettle();
    expect(find.text('4 · 11:00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('school.childPhone')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['settings 08:30,09:20,10:10,11:00 19:30 true', 'settings 08:30,09:20,10:10,11:00 19:30 false']);
  });
}
