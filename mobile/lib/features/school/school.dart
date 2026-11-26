import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

DateTime _date(String s) => DateTime.parse(s);
String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
List<String> _strings(Object? list) => [for (final s in list as List? ?? const []) s as String];

/// The family's school settings: bell times for every child, items every school day needs, the evening note.
class SchoolSettings {
  const SchoolSettings(
      {this.bellTimes = const [], this.dailyItems = const [], this.reminderTime = '19:30', this.childPhone = true, this.quietOnHolidays = true});

  factory SchoolSettings.fromJson(Map<String, dynamic> j) => SchoolSettings(
        bellTimes: _strings(j['bellTimes']),
        dailyItems: _strings(j['dailyItems']),
        reminderTime: j['reminderTime'] as String?,
        childPhone: j['childPhone'] as bool? ?? true,
        quietOnHolidays: j['quietOnHolidays'] as bool? ?? true,
      );

  /// "08:30", one per period.
  final List<String> bellTimes;
  final List<String> dailyItems;

  /// "19:30"; null when the evening note is off.
  final String? reminderTime;
  final bool childPhone;
  final bool quietOnHolidays;

  SchoolSettings copyWith({List<String>? bellTimes, List<String>? dailyItems, String? Function()? reminderTime, bool? childPhone, bool? quietOnHolidays}) =>
      SchoolSettings(
        bellTimes: bellTimes ?? this.bellTimes,
        dailyItems: dailyItems ?? this.dailyItems,
        reminderTime: reminderTime == null ? this.reminderTime : reminderTime(),
        childPhone: childPhone ?? this.childPhone,
        quietOnHolidays: quietOnHolidays ?? this.quietOnHolidays,
      );

  Map<String, dynamic> toJson() => {
        'bellTimes': bellTimes,
        'dailyItems': dailyItems,
        'reminderTime': reminderTime,
        'childPhone': childPhone,
        'quietOnHolidays': quietOnHolidays,
      };
}

/// "Ara tatil", 16–20 Kasım.
class SchoolBreak {
  const SchoolBreak({required this.id, required this.title, required this.from, required this.to});

  factory SchoolBreak.fromJson(Map<String, dynamic> j) =>
      SchoolBreak(id: j['id'] as String, title: j['title'] as String, from: _date(j['from'] as String), to: _date(j['to'] as String));

  final String id;
  final String title;
  final DateTime from;
  final DateTime to;
}

/// One period of a child's week. [weekday] is 1 (Monday) to 5 (Friday).
class Lesson {
  const Lesson({required this.id, required this.childId, required this.weekday, required this.period, required this.subject, this.items = const []});

  factory Lesson.fromJson(Map<String, dynamic> j) => Lesson(
        id: j['id'] as String,
        childId: j['childId'] as String,
        weekday: j['weekday'] as int,
        period: j['period'] as int,
        subject: j['subject'] as String,
        items: _strings(j['items']),
      );

  final String id;
  final String childId;
  final int weekday;
  final int period;
  final String subject;
  final List<String> items;
}

/// One line of the bag: an item to pack ("👟 Eşofman" for Beden Eğitimi) or an exam to study for.
class BagItem {
  const BagItem({required this.key, required this.kind, required this.text, this.subjects = const [], this.examDate, this.packed = false});

  factory BagItem.fromJson(Map<String, dynamic> j) => BagItem(
        key: j['key'] as String,
        kind: j['kind'] as String? ?? 'Item',
        text: j['text'] as String,
        subjects: _strings(j['subjects']),
        examDate: j['examDate'] == null ? null : _date(j['examDate'] as String),
        packed: j['packed'] as bool? ?? false,
      );

  final String key;

  /// Item or Exam.
  final String kind;
  final String text;

  /// The lessons that need it; empty for every-day items.
  final List<String> subjects;
  final DateTime? examDate;
  final bool packed;

  bool get isExam => kind == 'Exam';
}

/// Tomorrow's school bag for one child.
class Bag {
  const Bag(
      {required this.childId,
      required this.childName,
      required this.day,
      this.subjects = const [],
      this.items = const [],
      this.readyAt,
      this.readyByChild = false,
      this.childClaim});

  factory Bag.fromJson(Map<String, dynamic> j) => Bag(
        childId: j['childId'] as String,
        childName: j['childName'] as String? ?? '',
        day: _date(j['day'] as String),
        subjects: _strings(j['subjects']),
        items: [for (final i in j['items'] as List? ?? const []) BagItem.fromJson(i as Map<String, dynamic>)],
        readyAt: j['readyAt'] == null ? null : DateTime.parse(j['readyAt'] as String),
        readyByChild: j['readyByChild'] as bool? ?? false,
        childClaim: j['childClaim'] as String?,
      );

  final String childId;
  final String childName;
  final DateTime day;
  final List<String> subjects;
  final List<BagItem> items;
  final DateTime? readyAt;
  final bool readyByChild;

  /// The child's "Çantam hazır" today: null, Pending or Done.
  final String? childClaim;

  bool get ready => readyAt != null;
  int get packedCount => items.where((i) => i.packed).length;
}

class SchoolState {
  const SchoolState(
      {required this.today,
      this.todayIsSchoolDay = true,
      this.settings = const SchoolSettings(),
      this.breaks = const [],
      this.lessons = const [],
      this.bags = const []});

  factory SchoolState.fromJson(Map<String, dynamic> j) => SchoolState(
        today: _date(j['today'] as String),
        todayIsSchoolDay: j['todayIsSchoolDay'] as bool? ?? true,
        settings: SchoolSettings.fromJson(j['settings'] as Map<String, dynamic>? ?? const {}),
        breaks: [for (final b in j['breaks'] as List? ?? const []) SchoolBreak.fromJson(b as Map<String, dynamic>)],
        lessons: [for (final l in j['lessons'] as List? ?? const []) Lesson.fromJson(l as Map<String, dynamic>)],
        bags: [for (final b in j['bags'] as List? ?? const []) Bag.fromJson(b as Map<String, dynamic>)],
      );

  final DateTime today;
  final bool todayIsSchoolDay;
  final SchoolSettings settings;
  final List<SchoolBreak> breaks;
  final List<Lesson> lessons;
  final List<Bag> bags;

  List<Lesson> lessonsOf(String childId) => lessons.where((l) => l.childId == childId).toList();

  Lesson? lessonAt(String childId, int weekday, int period) {
    for (final l in lessons) {
      if (l.childId == childId && l.weekday == weekday && l.period == period) return l;
    }
    return null;
  }

  Bag? bagOf(String childId) => bags.where((b) => b.childId == childId).firstOrNull;

  /// Rows in the grid: the bell times, or more when lessons go further.
  int periodsOf(String childId) {
    var n = settings.bellTimes.length;
    for (final l in lessonsOf(childId)) {
      if (l.period > n) n = l.period;
    }
    return n < 1 ? 1 : n;
  }
}

/// On the child's phone: one of today's lessons.
class ChildLesson {
  const ChildLesson({required this.period, required this.subject, this.start, this.items = const [], this.now = false});

  factory ChildLesson.fromJson(Map<String, dynamic> j) => ChildLesson(
        period: j['period'] as int,
        start: j['start'] as String?,
        subject: j['subject'] as String,
        items: _strings(j['items']),
        now: j['now'] as bool? ?? false,
      );

  final int period;
  final String? start;
  final String subject;
  final List<String> items;

  /// Going on right now.
  final bool now;
}

/// On the child's phone: today's lessons and, when the parents allow it, tomorrow's bag.
class ChildSchool {
  const ChildSchool({this.today = const [], this.bag});

  factory ChildSchool.fromJson(Map<String, dynamic> j) => ChildSchool(
        today: [for (final l in j['today'] as List? ?? const []) ChildLesson.fromJson(l as Map<String, dynamic>)],
        bag: j['bag'] == null ? null : Bag.fromJson(j['bag'] as Map<String, dynamic>),
      );

  final List<ChildLesson> today;
  final Bag? bag;
}

abstract interface class SchoolRepository {
  Future<SchoolState> get(String familyId);
  Future<SchoolState> saveSettings(String familyId, SchoolSettings settings);
  Future<SchoolState> addBreak(String familyId, String title, DateTime from, DateTime to);
  Future<SchoolState> deleteBreak(String familyId, String breakId);

  /// Sets one period; an empty [subject] clears it.
  Future<SchoolState> setLesson(String familyId,
      {required String childId, required int weekday, required int period, String? subject, List<String> items = const []});
  Future<SchoolState> copy(String familyId, {required String fromChildId, required String toChildId});
  Future<SchoolState> pack(String familyId, String childId, String key, bool packed);

  /// "Hazırladık".
  Future<SchoolState> ready(String familyId, String childId);
}

class ApiSchoolRepository implements SchoolRepository {
  ApiSchoolRepository(this._api);

  final ApiClient _api;

  String _base(String familyId) => '/api/v1/families/$familyId/school';

  Future<SchoolState> _call(Future<Response<Map<String, dynamic>>> Function() fn) async {
    try {
      return SchoolState.fromJson((await fn()).data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<SchoolState> get(String familyId) => _call(() => _api.dio.get<Map<String, dynamic>>(_base(familyId)));

  @override
  Future<SchoolState> saveSettings(String familyId, SchoolSettings settings) =>
      _call(() => _api.dio.put<Map<String, dynamic>>('${_base(familyId)}/settings', data: settings.toJson()));

  @override
  Future<SchoolState> addBreak(String familyId, String title, DateTime from, DateTime to) =>
      _call(() => _api.dio.post<Map<String, dynamic>>('${_base(familyId)}/breaks', data: {'title': title, 'from': _day(from), 'to': _day(to)}));

  @override
  Future<SchoolState> deleteBreak(String familyId, String breakId) => _call(() => _api.dio.delete<Map<String, dynamic>>('${_base(familyId)}/breaks/$breakId'));

  @override
  Future<SchoolState> setLesson(String familyId,
          {required String childId, required int weekday, required int period, String? subject, List<String> items = const []}) =>
      _call(() => _api.dio.put<Map<String, dynamic>>('${_base(familyId)}/lessons',
          data: {'childId': childId, 'weekday': weekday, 'period': period, 'subject': subject ?? '', 'items': items}));

  @override
  Future<SchoolState> copy(String familyId, {required String fromChildId, required String toChildId}) =>
      _call(() => _api.dio.post<Map<String, dynamic>>('${_base(familyId)}/children/$toChildId/copy-from/$fromChildId'));

  @override
  Future<SchoolState> pack(String familyId, String childId, String key, bool packed) =>
      _call(() => _api.dio.put<Map<String, dynamic>>('${_base(familyId)}/bags/$childId/items', data: {'key': key, 'packed': packed}));

  @override
  Future<SchoolState> ready(String familyId, String childId) => _call(() => _api.dio.post<Map<String, dynamic>>('${_base(familyId)}/bags/$childId/ready'));
}

final schoolRepositoryProvider = Provider<SchoolRepository>((ref) => ApiSchoolRepository(ref.watch(apiClientProvider)));

/// The family's timetables, settings and tomorrow's bags. Screens write the server's answer back with [SchoolNotifier.set].
final schoolProvider = AsyncNotifierProvider.autoDispose.family<SchoolNotifier, SchoolState, String>(SchoolNotifier.new);

class SchoolNotifier extends AutoDisposeFamilyAsyncNotifier<SchoolState, String> {
  @override
  Future<SchoolState> build(String familyId) => ref.watch(schoolRepositoryProvider).get(familyId);

  /// Runs a change and shows its result; errors are rethrown for the caller's snack bar.
  Future<SchoolState> run(Future<SchoolState> Function(SchoolRepository repo) change) async {
    final next = await change(ref.read(schoolRepositoryProvider));
    state = AsyncData(next);
    return next;
  }
}

/// Subject → colour in the grid (the same subject always looks the same).
const subjectPalette = ['mist', 'lavender', 'sage', 'peach', 'butter', 'powder'];

String subjectColorKey(String subject) {
  final s = subject.toLowerCase();
  if (s.startsWith('mat')) return 'mist';
  if (s.startsWith('tür') || s.startsWith('tur') || s.startsWith('eng')) return 'lavender';
  if (s.startsWith('fen') || s.startsWith('sci')) return 'sage';
  if (s.startsWith('hayat') || s.startsWith('sos')) return 'peach';
  if (s.startsWith('ing') || s.startsWith('lang')) return 'butter';
  if (s.startsWith('beden') || s.startsWith('pe') || s.startsWith('müz') || s.startsWith('mus')) return 'powder';
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return subjectPalette[h % subjectPalette.length];
}

/// "👟 Eşofman" → "👟"; a plain word gives null.
String? itemEmoji(String item) {
  final first = item.runes.isEmpty ? 0 : item.runes.first;
  if (first < 0x2190) return null;
  final space = item.indexOf(' ');
  return space > 0 ? item.substring(0, space) : String.fromCharCode(first);
}
