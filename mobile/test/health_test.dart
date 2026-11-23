import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/health/health_repository.dart';
import 'package:hally/features/health/health_screen.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'mint');

class _FakeHealth implements HealthRepository {
  final calls = <String>[];
  HealthProfile profile = const HealthProfile();
  final vaccines = <Vaccine>[Vaccine(id: 'v1', name: 'Hepatit A', dueOn: DateTime(2026, 11, 1), overdue: true)];
  final growth = <GrowthMeasurement>[GrowthMeasurement(id: 'g1', measuredOn: DateTime(2026, 5, 1), heightCm: 98.5, weightKg: 15.2)];
  final appointments = <HealthAppointment>[];

  HealthCard get _card => HealthCard(childId: 'c1', profile: profile, vaccines: List.of(vaccines), growth: List.of(growth), appointments: List.of(appointments));

  @override
  Future<HealthCard> card(String familyId, String childId) async => _card;

  @override
  Future<HealthCard> saveProfile(String familyId, String childId, HealthProfile p) async {
    calls.add('profile ${p.bloodType} ${p.allergies}');
    profile = p;
    return _card;
  }

  @override
  Future<HealthCard> addVaccine(String familyId, String childId, {required String name, DateTime? dueOn, DateTime? givenOn, String? note}) async {
    calls.add('vaccine $name ${givenOn != null ? 'given' : 'due'}');
    vaccines.add(Vaccine(id: 'v2', name: name, dueOn: dueOn, givenOn: givenOn));
    return _card;
  }

  @override
  Future<HealthCard> vaccineGiven(String familyId, String childId, String vaccineId) async {
    calls.add('given $vaccineId');
    final i = vaccines.indexWhere((v) => v.id == vaccineId);
    vaccines[i] = Vaccine(id: vaccineId, name: vaccines[i].name, dueOn: vaccines[i].dueOn, givenOn: DateTime(2026, 11, 23));
    return _card;
  }

  @override
  Future<HealthCard> deleteVaccine(String familyId, String childId, String vaccineId) async => _card;

  @override
  Future<HealthCard> addGrowth(String familyId, String childId, {double? heightCm, double? weightKg, double? headCm, DateTime? measuredOn}) async {
    calls.add('growth $heightCm $weightKg $headCm');
    growth.add(GrowthMeasurement(id: 'g2', measuredOn: DateTime(2026, 11, 23), heightCm: heightCm, weightKg: weightKg, headCm: headCm));
    return _card;
  }

  @override
  Future<HealthCard> deleteGrowth(String familyId, String childId, String measurementId) async => _card;

  @override
  Future<HealthCard> addAppointment(String familyId, String childId,
      {required String title, required DateTime startsAt, String? location, String? doctor, bool remind = true}) async {
    calls.add('appointment $title $doctor $remind');
    appointments.add(HealthAppointment(id: 'a1', eventId: 'e1', title: title, startsAt: startsAt, doctor: doctor));
    return _card;
  }

  @override
  Future<HealthCard> deleteAppointment(String familyId, String childId, String appointmentId) async => _card;
}

Widget _app(_FakeHealth repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        healthRepositoryProvider.overrideWithValue(repo),
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
        home: const HealthScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('parses Turkish decimals', () {
    expect(parseHealthNumber('98,5'), 98.5);
    expect(parseHealthNumber(' 15.2 '), 15.2);
    expect(parseHealthNumber(''), isNull);
  });

  testWidgets('fills in the basics and marks a vaccine as given', (tester) async {
    _phone(tester);
    final repo = _FakeHealth();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.textContaining('gecikti'), findsOneWidget);

    await tester.tap(find.byKey(const Key('health.editProfile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('health.blood.A+')));
    await tester.enterText(find.byKey(const Key('health.allergiesField')), 'Fıstık');
    await tester.tap(find.byKey(const Key('health.saveProfile')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['profile A+ Fıstık']);
    expect(find.byKey(const Key('health.allergies')), findsOneWidget);

    await tester.tap(find.byKey(const Key('health.given.v1')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'given v1');
    expect(find.textContaining('gecikti'), findsNothing);
    expect(find.textContaining('tarihinde yapıldı'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adds a measurement, a vaccine and an appointment', (tester) async {
    _phone(tester);
    final repo = _FakeHealth();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('health.addGrowth')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('health.saveGrowth')));
    await tester.pumpAndSettle();
    expect(find.text('En az bir ölçüm yazın.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('health.height')), '102,5');
    await tester.tap(find.byKey(const Key('health.saveGrowth')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['growth 102.5 null null']);
    await tester.scrollUntilVisible(find.text('102,5 cm'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('102,5 cm'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('health.addVaccine')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('health.vaccineName')), 'KKK');
    await tester.tap(find.text('Yapıldı').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('health.saveVaccine')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'vaccine KKK given');

    await tester.tap(find.byKey(const Key('health.addAppointment')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('health.appointmentTitle')), 'Diş kontrolü');
    await tester.tap(find.byKey(const Key('health.saveAppointment')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'appointment Diş kontrolü null true');
    expect(find.text('Diş kontrolü'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
