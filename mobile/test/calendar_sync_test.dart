import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/calendar_sync/calendar_sync.dart';
import 'package:hally/features/calendar_sync/calendar_sync_screens.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/planning/calendar_screen.dart';
import 'package:hally/features/planning/planning_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe Yılmaz', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _family = FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: []);

class _Phone implements PhoneCalendarGateway {
  _Phone({this.state = CalendarAccess.granted});

  CalendarAccess state;
  final cals = <PhoneCalendar>[
    const PhoneCalendar(id: 'g-work', name: 'İş', provider: CalendarProvider.google, accountName: 'ayse@gmail.com', colorHex: '#4F7590'),
    const PhoneCalendar(id: 'g-home', name: 'Kişisel', provider: CalendarProvider.google, accountName: 'ayse@gmail.com', colorHex: '#FF5F7F5A'),
    const PhoneCalendar(id: 'g-hol', name: 'Türkiye tatilleri', provider: CalendarProvider.google, accountName: 'ayse@gmail.com', subscribed: true),
  ];
  final phoneEvents = <PhoneEvent>[];
  final created = <String, ({String calendarId, String title, DateTime start, bool allDay})>{};
  final deleted = <String>[];
  final deletedCalendars = <String>[];
  var _n = 0;

  @override
  Future<CalendarAccess> access() async => state;

  @override
  Future<bool> requestAccess() async {
    if (state == CalendarAccess.notDetermined) state = CalendarAccess.granted;
    return state == CalendarAccess.granted;
  }

  @override
  Future<void> openSettings() async {}

  @override
  Future<List<PhoneCalendar>> calendars() async => List.of(cals);

  @override
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> calendarIds) async =>
      phoneEvents.where((e) => calendarIds.contains(e.calendarId) && e.start.isBefore(to) && e.end.isAfter(from)).toList();

  @override
  Future<String> createCalendar(String name, String colorHex) async {
    final id = 'cal${_n++}';
    cals.add(PhoneCalendar(id: id, name: name, provider: CalendarProvider.other, colorHex: colorHex));
    return id;
  }

  @override
  Future<void> deleteCalendar(String id) async {
    deletedCalendars.add(id);
    cals.removeWhere((c) => c.id == id);
  }

  @override
  Future<String> createEvent(String calendarId, {required String title, required DateTime start, required DateTime end, required bool allDay, String? location}) async {
    final id = 'ev${_n++}';
    created[id] = (calendarId: calendarId, title: title, start: start, allDay: allDay);
    return id;
  }

  @override
  Future<void> deleteEvent(String instanceId) async {
    deleted.add(instanceId);
    created.remove(instanceId);
  }

  @override
  Future<void> openEvent(String instanceId) async {}
}

class _Storage implements CalendarSyncStorage {
  _Storage([this.value = const CalendarSyncSettings()]);

  CalendarSyncSettings? value;

  @override
  Future<CalendarSyncSettings?> read() async => value;

  @override
  Future<void> write(CalendarSyncSettings settings) async => value = settings;
}

class _Api implements CalendarSyncApi {
  List<Map<String, dynamic>>? lastShare;
  var stopped = 0;
  var shared = <SharedEvent>[];
  var feeds = 0;

  @override
  Future<List<SharedEvent>> sharedEvents(String familyId, DateTime from, DateTime to) async => shared;

  @override
  Future<void> share(String familyId, List<Map<String, dynamic>> events) async => lastShare = events;

  @override
  Future<void> stopSharing(String familyId) async => stopped++;

  @override
  Future<bool> feedActive(String familyId) async => feeds > 0;

  @override
  Future<FeedLink> createFeed(String familyId) async {
    feeds++;
    return FeedLink('https://api.hally.app/ics/tok$feeds.ics', 'webcal://api.hally.app/ics/tok$feeds.ics');
  }

  @override
  Future<void> revokeFeed(String familyId) async {}
}

class _Planning implements PlanningRepository {
  final saved = <EventItem>[];

  @override
  Future<List<EventItem>> events(String familyId, DateTime from, DateTime to) async =>
      saved.where((e) => !e.startsAt.isBefore(from) && e.startsAt.isBefore(to)).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Override> _overrides(_Phone phone, _Storage storage, _Api api, _Planning planning) => [
      meProvider.overrideWith((ref) async => _me),
      familyProvider.overrideWith((ref, id) async => _family),
      phoneCalendarGatewayProvider.overrideWithValue(phone),
      calendarSyncStorageProvider.overrideWithValue(storage),
      calendarSyncApiProvider.overrideWithValue(api),
      planningRepositoryProvider.overrideWithValue(planning),
    ];

Widget _app(Widget home, List<Override> overrides) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => home),
    GoRoute(path: '/calendar-sync', builder: (_, __) => const ConnectedCalendarsScreen()),
    GoRoute(
        path: '/calendar-sync/:provider',
        builder: (_, s) => CalendarConnectScreen(provider: CalendarProvider.values.firstWhere((p) => p.name == s.pathParameters['provider']))),
  ]);
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildHallyTheme(Brightness.light),
      locale: const Locale('tr'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

void _phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('accounts are recognised on both platforms', () {
    expect(providerOf('ayse@gmail.com', 'com.google'), CalendarProvider.google);
    expect(providerOf('Gmail', 'calDav'), CalendarProvider.google);
    expect(providerOf('iCloud', 'calDav'), CalendarProvider.icloud);
    expect(providerOf('ayse@icloud.com', 'com.example.caldav'), CalendarProvider.icloud);
    expect(providerOf('Outlook', 'exchange'), CalendarProvider.outlook);
    expect(providerOf('mehmet@sirket.com', 'com.microsoft.office.outlook'), CalendarProvider.outlook);
    expect(providerOf('mehmet@hotmail.com', 'com.android.exchange'), CalendarProvider.outlook);
    expect(providerOf('Telefonda', 'LOCAL'), CalendarProvider.other);
  });

  test('sync shares family calendars, keeps "only me" on the phone and writes Hally events to a Hally calendar', () async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day + 1);
    final phone = _Phone()
      ..phoneEvents.addAll([
        PhoneEvent(calendarId: 'g-work', eventId: 'w1', instanceId: 'w1', title: 'Bütçe toplantısı', start: day.add(const Duration(hours: 9)), end: day.add(const Duration(hours: 10)), allDay: false),
        PhoneEvent(calendarId: 'g-home', eventId: 'h1', instanceId: 'h1', title: 'Diş hekimi', start: day.add(const Duration(hours: 17)), end: day.add(const Duration(hours: 18)), allDay: false),
      ]);
    final storage = _Storage(const CalendarSyncSettings(
        familyId: 'f1', calendars: {'g-work': ShareMode.onlyMe, 'g-home': ShareMode.family}, exportEnabled: true));
    final api = _Api();
    final planning = _Planning()
      ..saved.addAll([
        EventItem(id: 'e1', title: 'Piyano dersi', startsAt: day.add(const Duration(hours: 16)), allDay: false, childIds: const ['c1']),
        EventItem(id: 'e2', title: 'Okul gezisi', startsAt: day.add(const Duration(days: 2)), allDay: true),
      ]);
    final container = ProviderContainer(overrides: _overrides(phone, storage, api, planning));
    addTearDown(container.dispose);
    await container.read(meProvider.future);

    await container.read(calendarSyncServiceProvider).run();
    expect(api.lastShare!.map((e) => e['title']), ['Diş hekimi'], reason: '"only me" calendars never leave the phone');
    expect(api.lastShare!.single['provider'], 'Google');
    expect(api.lastShare!.single['colorHex'], '#5F7F5A');
    final hally = storage.value!.hallyCalendarId!;
    expect(phone.created.values.map((e) => (e.calendarId, e.title)), [(hally, 'Piyano dersi'), (hally, 'Okul gezisi')]);
    expect(phone.created.values.last.allDay, isTrue);
    expect(storage.value!.lastSync, isNotNull);

    // Busy only, a moved Hally event and a removed one.
    await container.read(calendarSyncSettingsProvider.notifier).save(storage.value!.copyWith(busyOnly: true, exportChildId: 'c1'));
    planning.saved[0] = EventItem(id: 'e1', title: 'Piyano dersi', startsAt: day.add(const Duration(hours: 15)), allDay: false, childIds: const ['c1']);
    await container.read(calendarSyncServiceProvider).run(force: true);
    expect(api.lastShare!.single['title'], isNull);
    expect(api.lastShare!.single['busyOnly'], isTrue);
    expect(phone.created.values.map((e) => (e.title, e.start.hour)), [('Piyano dersi', 15)], reason: 'only Ela\'s events, and the moved one is rewritten');
    expect(phone.deleted, hasLength(2));

    // Nothing shared any more: the server copy is cleared once.
    await container.read(calendarSyncSettingsProvider.notifier).save(storage.value!.copyWith(calendars: {'g-work': ShareMode.onlyMe}));
    await container.read(calendarSyncServiceProvider).run(force: true);
    expect(api.stopped, 1);
    expect(storage.value!.sharedBefore, isFalse);

    await container.read(calendarSyncServiceProvider).disconnect();
    expect(phone.deletedCalendars, [hally]);
    expect(storage.value!.calendars, isEmpty);
    expect(storage.value!.exportEnabled, isFalse);
  });

  test('sync does nothing without calendar access', () async {
    final phone = _Phone(state: CalendarAccess.denied);
    final api = _Api();
    final storage = _Storage(const CalendarSyncSettings(familyId: 'f1', calendars: {'g-home': ShareMode.family}, exportEnabled: true));
    final container = ProviderContainer(overrides: _overrides(phone, storage, api, _Planning()));
    addTearDown(container.dispose);
    await container.read(meProvider.future);
    await container.read(calendarSyncServiceProvider).run();
    expect(api.lastShare, isNull);
    expect(phone.created, isEmpty);
  });

  testWidgets('calendar tab offers calendar sync once and shows outside events read-only', (tester) async {
    _phoneSize(tester);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final phone = _Phone()
      ..phoneEvents.add(PhoneEvent(
          calendarId: 'g-work', eventId: 'w1', instanceId: 'w1', title: 'Bütçe toplantısı',
          start: today.add(const Duration(hours: 9, minutes: 30)), end: today.add(const Duration(hours: 10, minutes: 30)), allDay: false));
    final storage = _Storage();
    final api = _Api()
      ..shared = [
        SharedEvent(id: 's1', ownerName: 'Mehmet', mine: false, provider: CalendarProvider.outlook, calendarName: 'Ofis', busyOnly: true,
            startsAt: today.add(const Duration(hours: 19)), endsAt: today.add(const Duration(hours: 21)), allDay: false),
      ];
    final planning = _Planning()..saved.add(EventItem(id: 'e1', title: 'Piyano dersi', startsAt: today.add(const Duration(hours: 16)), allDay: false));

    await tester.pumpWidget(_app(const CalendarScreen(), _overrides(phone, storage, api, planning)));
    await tester.pumpAndSettle();
    expect(find.text('Takvimini bağla, aile planın tek yerde dursun'), findsOneWidget);
    await tester.tap(find.byKey(const Key('calSync.later')));
    await tester.pumpAndSettle();
    expect(storage.value!.inviteDone, isTrue);
    expect(find.text('Mehmet meşgul'), findsOneWidget, reason: 'the other parent shared only "busy"');
    expect(find.text('Bütçe toplantısı'), findsNothing, reason: 'no phone calendar picked yet');

    await storage.write(storage.value!.copyWith(calendars: {'g-work': ShareMode.onlyMe}));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(const CalendarScreen(), _overrides(phone, storage, api, planning)));
    await tester.pumpAndSettle();
    expect(find.text('Takvimini bağla, aile planın tek yerde dursun'), findsNothing, reason: 'offered only once');
    expect(find.text('Bütçe toplantısı'), findsOneWidget);
    expect(find.textContaining('Sadece sen'), findsOneWidget);
    final titles = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).where((t) => ['Bütçe toplantısı', 'Piyano dersi', 'Mehmet meşgul'].contains(t));
    expect(titles, ['Bütçe toplantısı', 'Piyano dersi', 'Mehmet meşgul'], reason: 'Hally and outside events interleave by time');

    await tester.tap(find.text('Bütçe toplantısı'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calSync.openEvent')), findsOneWidget);
    expect(find.textContaining('Kaynak: Google Takvim · İş'), findsOneWidget);
  });

  testWidgets('connect screen asks for access, picks calendars and shares the family ones', (tester) async {
    _phoneSize(tester);
    final now = DateTime.now();
    final phone = _Phone(state: CalendarAccess.notDetermined)
      ..phoneEvents.add(PhoneEvent(
          calendarId: 'g-home', eventId: 'h1', instanceId: 'h1', title: 'Diş hekimi',
          start: now.add(const Duration(days: 1)), end: now.add(const Duration(days: 1, hours: 1)), allDay: false));
    final storage = _Storage(const CalendarSyncSettings(familyId: 'f1', inviteDone: true));
    final api = _Api();
    await tester.pumpWidget(_app(const CalendarConnectScreen(provider: CalendarProvider.google), _overrides(phone, storage, api, _Planning())));
    await tester.pumpAndSettle();

    expect(find.text('ayse@gmail.com'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byKey(const Key('calSync.pick.g-work'))).value, isTrue);
    expect(tester.widget<Checkbox>(find.byKey(const Key('calSync.pick.g-hol'))).value, isFalse, reason: 'holidays are not ticked by default');
    await tester.tap(find.descendant(of: find.byKey(const Key('calSync.mode.g-home')), matching: find.text('Ailem')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('calSync.save')), 200);
    await tester.tap(find.byKey(const Key('calSync.export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calSync.save')));
    await tester.pumpAndSettle();

    expect(storage.value!.calendars, {'g-work': ShareMode.onlyMe, 'g-home': ShareMode.family});
    expect(storage.value!.exportEnabled, isFalse);
    expect(api.lastShare!.map((e) => e['title']), ['Diş hekimi']);
  });

  testWidgets('without an account on the phone the screen explains how to add it or use the link', (tester) async {
    _phoneSize(tester);
    final storage = _Storage(const CalendarSyncSettings(familyId: 'f1'));
    final api = _Api();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_app(const CalendarConnectScreen(provider: CalendarProvider.icloud), _overrides(_Phone(), storage, api, _Planning())));
    await tester.pumpAndSettle();
    expect(find.text('Bu telefonda iCloud hesabı yok'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('calSync.retry')), 200);
    await tester.tap(find.byKey(const Key('calSync.copyFeed')));
    await tester.pumpAndSettle();
    expect(api.feeds, 1);
    expect(storage.value!.feedUrl, 'https://api.hally.app/ics/tok1.ics');
    expect(find.text('Bağlantı kopyalandı'), findsOneWidget);
    expect(copied, 'https://api.hally.app/ics/tok1.ics');
  });

  testWidgets('connected calendars screen shows status, the link and disconnects', (tester) async {
    _phoneSize(tester);
    final storage = _Storage(const CalendarSyncSettings(
        familyId: 'f1', inviteDone: true, calendars: {'g-home': ShareMode.family}, feedUrl: 'https://api.hally.app/ics/x.ics', sharedBefore: true));
    final api = _Api()..feeds = 1;
    final phone = _Phone();
    await tester.pumpWidget(_app(const ConnectedCalendarsScreen(), _overrides(phone, storage, api, _Planning())));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('calSync.provider.google')), matching: find.text('Bağlı')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('calSync.provider.icloud')), matching: find.text('Bu telefonda hesap yok')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('https://api.hally.app/ics/x.ics'), 200);

    await tester.scrollUntilVisible(find.byKey(const Key('calSync.disconnect')), 200);
    await tester.tap(find.byKey(const Key('calSync.disconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Takvim bağlantısını kaldır'));
    await tester.pumpAndSettle();
    expect(api.stopped, 1);
    expect(storage.value!.calendars, isEmpty);
    expect(storage.value!.feedUrl, 'https://api.hally.app/ics/x.ics', reason: 'the computer link is managed separately');
  });
}
