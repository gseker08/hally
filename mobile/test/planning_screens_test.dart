import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/capture/capture_models.dart';
import 'package:hally/features/demo/demo_repository.dart';
import 'package:hally/features/demo/demo_scan_screen.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/home/today_screen.dart';
import 'package:hally/features/notifications/notifications_repository.dart';
import 'package:hally/features/planning/calendar_screen.dart';
import 'package:hally/features/planning/planning_repository.dart';
import 'package:hally/features/planning/tasks_screen.dart';
import 'package:hally/features/share/share_intake.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeReminders implements NotificationsRepository {
  final reminders = <(String, String, DateTime)>[];

  @override
  Future<void> createReminder(String familyId, {required String target, required String targetId, required DateTime fireAt, required bool forEveryone}) async =>
      reminders.add((target, targetId, fireAt));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlanning implements PlanningRepository {
  final open = <TaskItem>[const TaskItem(id: 't1', title: 'Beslenme çantası', allDay: false, state: 'Open')];
  final done = <TaskItem>[];
  final saved = <EventItem>[];
  final completed = <String>[];

  @override
  Future<void> completeTask(String familyId, String taskId) async {
    completed.add(taskId);
    final t = open.firstWhere((t) => t.id == taskId);
    open.remove(t);
    done.add(TaskItem(id: t.id, title: t.title, allDay: t.allDay, state: 'Done'));
  }

  @override
  Future<void> reopenTask(String familyId, String taskId) async {
    final t = done.firstWhere((t) => t.id == taskId);
    done.remove(t);
    open.add(TaskItem(id: t.id, title: t.title, allDay: t.allDay, state: 'Open'));
  }

  @override
  Future<List<TaskItem>> tasks(String familyId, {required String state}) async =>
      state == 'Done' ? done.where((t) => t.state == 'Done').toList() : List.of(open);

  @override
  Future<TaskItem> createTask(String familyId, {required String title, DateTime? dueDate, List<String> childIds = const []}) async {
    final t = TaskItem(id: 'n${open.length}', title: title, allDay: dueDate != null, dueAt: dueDate, state: 'Open', childIds: childIds);
    open.add(t);
    return t;
  }

  final updated = <String, String>{};
  final cancelled = <String>[];

  @override
  Future<TaskItem> updateTask(String familyId, String taskId,
      {required String title, String? notes, DateTime? dueAt, required bool allDay, String? assigneeUserId, List<String> childIds = const []}) async {
    final i = open.indexWhere((t) => t.id == taskId);
    final t = TaskItem(id: taskId, title: title, notes: notes, dueAt: dueAt, allDay: allDay, state: 'Open', childIds: childIds);
    open[i] = t;
    updated[taskId] = title;
    return t;
  }

  @override
  Future<void> cancelTask(String familyId, String taskId) async {
    cancelled.add(taskId);
    final t = open.firstWhere((t) => t.id == taskId);
    open.remove(t);
    done.add(TaskItem(id: t.id, title: t.title, allDay: t.allDay, state: 'Cancelled'));
  }

  @override
  Future<List<EventItem>> events(String familyId, DateTime from, DateTime to) async =>
      saved.where((e) => !e.startsAt.isBefore(from) && e.startsAt.isBefore(to)).toList();

  @override
  Future<SavedEvent> createEvent(String familyId,
      {required String title, required DateTime startsAt, required bool allDay, EventRepeat repeat = EventRepeat.none, List<String> childIds = const []}) async {
    final e = EventItem(id: 'e${saved.length}', title: title, startsAt: startsAt, allDay: allDay, repeat: repeat, childIds: childIds);
    final conflicts = saved.where((x) => x.startsAt == startsAt).toList();
    saved.add(e);
    return SavedEvent(event: e, conflicts: conflicts);
  }

  @override
  Future<SavedEvent> updateEvent(String familyId, EventItem original,
      {required String title, required DateTime startsAt, required bool allDay, required EventRepeat repeat, required List<String> childIds}) async {
    final e = EventItem(id: original.id, title: title, startsAt: startsAt, allDay: allDay, repeat: repeat, childIds: childIds);
    saved[saved.indexWhere((x) => x.id == original.id)] = e;
    return SavedEvent(event: e, conflicts: const []);
  }

  @override
  Future<void> deleteEvent(String familyId, String eventId) async => saved.removeWhere((e) => e.id == eventId);

  @override
  Future<TodayData> today(String familyId) async => TodayData(overdue: const [], dueToday: const [], events: List.of(saved), waiting: const []);
}

class _FakeDemo implements DemoRepository {
  @override
  Future<List<DemoItem>> scanSample(String sampleId, String locale) async => [
        const DemoItem(isEvent: false, payload: ProposalPayload(title: 'Kırmızı tişört giydir', date: '2026-11-13')),
        const DemoItem(isEvent: true, payload: ProposalPayload(title: 'Veli toplantısı', date: '2026-11-18', time: '18:00')),
      ];

  @override
  Future<List<DemoItem>> scanImage(List<int> bytes, String fileName, String contentType, String locale) => throw UnimplementedError();
}

const _kids = FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [
  ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky'),
  ChildProfile(id: 'c2', firstName: 'Can', color: 'mint'),
]);

Widget _app(Widget child, List<Override> overrides, {FamilyDetails family = const FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [])}) =>
    ProviderScope(
      overrides: [meProvider.overrideWith((ref) async => _me), familyProvider.overrideWith((ref, id) async => family), ...overrides],
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
        home: child,
      ),
    );

void main() {
  testWidgets('tasks: the child filter keeps that child and whole-family tasks', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _FakePlanning()
      ..open.addAll(const [
        TaskItem(id: 't2', title: 'Ela ödev', allDay: false, state: 'Open', childIds: ['c1']),
        TaskItem(id: 't3', title: 'Can yüzme', allDay: false, state: 'Open', childIds: ['c2']),
      ]);
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)], family: _kids));
    await tester.pumpAndSettle();
    expect(find.text('Ela ödev'), findsOneWidget);
    expect(find.text('Can yüzme'), findsOneWidget);

    await tester.tap(find.byKey(const Key('childFilter.c1')));
    await tester.pumpAndSettle();
    expect(find.text('Ela ödev'), findsOneWidget);
    expect(find.text('Beslenme çantası'), findsOneWidget, reason: 'untagged tasks belong to the whole family');
    expect(find.text('Can yüzme'), findsNothing);

    await tester.tap(find.byKey(const Key('childFilter.all')));
    await tester.pumpAndSettle();
    expect(find.text('Can yüzme'), findsOneWidget);
  });

  testWidgets('tasks: a new task can be tagged with several children', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)], family: _kids));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tasks.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task.title')), 'Veli toplantısı formu');
    await tester.tap(find.byKey(const Key('childPicker.c1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('childPicker.c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();
    expect(repo.open.last.childIds, unorderedEquals(['c1', 'c2']));
  });

  testWidgets('tasks: completing an open task moves it to done', (tester) async {
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    expect(find.text('Beslenme çantası'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task.t1.check')));
    await tester.pumpAndSettle();
    expect(repo.completed, ['t1']);
    expect(find.text('Açık görev yok'), findsOneWidget);

    await tester.tap(find.text('Tamamlanan'));
    await tester.pumpAndSettle();
    expect(find.text('Beslenme çantası'), findsOneWidget);
  });

  testWidgets('tasks: undo on the snackbar reopens a completed task', (tester) async {
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('task.t1.check')));
    await tester.pumpAndSettle();
    expect(find.text('Açık görev yok'), findsOneWidget);

    await tester.tap(find.byKey(const Key('task.undo')));
    await tester.pumpAndSettle();
    expect(repo.open.map((t) => t.id), ['t1']);
    expect(find.text('Beslenme çantası'), findsOneWidget);
  });

  testWidgets('tasks: tapping a row opens the task instead of completing it', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Beslenme çantası'));
    await tester.pumpAndSettle();
    expect(repo.completed, isEmpty);
    expect(find.byKey(const Key('taskSheet.title')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('taskSheet.title')), 'Beslenme çantasını hazırla');
    await tester.tap(find.byKey(const Key('taskSheet.save')));
    await tester.pumpAndSettle();
    expect(repo.updated, {'t1': 'Beslenme çantasını hazırla'});
    expect(repo.completed, isEmpty);
    expect(find.text('Beslenme çantasını hazırla'), findsOneWidget);
  });

  testWidgets('tasks: the task sheet can complete and delete, with undo', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Beslenme çantası'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('taskSheet.toggle')));
    await tester.pumpAndSettle();
    expect(repo.completed, ['t1']);
    await tester.tap(find.byKey(const Key('task.undo')));
    await tester.pumpAndSettle();
    expect(find.text('Beslenme çantası'), findsOneWidget);

    await tester.tap(find.text('Beslenme çantası'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('taskSheet.delete')));
    await tester.pumpAndSettle();
    expect(repo.cancelled, ['t1']);
    expect(find.text('Açık görev yok'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task.undo')));
    await tester.pumpAndSettle();
    expect(find.text('Beslenme çantası'), findsOneWidget);
  });

  testWidgets('today: tapping a task row opens it, only the circle completes it', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(
      Scaffold(body: TaskTile(task: repo.open.first, familyId: 'f1', color: Colors.green)),
      [planningRepositoryProvider.overrideWithValue(repo)],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Beslenme çantası'));
    await tester.pumpAndSettle();
    expect(repo.completed, isEmpty);
    expect(find.byKey(const Key('taskSheet.title')), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const Key('taskSheet.title')))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('task.t1.check')));
    await tester.pumpAndSettle();
    expect(repo.completed, ['t1']);
  });

  testWidgets('tasks: quick add creates an open task', (tester) async {
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const TasksScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tasks.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task.title')), 'İzin kağıdını imzala');
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();
    expect(find.text('İzin kağıdını imzala'), findsOneWidget);
  });

  testWidgets('calendar: added event shows on the selected day and conflicts are flagged', (tester) async {
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const CalendarScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();
    expect(find.text('Bu güne planlanmış bir şey yok'), findsOneWidget);

    for (final _ in [1, 2]) {
      await tester.tap(find.byKey(const Key('calendar.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('event.title')), 'Yüzme');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Yüzme'), findsNWidgets(2));
    expect(find.text('Bu saatte başka bir etkinlik var: Yüzme'), findsOneWidget);
  });

  testWidgets('calendar: a new timed event gets a reminder unless it is turned off', (tester) async {
    final repo = _FakePlanning();
    final reminders = _FakeReminders();
    await tester.pumpWidget(_app(const CalendarScreen(),
        [planningRepositoryProvider.overrideWithValue(repo), notificationsRepositoryProvider.overrideWithValue(reminders)]));
    await tester.pumpAndSettle();

    Future<void> addAtNine(String title, {bool noReminder = false}) async {
      await tester.tap(find.byKey(const Key('calendar.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('event.title')), title);
      // All-day events have no reminder choice.
      expect(find.byKey(const Key('event.reminder')), findsNothing);
      await tester.tap(find.byIcon(Icons.schedule));
      await tester.pumpAndSettle();
      await tester.tap(find.text(MaterialLocalizations.of(tester.element(find.byType(TimePickerDialog))).okButtonLabel));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event.reminder')), findsOneWidget);
      if (noReminder) {
        await tester.tap(find.byKey(const Key('event.reminder')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hatırlatma yok').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
    }

    await addAtNine('Yüzme', noReminder: true);
    expect(reminders.reminders, isEmpty);

    await addAtNine('Veli toplantısı');
    final startsAt = repo.saved.last.startsAt;
    if (startsAt.isAfter(DateTime.now())) {
      final (target, id, fireAt) = reminders.reminders.single;
      expect((target, id), ('Event', repo.saved.last.id));
      expect(fireAt.isAfter(startsAt), isFalse);
    } else {
      // Today's 09:00 has already passed while the test runs: the editor says so instead of failing silently.
      expect(reminders.reminders, isEmpty);
      expect(find.text('Etkinliğin saati geçtiği için hatırlatma kurulmadı'), findsOneWidget);
    }
  });

  testWidgets('calendar: a weekly event is saved as a series and labelled', (tester) async {
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const CalendarScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calendar.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('event.title')), 'Yüzme');
    await tester.tap(find.byKey(const Key('event.repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Her hafta').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(repo.saved.single.repeat, EventRepeat.weekly);
    expect(find.textContaining('Her hafta'), findsOneWidget);
  });

  testWidgets('calendar: add-event dialog scrolls instead of overflowing on a short screen with large text', (tester) async {
    tester.view.physicalSize = const Size(1080, 1500);
    tester.view.devicePixelRatio = 2.625;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repo = _FakePlanning();
    await tester.pumpWidget(_app(const CalendarScreen(), [planningRepositoryProvider.overrideWithValue(repo)], family: _kids));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calendar.add')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byKey(const Key('event.title')), 'Yüzme');
    await tester.ensureVisible(find.byKey(const Key('childPicker.c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('childPicker.c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();
    expect(repo.saved.single.childIds, ['c2']);
  });

  testWidgets('calendar: tapping an event edits it, with its values filled in', (tester) async {
    final repo = _FakePlanning();
    final day = DateTime.now();
    repo.saved.add(EventItem(id: 'e0', title: 'Yüzme', startsAt: DateTime(day.year, day.month, day.day, 17), allDay: false, childIds: const ['c1']));
    await tester.pumpWidget(_app(const CalendarScreen(), [planningRepositoryProvider.overrideWithValue(repo)], family: _kids));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('event.e0')));
    await tester.pumpAndSettle();
    expect(find.text('Etkinliği düzenle'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Yüzme'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('event.title')), 'Yüzme kursu');
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(repo.saved.single.title, 'Yüzme kursu');
    expect(repo.saved.single.startsAt.hour, 17);
    expect(repo.saved.single.childIds, ['c1']);
    expect(find.text('Yüzme kursu'), findsOneWidget);
  });

  testWidgets('calendar: deleting a repeating event asks first and removes the series', (tester) async {
    final repo = _FakePlanning();
    final day = DateTime.now();
    repo.saved.add(EventItem(id: 'e0', title: 'Piyano', startsAt: DateTime(day.year, day.month, day.day, 16), allDay: false, repeat: EventRepeat.weekly));
    await tester.pumpWidget(_app(const CalendarScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('event.e0')));
    await tester.pumpAndSettle();
    expect(find.text('Tekrarlanan etkinlik: değişiklikler tüm tekrarlara uygulanır.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('event.delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tüm tekrarlarıyla birlikte silinir'), findsOneWidget);
    await tester.tap(find.byKey(const Key('event.deleteConfirm')));
    await tester.pumpAndSettle();

    expect(repo.saved, isEmpty);
    expect(find.text('Etkinlik silindi.'), findsOneWidget);
    expect(find.text('Bu güne planlanmış bir şey yok'), findsOneWidget);
  });

  testWidgets('calendar: month view shows the whole month and keeps the selected day', (tester) async {
    final repo = _FakePlanning();
    final now = DateTime.now();
    repo.saved.add(EventItem(id: 'x', title: 'Veli toplantısı', startsAt: DateTime(now.year, now.month, now.day, 18), allDay: false));
    await tester.pumpWidget(_app(const CalendarScreen(), [planningRepositoryProvider.overrideWithValue(repo)]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calendar.view.month')));
    await tester.pumpAndSettle();
    final last = DateTime(now.year, now.month + 1, 0);
    expect(find.byKey(Key('calendar.day.${now.year}-${now.month}-1')), findsOneWidget);
    expect(find.byKey(Key('calendar.day.${last.year}-${last.month}-${last.day}')), findsOneWidget);
    expect(find.text('Veli toplantısı'), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar.next')));
    await tester.pumpAndSettle();
    final next = DateTime(now.year, now.month + 1, 1);
    expect(find.byKey(Key('calendar.day.${next.year}-${next.month}-1')), findsOneWidget);
  });

  testWidgets('demo: scanning the sample shows what Hally found', (tester) async {
    await tester.pumpWidget(_app(const DemoScanScreen(), [demoRepositoryProvider.overrideWithValue(_FakeDemo())]));
    await tester.tap(find.byKey(const Key('demo.scan')));
    await tester.pumpAndSettle();
    expect(find.text('2 şey buldum'), findsOneWidget);
    expect(find.text('Veli toplantısı'), findsOneWidget);
    expect(find.byKey(const Key('demo.save')), findsOneWidget);
  });

  test('share mapping keeps text and images, drops other files', () {
    expect(mapShared('text', '  Yarın gezi var  ', null), isA<SharedText>().having((t) => t.text, 'text', 'Yarın gezi var'));
    expect(mapShared('url', '', null), isNull);
    expect(mapShared('image', '/tmp/a.PNG', null), isA<SharedImage>().having((i) => i.mimeType, 'mime', 'image/png'));
    expect(mapShared('video', '/tmp/a.mp4', 'video/mp4'), isNull);
  });
}
