import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/caregiver_screen.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/family/invite_partner_screen.dart';
import 'package:hally/features/home/home_shell.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _Repo implements FamilyRepository {
  final calls = <String>[];

  @override
  Future<Invitation> invite(String familyId, {CaregiverAccess? caregiver}) async {
    calls.add(caregiver == null
        ? 'invite parent'
        : 'invite caregiver ${caregiver.childIds.join(',')} health=${caregiver.canSeeHealth} until=${caregiver.until != null}');
    return const Invitation(url: 'https://hally.test/i/t', shareText: 'x', whatsAppUrl: 'https://wa.me/?text=x');
  }

  @override
  Future<FamilyMember> setCaregiverAccess(String familyId, String userId, CaregiverAccess access) async {
    calls.add('access $userId health=${access.canSeeHealth} children=${access.childIds.join(',')}');
    return FamilyMember(userId: userId, displayName: 'Zeynep', role: 'Caregiver', canSeeHealth: access.canSeeHealth);
  }

  @override
  Future<ChildProfile> addChild(String familyId, {required String firstName, int? birthYear, String? color}) async {
    calls.add('addChild $firstName $birthYear $color');
    return ChildProfile(id: 'c9', firstName: firstName, birthYear: birthYear, color: color ?? 'sky');
  }

  @override
  Future<void> removeCaregiver(String familyId, String userId) async => calls.add('remove $userId');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _family = FamilyDetails(
  id: 'f1',
  name: 'Yılmaz',
  timeZoneId: 'Europe/Istanbul',
  members: [
    FamilyMember(userId: 'u1', displayName: 'Ayşe', role: 'Owner'),
    FamilyMember(userId: 'u3', displayName: 'Zeynep', role: 'Caregiver', childIds: ['c1'], canSeeHealth: false),
  ],
  children: [ChildProfile(id: 'c1', firstName: 'Ela'), ChildProfile(id: 'c2', firstName: 'Deniz')],
);

/// The invite screen inside a router, so "Kod al" can open the child's phone page.
Widget _routed(_Repo repo) => _app(
      repo,
      null,
      router: GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const InvitePartnerScreen(familyId: 'f1')),
        GoRoute(path: '/family/:id/child/:childId/phone', builder: (_, s) => Text('phone ${s.pathParameters['childId']}')),
      ]),
    );

Widget _app(_Repo repo, Widget? home, {String role = 'Owner', GoRouter? router}) => ProviderScope(
      overrides: [
        familyRepositoryProvider.overrideWithValue(repo),
        familyProvider.overrideWith((ref, id) async => _family),
        meProvider.overrideWith((ref) async =>
            Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz', role: role)])),
      ],
      child: router != null
          ? MaterialApp.router(
              theme: buildHallyTheme(Brightness.light),
              locale: const Locale('tr'),
              localizationsDelegates: _delegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            )
          : MaterialApp(
              theme: buildHallyTheme(Brightness.light),
              locale: const Locale('tr'),
              localizationsDelegates: _delegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: home,
            ),
    );

const _delegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('inviting a caregiver sends children, end date and health permission', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(repo, const InvitePartnerScreen(familyId: 'f1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite.role.caregiver')));
    await tester.pumpAndSettle();
    // The child card sits between the role cards and the caregiver choices, so scroll down to them.
    await tester.scrollUntilVisible(find.byKey(const Key('invite.child.c2')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Hangi çocuklara bakacak?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('invite.child.c2'))); // Deniz off: only Ela
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('invite.health')), 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sağlık bilgisini görebilsin'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('invite.copy')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('invite.copy')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['invite caregiver c1 health=true until=true']);

  });

  testWidgets('adding a child picks an existing child and opens its phone code', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_routed(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite.role.child')));
    await tester.pumpAndSettle();
    expect(find.text('Hangi çocuk?'), findsOneWidget);
    expect(find.byKey(const Key('invite.whatsapp')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('invite.kid.c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('invite.kid.c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('invite.childCode')));
    await tester.pumpAndSettle();
    expect(find.text('phone c2'), findsOneWidget);
    expect(repo.calls, isEmpty);
  });

  testWidgets('adding a new child creates the profile first, with a free colour', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_routed(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite.role.child')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('invite.kid.new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('invite.kid.new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('invite.childCode')));
    await tester.pumpAndSettle();
    expect(find.text('Çocuğun adını yaz'), findsOneWidget);
    expect(repo.calls, isEmpty);

    await tester.scrollUntilVisible(find.byKey(const Key('invite.kid.year')), 100,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invite.kid.name')), 'Can');
    await tester.enterText(find.byKey(const Key('invite.kid.year')), '2016');
    await tester.tap(find.byKey(const Key('invite.childCode')));
    await tester.pumpAndSettle();
    // Ela and Deniz are both sky (the default), so the next free colour is mint.
    expect(repo.calls, ['addChild Can 2016 mint']);
    expect(find.text('phone c9'), findsOneWidget);
  });

  testWidgets('a parent opens health for a caregiver and can remove them', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(repo, const CaregiverScreen(familyId: 'f1', userId: 'u3')));
    await tester.pumpAndSettle();

    expect(find.text('Yapabilir'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('caregiver.health')), 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sağlık bilgisini görebilsin'));
    await tester.pumpAndSettle();
    expect(repo.calls, ['access u3 health=true children=c1']);

    await tester.scrollUntilVisible(find.byKey(const Key('caregiver.remove')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('caregiver.remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('caregiver.remove.confirm')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'remove u3');
  });

  testWidgets('a caregiver has no Add button and Messages instead of Family', (tester) async {
    _phone(tester);
    Widget bar(bool caregiver) => _app(
          _Repo(),
          Consumer(
            builder: (context, ref, _) => Scaffold(
              bottomNavigationBar: HallyNavBar(
                currentIndex: 0,
                items: const [
                  HallyNavItem(icon: Icons.wb_sunny_outlined, activeIcon: Icons.wb_sunny, label: 'Bugün'),
                  HallyNavItem(icon: Icons.forum_outlined, activeIcon: Icons.forum, label: 'Mesajlar'),
                ],
                centerLabel: caregiver ? null : 'Ekle',
                onTap: (_) {},
                onCenterTap: () {},
              ),
            ),
          ),
        );
    await tester.pumpWidget(bar(true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab.capture')), findsNothing);
    await tester.pumpWidget(bar(false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab.capture')), findsOneWidget);
  });
}
