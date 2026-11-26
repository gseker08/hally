import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The study-reminder choices (days before the exam).
const examStudyDayChoices = [1, 2, 3, 7];

/// A child's exam (Sınav takvimi). [outcome], [score] and [cherries] are only filled for parents.
class Exam {
  const Exam({
    required this.id,
    required this.childId,
    required this.childName,
    required this.subject,
    required this.date,
    this.topics,
    this.slot,
    this.studyDaysBefore,
    this.eventId,
    this.daysLeft = 0,
    this.studySeconds = 0,
    this.outcome,
    this.score,
    this.cherries = 0,
    this.studyDay = false,
  });

  factory Exam.fromJson(Map<String, dynamic> j) => Exam(
        id: j['id'] as String,
        childId: j['childId'] as String,
        childName: j['childName'] as String? ?? '',
        subject: j['subject'] as String,
        topics: j['topics'] as String?,
        date: DateTime.parse(j['date'] as String),
        slot: j['slot'] as String?,
        studyDaysBefore: j['studyDaysBefore'] as int?,
        eventId: j['eventId'] as String?,
        daysLeft: j['daysLeft'] as int? ?? 0,
        studySeconds: j['studySeconds'] as int? ?? 0,
        outcome: j['outcome'] as String?,
        score: j['score'] as int?,
        cherries: j['cherries'] as int? ?? 0,
        studyDay: j['studyDay'] as bool? ?? false,
      );

  final String id;
  final String childId;
  final String childName;
  final String subject;
  final String? topics;

  /// The exam day (date only).
  final DateTime date;

  /// "2. ders", "10:30".
  final String? slot;
  final int? studyDaysBefore;
  final String? eventId;

  /// Days from today in the family's zone; negative once it is past.
  final int daysLeft;
  final int studySeconds;

  /// Hard, Good or Great.
  final String? outcome;
  final int? score;
  final int cherries;

  /// Today is one of the study evenings before it.
  final bool studyDay;

  bool get upcoming => daysLeft >= 0;
  bool get hasResult => outcome != null;

  /// Past and nobody noted how it went yet.
  bool get awaitingResult => daysLeft < 0 && !hasResult;

  /// Whether [day] is one of the study evenings (from [studyDaysBefore] days before up to the day before).
  bool isStudyDay(DateTime day) {
    final n = studyDaysBefore;
    if (n == null) return false;
    final d = DateTime(day.year, day.month, day.day);
    final exam = DateTime(date.year, date.month, date.day);
    final diff = exam.difference(d).inDays;
    return diff >= 1 && diff <= n;
  }
}

/// What the app sends to add or change an exam.
class ExamDraft {
  const ExamDraft({required this.childId, required this.subject, required this.date, this.topics, this.slot, this.studyDaysBefore = 3});

  final String childId;
  final String subject;
  final DateTime date;
  final String? topics;
  final String? slot;
  final int? studyDaysBefore;

  Map<String, dynamic> toJson() => {
        'childId': childId,
        'subject': subject,
        'date': _day(date),
        'topics': topics,
        'slot': slot,
        'studyDaysBefore': studyDaysBefore,
      };
}

/// On the child's own phone: an exam in the next two weeks.
class ChildExam {
  const ChildExam({required this.id, required this.subject, required this.date, this.topics, this.slot, this.daysLeft = 0, this.studySeconds = 0, this.state = 'Todo'});

  factory ChildExam.fromJson(Map<String, dynamic> j) => ChildExam(
        id: j['id'] as String,
        subject: j['subject'] as String,
        topics: j['topics'] as String?,
        date: DateTime.parse(j['date'] as String),
        slot: j['slot'] as String?,
        daysLeft: j['daysLeft'] as int? ?? 0,
        studySeconds: j['studySeconds'] as int? ?? 0,
        state: j['state'] as String? ?? 'Todo',
      );

  final String id;
  final String subject;
  final String? topics;
  final DateTime date;
  final String? slot;
  final int daysLeft;
  final int studySeconds;

  /// "Çalıştım" today: Todo, Pending or Done.
  final String state;
}

abstract interface class ExamsRepository {
  Future<List<Exam>> list(String familyId, {String? childId});
  Future<Exam> get(String familyId, String examId);
  Future<Exam> create(String familyId, ExamDraft draft);
  Future<Exam> update(String familyId, String examId, ExamDraft draft);
  Future<void> delete(String familyId, String examId);
  Future<Exam> result(String familyId, String examId, {required String outcome, int? score, int cherries = 0});

  /// Starts the child's homework timer for this exam (its minutes add up on the exam).
  Future<void> startStudy(String familyId, String childId, String examId);
}

class ApiExamsRepository implements ExamsRepository {
  ApiExamsRepository(this._api);

  final ApiClient _api;

  String _base(String familyId) => '/api/v1/families/$familyId/exams';

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<List<Exam>> list(String familyId, {String? childId}) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>(_base(familyId), queryParameters: {if (childId != null) 'child': childId});
        return [for (final e in res.data!) Exam.fromJson(e as Map<String, dynamic>)];
      });

  @override
  Future<Exam> get(String familyId, String examId) =>
      _call(() async => Exam.fromJson((await _api.dio.get<Map<String, dynamic>>('${_base(familyId)}/$examId')).data!));

  @override
  Future<Exam> create(String familyId, ExamDraft draft) =>
      _call(() async => Exam.fromJson((await _api.dio.post<Map<String, dynamic>>(_base(familyId), data: draft.toJson())).data!));

  @override
  Future<Exam> update(String familyId, String examId, ExamDraft draft) =>
      _call(() async => Exam.fromJson((await _api.dio.put<Map<String, dynamic>>('${_base(familyId)}/$examId', data: draft.toJson())).data!));

  @override
  Future<void> delete(String familyId, String examId) => _call(() => _api.dio.delete<dynamic>('${_base(familyId)}/$examId'));

  @override
  Future<Exam> result(String familyId, String examId, {required String outcome, int? score, int cherries = 0}) => _call(() async => Exam.fromJson(
      (await _api.dio.put<Map<String, dynamic>>('${_base(familyId)}/$examId/result', data: {'outcome': outcome, 'score': score, 'cherries': cherries})).data!));

  @override
  Future<void> startStudy(String familyId, String childId, String examId) => _call(() =>
      _api.dio.post<dynamic>('/api/v1/families/$familyId/children/$childId/study/start', data: {'kind': 'Homework', 'examId': examId}));
}

final examsRepositoryProvider = Provider<ExamsRepository>((ref) => ApiExamsRepository(ref.watch(apiClientProvider)));

/// The family's exams (upcoming and the last two months). Reloads when study time changes (it adds up on exams).
final examsProvider = FutureProvider.autoDispose.family<List<Exam>, String>((ref, familyId) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.studyEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(examsRepositoryProvider).list(familyId);
});

/// Whether the calendar day has "Çalışma zamanı" rows (so the day is not shown as empty).
final hasStudyRowsProvider = Provider.autoDispose.family<bool, (String, DateTime, String?)>((ref, key) {
  final exams = ref.watch(examsProvider(key.$1)).valueOrNull ?? const <Exam>[];
  return exams.any((e) => e.isStudyDay(key.$2) && (key.$3 == null || e.childId == key.$3));
});
