import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/child_mode/child_lock.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/child_mode/kid_screens.dart';
import 'package:hally/features/child_mode/parent_child_mode.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';
import 'package:hally/router.dart';

ChildHome _home(
        {List<ChildItem>? today,
        int balance = 34,
        ChildScreen screen = const ChildScreen(goalMinutes: 60, limitMinutes: 60, usedSeconds: 1560),
        String? mood = 'Good'}) =>
    ChildHome(
      todayMood: mood,
      childId: 'c1',
      firstName: 'Ela',
      color: 'cherry',
      familyName: 'Yılmaz',
      balance: balance,
      weekCherries: 21,
      streakDays: 6,
      nextBonusIn: 1,
      today: today ??
          const [
            ChildItem(id: 'k1', kind: 'Chore', title: 'Odanı topla', cherries: 3, state: 'Todo'),
            ChildItem(id: 'h1', kind: 'Habit', title: 'Dişlerini fırçala', cherries: 1, state: 'Done'),
          ],
      rewards: const [
        ChildReward(id: 'r1', title: '15 dk ekstra ekran', cost: 20, screenMinutes: 15),
        ChildReward(id: 'r2', title: 'Park günü', cost: 50),
      ],
      screen: screen,
    );

class _KidApi implements ChildApi {
  _KidApi(this.current);

  ChildHome current;
  final calls = <String>[];

  @override
  Future<ChildHome> home() async => current;

  @override
  Future<ChildHome> markDone(ChildItem item) async {
    calls.add('done ${item.id}');
    current = _home(today: [
      for (final i in current.today) i.id == item.id ? ChildItem(id: i.id, kind: i.kind, title: i.title, cherries: i.cherries, state: 'Pending') : i,
    ]);
    return current;
  }

  @override
  Future<ChildHome> redeem(String rewardId) async {
    calls.add('redeem $rewardId');
    return current;
  }

  @override
  Future<void> requestTime(int minutes) async => calls.add('ask $minutes');

  @override
  Future<void> exit(String pin) async {
    calls.add('exit $pin');
    if (pin != '2580') throw const ChildExitException('child.exit_pin_wrong', triesLeft: 4);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ParentRepo implements ChildModeRepository {
  final calls = <String>[];
  var claimList = [
    ChildClaim(id: 'cl1', childId: 'c1', childName: 'Ela', kind: 'Chore', title: 'Odasını topladı', cherries: 3, at: DateTime(2026, 11, 25, 14, 5)),
  ];

  @override
  Future<PairingCode> pairingCode(String familyId, String childId) async {
    calls.add('code $childId');
    return PairingCode('482715', DateTime.now().add(const Duration(minutes: 10)));
  }

  var deviceList = [ChildDevice(id: 'd1', name: "Ela'nın telefonu", pairedAt: DateTime(2026, 11, 25), lastSeenAt: DateTime(2026, 11, 25, 15))];

  @override
  Future<List<ChildDevice>> devices(String familyId, String childId) async => deviceList;

  @override
  Future<bool> requireApproval(String familyId) async => true;

  bool pinSet = false;

  @override
  Future<bool> hasExitPin(String familyId) async => pinSet;

  @override
  Future<bool> setExitPin(String familyId, String? pin) async {
    calls.add('pin $pin');
    return pinSet = pin != null;
  }

  @override
  Future<ChildScreen> deviceScreen(String familyId, String childId) async =>
      const ChildScreen(goalMinutes: 60, limitMinutes: 60, usedSeconds: 3700, locked: true);

  @override
  Future<ChildScreen> grant(String familyId, String childId, int minutes) async {
    calls.add('grant $minutes');
    return const ChildScreen(goalMinutes: 60, limitMinutes: 75, usedSeconds: 3700);
  }

  @override
  Future<List<ChildClaim>> claims(String familyId) async => claimList;

  @override
  Future<List<ChildClaim>> decide(String familyId, String claimId, {required bool approve}) async {
    calls.add('${approve ? 'approve' : 'reject'} $claimId');
    claimList = [];
    return claimList;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _family = FamilyDetails(
  id: 'f1',
  name: 'Yılmaz',
  timeZoneId: 'Europe/Istanbul',
  members: [FamilyMember(userId: 'u1', displayName: 'Ayşe', role: 'Owner')],
  children: [ChildProfile(id: 'c1', firstName: 'Ela')],
);

Widget _app(Widget home, {ChildApi? kid, ChildModeRepository? parent, ChildLockStatus? lock}) => ProviderScope(
      overrides: [
        if (lock != null) childLockStatusProvider.overrideWith((ref) async => lock),
        if (kid != null) childApiProvider.overrideWithValue(kid),
        if (parent != null) ...[
          childModeRepositoryProvider.overrideWithValue(parent),
          childClaimsProvider.overrideWith((ref, id) => parent.claims(id)),
        ],
        familyProvider.overrideWith((ref, id) async => _family),
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
  test('a paired child phone only shows child mode', () {
    const me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: []);
    expect(resolveRedirect(location: '/today', loading: false, me: null, pendingInviteToken: null, childMode: true), '/kid');
    expect(resolveRedirect(location: '/kid', loading: false, me: null, pendingInviteToken: null, childMode: true), isNull);
    expect(resolveRedirect(location: '/kid/pair', loading: false, me: null, pendingInviteToken: null), isNull);
    expect(resolveRedirect(location: '/kid', loading: false, me: null, pendingInviteToken: null), '/');
    expect(resolveRedirect(location: '/kid', loading: false, me: me, pendingInviteToken: null), '/');
  });

  testWidgets('the child marks a job done and it waits for approval', (tester) async {
    _phone(tester);
    final api = _KidApi(_home());
    await tester.pumpWidget(_app(const KidShell(), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Merhaba Ela!'), findsOneWidget);
    expect(find.byKey(const Key('kid.balance')), findsOneWidget);
    expect(find.text('34'), findsWidgets);
    expect(find.text('Bir sonraki ödül: Park günü'), findsOneWidget);

    await tester.tap(find.text('Odanı topla'));
    await tester.pumpAndSettle();
    expect(api.calls, ['done k1']);
    expect(find.text('Onay bekliyor'), findsOneWidget);

    // A done habit cannot be tapped again.
    await tester.tap(find.text('Dişlerini fırçala'));
    await tester.pumpAndSettle();
    expect(api.calls, ['done k1']);

    await tester.tap(find.byKey(const Key('kid.tab.rewards')));
    await tester.pumpAndSettle();
    expect(find.text('Ödüllerim'), findsOneWidget);
    expect(find.text('16 kiraz daha'), findsOneWidget);
    await tester.tap(find.byKey(const Key('kid.buy.r1')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'redeem r1');

    await tester.tap(find.byKey(const Key('kid.tab.jar')));
    await tester.pumpAndSettle();
    expect(find.text('Kiraz kavanozum'), findsOneWidget);
    expect(find.textContaining('Altın kiraza 1 gün kaldı!'), findsOneWidget);
    expect(find.text('21 kiraz topladın'), findsOneWidget);
  });

  testWidgets('when time is up the lock page offers cherries and asking a parent', (tester) async {
    _phone(tester);
    final api = _KidApi(_home(screen: const ChildScreen(goalMinutes: 90, limitMinutes: 90, usedSeconds: 5400, locked: true)));
    await tester.pumpWidget(_app(const KidShell(), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Ekran süren doldu'), findsOneWidget);
    expect(find.textContaining('1 saat 30 dakika'), findsOneWidget);
    expect(find.text('20 kiraz ile 15 dk daha'), findsOneWidget);
    await tester.tap(find.byKey(const Key('kid.lock.ask')));
    await tester.pumpAndSettle();
    expect(api.calls, ['ask 15']);
    expect(find.text('İsteğin gitti'), findsWidgets);
  });

  testWidgets('holding the greeting asks for the parent PIN and leaves child mode', (tester) async {
    _phone(tester);
    final api = _KidApi(_home());
    await tester.pumpWidget(_app(const KidShell(), kid: api));
    await tester.pumpAndSettle();

    // A short press does nothing.
    await tester.longPress(find.byKey(const Key('kid.hello')));
    await tester.pumpAndSettle();
    expect(find.text('Ebeveyn çıkışı'), findsNothing);

    final hold = await tester.startGesture(tester.getCenter(find.byKey(const Key('kid.hello'))));
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    await hold.up();
    await tester.pumpAndSettle();
    expect(find.text('Ebeveyn çıkışı'), findsOneWidget);

    for (final d in ['1', '1', '1', '1']) {
      await tester.tap(find.byKey(Key('pin.$d')));
    }
    await tester.pumpAndSettle();
    expect(find.text('PIN yanlış · 4 deneme kaldı'), findsOneWidget);

    for (final d in ['2', '5', '8', '0']) {
      await tester.tap(find.byKey(Key('pin.$d')));
    }
    await tester.pumpAndSettle();
    expect(api.calls, ['exit 1111', 'exit 2580']);
    expect(find.text('Ebeveyn çıkışı'), findsNothing);
  });

  testWidgets('a parent sets the exit PIN by typing it twice', (tester) async {
    _phone(tester);
    final repo = _ParentRepo();
    await tester.pumpWidget(_app(const ConnectPhoneScreen(familyId: 'f1', childId: 'c1'), parent: repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(find.byKey(const Key('phone.exitPin.edit')), 200);
    await tester.ensureVisible(find.byKey(const Key('phone.exitPin.edit')));
    await tester.pumpAndSettle();
    expect(find.text('PIN yok'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone.exitPin.edit')));
    await tester.pumpAndSettle();
    expect(find.text('Yeni PIN belirle'), findsOneWidget);
    for (final d in ['2', '5', '8', '0']) {
      await tester.tap(find.byKey(Key('pin.$d')));
    }
    await tester.pump();
    expect(find.text("PIN'i tekrar gir"), findsOneWidget);
    for (final d in ['2', '5', '8', '1']) {
      await tester.tap(find.byKey(Key('pin.$d')));
    }
    await tester.pump();
    expect(find.text('PIN\'ler aynı değil, baştan girin.'), findsOneWidget);
    for (final d in ['2', '5', '8', '0', '2', '5', '8', '0']) {
      await tester.tap(find.byKey(Key('pin.$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'pin 2580');
    expect(find.text('Çıkış PIN\'i kaydedildi.'), findsOneWidget);
    expect(find.text('✓ PIN ayarlı'), findsOneWidget);
  });

  testWidgets('a parent sees the pairing code, the phone and gives extra time', (tester) async {
    _phone(tester);
    final repo = _ParentRepo();
    await tester.pumpWidget(_app(const ConnectPhoneScreen(familyId: 'f1', childId: 'c1'), parent: repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Ela için telefon'), findsOneWidget);
    for (final d in ['4', '8', '2', '7', '1', '5']) {
      expect(find.descendant(of: find.byKey(const Key('phone.code')), matching: find.text(d)), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.text("Ela'nın telefonu"), 200);
    expect(find.text("Ela'nın telefonu"), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Kilitli'), 200);
    expect(find.text('Kilitli'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('phone.give.15')), 200);
    await tester.tap(find.byKey(const Key('phone.give.15')));
    await tester.pump();
    expect(repo.calls, ['code c1', 'grant 15']);
  });

  testWidgets('the code screen shows the steps, waits for the phone and says when it connected', (tester) async {
    _phone(tester);
    final repo = _ParentRepo()..deviceList = [];
    await tester.pumpWidget(_app(const ConnectPhoneScreen(familyId: 'f1', childId: 'c1'), parent: repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("Çocuğun telefonuna Hally'yi indir"), findsOneWidget);
    expect(find.byKey(const Key('phone.whatsapp')), findsOneWidget);
    expect(find.byKey(const Key('phone.copy')), findsOneWidget);
    expect(find.text('Telefon bekleniyor…'), findsOneWidget);
    expect(find.byKey(const Key('phone.paired')), findsNothing);

    // The child's phone uses the code; the screen notices on its next refresh.
    repo.deviceList = [ChildDevice(id: 'd2', name: null, pairedAt: DateTime.now(), lastSeenAt: DateTime.now())];
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('phone.paired')), findsOneWidget);
    expect(find.text('Telefon bağlandı'), findsOneWidget);
    expect(find.text('Telefon bekleniyor…'), findsNothing);
  });

  test('a pasted message gives its six-digit code', () {
    const f = PairingCodeFormatter();
    TextEditingValue paste(String text) => f.formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: text));
    expect(paste('Hally kodun: 482 913\nHally\'yi aç ve kodu gir.').text, '482913');
    expect(paste('482913').text, '482913');
    expect(paste('48a2').text, '482');
    expect(paste('12345678').text, '123456');
  });

  testWidgets('the approval card on Today approves a claim', (tester) async {
    _phone(tester);
    final repo = _ParentRepo();
    await tester.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ChildClaimsCard(familyId: 'f1'))), parent: repo));
    await tester.pumpAndSettle();

    expect(find.text('Ela: Odasını topladı'), findsOneWidget);
    await tester.tap(find.byKey(const Key('claim.approve.cl1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['approve cl1']);
    expect(find.text('Ela: Odasını topladı'), findsNothing);
  });

  testWidgets('on Android the child home asks for the lock permissions until both are granted', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const KidShell(), kid: _KidApi(_home()), lock: const ChildLockStatus(supported: true, usageAccess: true)));
    await tester.pumpAndSettle();
    expect(find.text('Ekran kilidini aç'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('kid.lockSetup.usage')), matching: find.text('Aç')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('kid.lockSetup.overlay')), matching: find.text('Aç')), findsOneWidget);
  });
}
