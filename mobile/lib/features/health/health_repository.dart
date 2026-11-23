import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

double? _num(Object? v) => (v as num?)?.toDouble();

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const bloodTypes = ['0+', '0-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'];

class HealthProfile {
  const HealthProfile({this.bloodType, this.allergies, this.conditions, this.doctorName, this.doctorPhone, this.notes});

  factory HealthProfile.fromJson(Map<String, dynamic> j) => HealthProfile(
        bloodType: j['bloodType'] as String?,
        allergies: j['allergies'] as String?,
        conditions: j['conditions'] as String?,
        doctorName: j['doctorName'] as String?,
        doctorPhone: j['doctorPhone'] as String?,
        notes: j['notes'] as String?,
      );

  final String? bloodType;
  final String? allergies;
  final String? conditions;
  final String? doctorName;
  final String? doctorPhone;
  final String? notes;

  bool get isEmpty => [bloodType, allergies, conditions, doctorName, doctorPhone, notes].every((v) => v == null);

  Map<String, dynamic> toJson() =>
      {'bloodType': bloodType, 'allergies': allergies, 'conditions': conditions, 'doctorName': doctorName, 'doctorPhone': doctorPhone, 'notes': notes};
}

class Vaccine {
  const Vaccine({required this.id, required this.name, this.dueOn, this.givenOn, this.note, this.overdue = false});

  factory Vaccine.fromJson(Map<String, dynamic> j) => Vaccine(
        id: j['id'] as String,
        name: j['name'] as String,
        dueOn: _date(j['dueOn']),
        givenOn: _date(j['givenOn']),
        note: j['note'] as String?,
        overdue: j['overdue'] as bool? ?? false,
      );

  final String id;
  final String name;
  final DateTime? dueOn;
  final DateTime? givenOn;
  final String? note;
  final bool overdue;

  bool get given => givenOn != null;
}

class GrowthMeasurement {
  const GrowthMeasurement({required this.id, required this.measuredOn, this.heightCm, this.weightKg, this.headCm});

  factory GrowthMeasurement.fromJson(Map<String, dynamic> j) => GrowthMeasurement(
        id: j['id'] as String,
        measuredOn: DateTime.parse(j['measuredOn'] as String),
        heightCm: _num(j['heightCm']),
        weightKg: _num(j['weightKg']),
        headCm: _num(j['headCm']),
      );

  final String id;
  final DateTime measuredOn;
  final double? heightCm;
  final double? weightKg;
  final double? headCm;
}

class HealthAppointment {
  const HealthAppointment({required this.id, required this.eventId, required this.title, required this.startsAt, this.location, this.doctor, this.past = false});

  factory HealthAppointment.fromJson(Map<String, dynamic> j) => HealthAppointment(
        id: j['id'] as String,
        eventId: j['eventId'] as String,
        title: j['title'] as String,
        startsAt: DateTime.parse(j['startsAt'] as String).toLocal(),
        location: j['location'] as String?,
        doctor: j['doctor'] as String?,
        past: j['past'] as bool? ?? false,
      );

  final String id;
  final String eventId;
  final String title;
  final DateTime startsAt;
  final String? location;
  final String? doctor;
  final bool past;
}

class HealthCard {
  const HealthCard({required this.childId, this.profile = const HealthProfile(), this.vaccines = const [], this.growth = const [], this.appointments = const []});

  factory HealthCard.fromJson(Map<String, dynamic> j) => HealthCard(
        childId: j['childId'] as String,
        profile: HealthProfile.fromJson(j['profile'] as Map<String, dynamic>),
        vaccines: [for (final v in j['vaccines'] as List) Vaccine.fromJson(v as Map<String, dynamic>)],
        growth: [for (final g in j['growth'] as List) GrowthMeasurement.fromJson(g as Map<String, dynamic>)],
        appointments: [for (final a in j['appointments'] as List) HealthAppointment.fromJson(a as Map<String, dynamic>)],
      );

  final String childId;
  final HealthProfile profile;
  final List<Vaccine> vaccines;

  /// Oldest first.
  final List<GrowthMeasurement> growth;

  /// Upcoming (soonest first), then recent past ones.
  final List<HealthAppointment> appointments;
}

abstract interface class HealthRepository {
  Future<HealthCard> card(String familyId, String childId);
  Future<HealthCard> saveProfile(String familyId, String childId, HealthProfile profile);
  Future<HealthCard> addVaccine(String familyId, String childId, {required String name, DateTime? dueOn, DateTime? givenOn, String? note});
  Future<HealthCard> vaccineGiven(String familyId, String childId, String vaccineId);
  Future<HealthCard> deleteVaccine(String familyId, String childId, String vaccineId);
  Future<HealthCard> addGrowth(String familyId, String childId, {double? heightCm, double? weightKg, double? headCm, DateTime? measuredOn});
  Future<HealthCard> deleteGrowth(String familyId, String childId, String measurementId);
  Future<HealthCard> addAppointment(String familyId, String childId, {required String title, required DateTime startsAt, String? location, String? doctor, bool remind = true});
  Future<HealthCard> deleteAppointment(String familyId, String childId, String appointmentId);
}

class ApiHealthRepository implements HealthRepository {
  ApiHealthRepository(this._api);

  final ApiClient _api;

  Future<HealthCard> _card(Future<dynamic> Function() fn) async {
    try {
      return HealthCard.fromJson((await fn()).data as Map<String, dynamic>);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _u(String familyId, String childId) => '/api/v1/families/$familyId/children/$childId/health';

  @override
  Future<HealthCard> card(String familyId, String childId) => _card(() => _api.dio.get<Map<String, dynamic>>(_u(familyId, childId)));

  @override
  Future<HealthCard> saveProfile(String familyId, String childId, HealthProfile profile) =>
      _card(() => _api.dio.put<Map<String, dynamic>>('${_u(familyId, childId)}/profile', data: profile.toJson()));

  @override
  Future<HealthCard> addVaccine(String familyId, String childId, {required String name, DateTime? dueOn, DateTime? givenOn, String? note}) =>
      _card(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId, childId)}/vaccines', data: {
            'name': name,
            'dueOn': dueOn == null ? null : _day(dueOn),
            'givenOn': givenOn == null ? null : _day(givenOn),
            'note': note,
          }));

  @override
  Future<HealthCard> vaccineGiven(String familyId, String childId, String vaccineId) =>
      _card(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId, childId)}/vaccines/$vaccineId/given', data: <String, dynamic>{}));

  @override
  Future<HealthCard> deleteVaccine(String familyId, String childId, String vaccineId) =>
      _card(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId, childId)}/vaccines/$vaccineId'));

  @override
  Future<HealthCard> addGrowth(String familyId, String childId, {double? heightCm, double? weightKg, double? headCm, DateTime? measuredOn}) =>
      _card(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId, childId)}/growth', data: {
            'heightCm': heightCm,
            'weightKg': weightKg,
            'headCm': headCm,
            if (measuredOn != null) 'measuredOn': _day(measuredOn),
          }));

  @override
  Future<HealthCard> deleteGrowth(String familyId, String childId, String measurementId) =>
      _card(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId, childId)}/growth/$measurementId'));

  @override
  Future<HealthCard> addAppointment(String familyId, String childId,
          {required String title, required DateTime startsAt, String? location, String? doctor, bool remind = true}) =>
      _card(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId, childId)}/appointments', data: {
            'title': title,
            'startsAt': startsAt.toUtc().toIso8601String(),
            'location': location,
            'doctor': doctor,
            'remind': remind,
          }));

  @override
  Future<HealthCard> deleteAppointment(String familyId, String childId, String appointmentId) =>
      _card(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId, childId)}/appointments/$appointmentId'));
}

final healthRepositoryProvider = Provider<HealthRepository>((ref) => ApiHealthRepository(ref.watch(apiClientProvider)));

/// One child's health card; follows the other parent's changes live.
final healthCardProvider = FutureProvider.autoDispose.family<HealthCard, (String, String)>((ref, key) async {
  final live = ref.watch(chatRealtimeProvider).healthEvents.where((e) => e['childId'] == key.$2).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(healthRepositoryProvider).card(key.$1, key.$2);
});
