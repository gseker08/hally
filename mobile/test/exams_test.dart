import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/exams/exam_screens.dart';
import 'package:hally/features/exams/exams.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky');

DateTime get _today => DateUtils.dateOnly(DateTime.now());

class _FakeExams implements ExamsRepository {
  final calls = <String>[];
  late List<Exam> exams = [
    Exam(id: 'e1', childId: 'c1', childName: 'Ela', subject: 'Matematik', topics: 'Kesirler', date: _today.add(const Duration(days: 2)), daysLeft: 2, studyDaysBefore: 3, studyDay: true),
    Exam(id: 'e2', childId: 'c1', childName: 'Ela', subject: 'İngilizce', date: _today.add(const Duration(days: 7)), daysLeft: 7),
    Exam(id: 'e3', childId: 'c1', childName: 'Ela', subject: 'Türkçe', date: _today.subtract(const Duration(days: 5)), daysLeft: -5, studySeconds: 3300),
  ];

  @override
  Future<List<Exam>> list(String familyId, {String? childId}) async => exams;

  @override
  Future<Exam> get(String familyId, String examId) async => exams.firstWhere((e) => e.id == examId);

  @override
  Future<Exam> create(String familyId, ExamDraft draft) async {
    calls.add('create ${draft.childId} ${draft.subject} ${draft.topics} ${draft.studyDaysBefore}');
    return Exam(id: 'new', childId: draft.childId, childName: 'Ela', subject: draft.subject, date: draft.date);
  }

  @override
  Future<Exam> update(String familyId, String examId, ExamDraft draft) async {
    calls.add('update $examId ${draft.subject}');
    return exams.firstWhere((e) => e.id == examId);
  }

  @override
  Future<void> delete(String familyId, String examId) async => calls.add('delete $examId');

  @override
  Future<Exam> result(String familyId, String examId, {required String outcome, int? score, int cherries = 0}) async {
    calls.add('result $examId $outcome $score $cherries');
    return exams.firstWhere((e) => e.id == examId);
  }

  @override
  Future<void> startStudy(String familyId, String childId, String examId) async => calls.add('study $childId $examId');
}

Widget _app(_FakeExams repo, Widget home) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        examsRepositoryProvider.overrideWithValue(repo),
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
  test('study evenings run from the chosen days before up to the day before', () {
    final exam = Exam(id: 'e', childId: 'c', childName: 'Ela', subject: 'Fen', date: DateTime(2026, 11, 27), studyDaysBefore: 3);
    expect(exam.isStudyDay(DateTime(2026, 11, 23)), isFalse);
    expect(exam.isStudyDay(DateTime(2026, 11, 24, 18)), isTrue);
    expect(exam.isStudyDay(DateTime(2026, 11, 26)), isTrue);
    expect(exam.isStudyDay(DateTime(2026, 11, 27)), isFalse, reason: 'the exam day itself asks how it went');
    expect(Exam(id: 'e', childId: 'c', childName: 'Ela', subject: 'Fen', date: DateTime(2026, 11, 27)).isStudyDay(DateTime(2026, 11, 26)), isFalse);
  });

  test('exam pushes open the list or the result page', () {
    expect(pushRoute({'kind': 'ExamStudy', 'targetId': 'e1'}), '/exams');
    expect(pushRoute({'kind': 'ExamResult', 'targetId': 'e1'}), '/exams/e1/result');
  });

  testWidgets('the list shows countdowns and the exam waiting for a result; a new exam is saved with a 3-day reminder', (tester) async {
    _phone(tester);
    final repo = _FakeExams();
    await tester.pumpWidget(_app(repo, const ExamsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Matematik'), findsOneWidget);
    expect(find.text('2 gün'), findsOneWidget);
    expect(find.text('7 gün'), findsOneWidget);
    expect(find.text('Sonuç bekleyen'), findsOneWidget);
    expect(find.byKey(const Key('exam.e3.result')), findsOneWidget);

    await tester.tap(find.byKey(const Key('exams.add')));
    await tester.pumpAndSettle();
    expect(find.text('Yeni sınav'), findsOneWidget);
    expect(find.text('3 gün önce, akşam 18:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exam.subject.Fen')));
    await tester.enterText(find.byKey(const Key('exam.topics')), 'Maddenin halleri');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('exam.save')));
    await tester.tap(find.byKey(const Key('exam.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['create c1 Fen Maddenin halleri 3']);
  });

  testWidgets('a result with a score gives five cherries by default', (tester) async {
    _phone(tester);
    final repo = _FakeExams();
    await tester.pumpWidget(_app(repo, const ExamResultScreen(examId: 'e3')));
    await tester.pumpAndSettle();
    expect(find.text('Ela · toplam 55 dk çalıştı'), findsOneWidget);

    await tester.tap(find.byKey(const Key('exam.saveResult')));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty, reason: 'how it went comes first');

    await tester.tap(find.byKey(const Key('exam.outcome.Great')));
    await tester.enterText(find.byKey(const Key('exam.score')), '92');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('exam.saveResult')));
    await tester.tap(find.byKey(const Key('exam.saveResult')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['result e3 Great 92 5']);
  });

  testWidgets('a study evening shows Çalışma zamanı with Başlat, which starts the timer for that exam', (tester) async {
    _phone(tester);
    final repo = _FakeExams();
    await tester.pumpWidget(_app(repo, Scaffold(body: ExamStudyRows(familyId: 'f1', day: DateTime.now()))));
    await tester.pumpAndSettle();
    expect(find.text('Çalışma zamanı · Matematik'), findsOneWidget);
    expect(find.text('Ela · 18:00 · sınava 2 gün'), findsOneWidget);
    await tester.tap(find.byKey(const Key('studyRow.e1.start')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['study c1 e1']);
    expect(find.text('Ela için ödev zamanlayıcısı başladı'), findsOneWidget);
  });
}
