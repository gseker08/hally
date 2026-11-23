import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

DateTime? _date(Object? v) => v is String ? DateTime.parse(v).toLocal() : null;

class Dose {
  const Dose({required this.id, required this.givenAt, this.givenByUserId, this.givenByName, this.note, this.overrodeWarning = false});

  factory Dose.fromJson(Map<String, dynamic> j) => Dose(
        id: j['id'] as String,
        givenAt: _date(j['givenAt'])!,
        givenByUserId: j['givenByUserId'] as String?,
        givenByName: j['givenByName'] as String?,
        note: j['note'] as String?,
        overrodeWarning: j['overrodeWarning'] as bool? ?? false,
      );

  final String id;
  final DateTime givenAt;
  final String? givenByUserId;
  final String? givenByName;
  final String? note;
  final bool overrodeWarning;
}

/// A child's medicine with the parents' own spacing rule. Hally never suggests doses: the parents enter the
/// interval from the doctor or the leaflet, and Hally warns when a dose would come sooner.
class Medication {
  const Medication({
    required this.id,
    required this.childId,
    required this.name,
    required this.minIntervalMinutes,
    this.dose,
    this.maxDosesPerDay,
    this.remindNextDose = true,
    this.notes,
    this.active = true,
    this.lastDose,
    this.dosesLast24h = 0,
    this.nextAllowedAt,
  });

  factory Medication.fromJson(Map<String, dynamic> j) => Medication(
        id: j['id'] as String,
        childId: j['childId'] as String,
        name: j['name'] as String,
        dose: j['dose'] as String?,
        minIntervalMinutes: j['minIntervalMinutes'] as int,
        maxDosesPerDay: j['maxDosesPerDay'] as int?,
        remindNextDose: j['remindNextDose'] as bool? ?? true,
        notes: j['notes'] as String?,
        active: j['active'] as bool? ?? true,
        lastDose: j['lastDose'] is Map ? Dose.fromJson(Map<String, dynamic>.from(j['lastDose'] as Map)) : null,
        dosesLast24h: j['dosesLast24h'] as int? ?? 0,
        nextAllowedAt: _date(j['nextAllowedAt']),
      );

  final String id;
  final String childId;
  final String name;
  final String? dose;
  final int minIntervalMinutes;
  final int? maxDosesPerDay;
  final bool remindNextDose;
  final String? notes;
  final bool active;
  final Dose? lastDose;
  final int dosesLast24h;

  /// When the next dose fits the rule; null when it may be given now.
  final DateTime? nextAllowedAt;

  bool canGiveAt(DateTime now) => nextAllowedAt == null || !nextAllowedAt!.isAfter(now);
}

/// The server refused a dose because it comes too soon (or past the daily limit). Nothing was saved.
class DoseWarning implements Exception {
  const DoseWarning({required this.code, required this.lastDose, this.nextAllowedAt});

  final String code;
  final Dose lastDose;
  final DateTime? nextAllowedAt;

  bool get isDailyLimit => code == 'medication.daily_limit';
}

class MedicationInput {
  const MedicationInput({required this.childId, required this.name, required this.minIntervalMinutes, this.dose, this.maxDosesPerDay, this.remindNextDose = true, this.notes, this.active = true});

  final String childId;
  final String name;
  final String? dose;
  final int minIntervalMinutes;
  final int? maxDosesPerDay;
  final bool remindNextDose;
  final String? notes;
  final bool active;

  Map<String, dynamic> toJson() => {
        'childId': childId,
        'name': name,
        'dose': dose,
        'minIntervalMinutes': minIntervalMinutes,
        'maxDosesPerDay': maxDosesPerDay,
        'remindNextDose': remindNextDose,
        'notes': notes,
        'active': active,
      };
}

abstract interface class MedicationsRepository {
  Future<List<Medication>> list(String familyId, {bool includeInactive = false});
  Future<Medication> create(String familyId, MedicationInput input);
  Future<Medication> update(String familyId, String id, MedicationInput input);
  Future<void> delete(String familyId, String id);
  Future<List<Dose>> doses(String familyId, String id);

  /// Throws [DoseWarning] when the dose is too soon and [force] is false.
  Future<Medication> give(String familyId, String id, {DateTime? givenAt, String? note, bool force = false});
  Future<void> deleteDose(String familyId, String id, String doseId);
}

class ApiMedicationsRepository implements MedicationsRepository {
  ApiMedicationsRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      final data = e.response?.data;
      if (e.response?.statusCode == 409 && data is Map && data['lastDose'] is Map) {
        throw DoseWarning(
          code: data['code'] as String,
          lastDose: Dose.fromJson(Map<String, dynamic>.from(data['lastDose'] as Map)),
          nextAllowedAt: _date(data['nextAllowedAt']),
        );
      }
      throw ApiClient.toApiException(e);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _base(String familyId) => '/api/v1/families/$familyId/medications';

  @override
  Future<List<Medication>> list(String familyId, {bool includeInactive = false}) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>(_base(familyId), queryParameters: includeInactive ? {'includeInactive': true} : null);
        return [for (final m in res.data!) Medication.fromJson(m as Map<String, dynamic>)];
      });

  @override
  Future<Medication> create(String familyId, MedicationInput input) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>(_base(familyId), data: input.toJson());
        return Medication.fromJson(res.data!);
      });

  @override
  Future<Medication> update(String familyId, String id, MedicationInput input) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('${_base(familyId)}/$id', data: input.toJson());
        return Medication.fromJson(res.data!);
      });

  @override
  Future<void> delete(String familyId, String id) => _call(() => _api.dio.delete<dynamic>('${_base(familyId)}/$id'));

  @override
  Future<List<Dose>> doses(String familyId, String id) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('${_base(familyId)}/$id/doses');
        return [for (final d in res.data!) Dose.fromJson(d as Map<String, dynamic>)];
      });

  @override
  Future<Medication> give(String familyId, String id, {DateTime? givenAt, String? note, bool force = false}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_base(familyId)}/$id/doses',
            data: {'givenAt': givenAt?.toUtc().toIso8601String(), 'note': note, 'force': force});
        return Medication.fromJson(res.data!);
      });

  @override
  Future<void> deleteDose(String familyId, String id, String doseId) =>
      _call(() => _api.dio.delete<dynamic>('${_base(familyId)}/$id/doses/$doseId'));
}

final medicationsRepositoryProvider = Provider<MedicationsRepository>((ref) => ApiMedicationsRepository(ref.watch(apiClientProvider)));

/// Active medications of a family. Reloads when the other parent changes something (live event), and every
/// minute while the live connection is down.
final medicationsProvider = FutureProvider.autoDispose.family<List<Medication>, String>((ref, familyId) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.medicationEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  final poll = Timer.periodic(const Duration(minutes: 1), (_) {
    if (!realtime.isConnected) ref.invalidateSelf();
  });
  ref.onDispose(() {
    live.cancel();
    poll.cancel();
  });
  return ref.watch(medicationsRepositoryProvider).list(familyId);
});

final medicationDosesProvider = FutureProvider.autoDispose.family<List<Dose>, (String, String)>(
    (ref, key) => ref.watch(medicationsRepositoryProvider).doses(key.$1, key.$2));
