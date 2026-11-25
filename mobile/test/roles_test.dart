import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

Widget _app(_Repo repo, Widget home, {String role = 'Owner'}) => ProviderScope(
      overrides: [
        familyRepositoryProvider.overrideWithValue(repo),
        familyProvider.overrideWith((ref, id) async => _family),
        meProvider.overrideWith((ref) async =>
            Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz', role: role)])),
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
  testWidgets('inviting a caregiver sends children, end date and health permission', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(repo, const InvitePartnerScreen(familyId: 'f1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite.role.caregiver')));
    await tester.pumpAndSettle();
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
