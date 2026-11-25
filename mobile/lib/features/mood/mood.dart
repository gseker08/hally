import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../insights/insights_repository.dart' show insightsDay;

/// The six answers, in the order the child sees them.
const moodValues = ['Great', 'Good', 'Okay', 'Sad', 'Angry', 'Tired'];
const moodReasons = ['Friends', 'School', 'Home', 'Play'];

String moodEmoji(String mood) => switch (mood) {
      'Great' => '😄',
      'Good' => '🙂',
      'Okay' => '😐',
      'Sad' => '😢',
      'Angry' => '😠',
      'Tired' => '😴',
      _ => '·',
    };

String moodLabel(AppLocalizations l10n, String mood) => switch (mood) {
      'Great' => l10n.moodGreat,
      'Good' => l10n.moodGood,
      'Okay' => l10n.moodOkay,
      'Sad' => l10n.moodSad,
      'Angry' => l10n.moodAngry,
      'Tired' => l10n.moodTired,
      _ => mood,
    };

String reasonEmoji(String reason) => switch (reason) { 'Friends' => '👫', 'School' => '🏫', 'Home' => '🏠', 'Play' => '⚽', _ => '' };

String reasonLabel(AppLocalizations l10n, String reason) => switch (reason) {
      'Friends' => l10n.moodFriends,
      'School' => l10n.moodSchool,
      'Home' => l10n.moodHome,
      'Play' => l10n.moodPlay,
      _ => reason,
    };

/// For the trend line: 4 is the best, 1 the hardest.
int moodScore(String mood) => switch (mood) { 'Great' => 4, 'Good' => 3, 'Okay' || 'Tired' => 2, _ => 1 };

bool moodIsHard(String mood) => mood == 'Sad' || mood == 'Angry';

class MoodDay {
  const MoodDay({required this.date, this.mood, this.reasons = const []});

  factory MoodDay.fromJson(Map<String, dynamic> j) =>
      MoodDay(date: DateTime.parse(j['date'] as String), mood: j['mood'] as String?, reasons: [for (final r in j['reasons'] as List? ?? const []) r as String]);

  final DateTime date;
  final String? mood;
  final List<String> reasons;
}

class MoodNudge {
  const MoodNudge({required this.date, required this.mood, this.reason});

  final DateTime date;
  final String mood;
  final String? reason;
}

class MoodWeek {
  const MoodWeek({required this.today, required this.days, this.mostCommon, this.mostCommonDays = 0, this.topReason, this.nudge});

  factory MoodWeek.fromJson(Map<String, dynamic> j) {
    final n = j['nudge'] as Map<String, dynamic>?;
    return MoodWeek(
      today: DateTime.parse(j['today'] as String),
      days: [for (final d in j['days'] as List) MoodDay.fromJson(d as Map<String, dynamic>)],
      mostCommon: j['mostCommon'] as String?,
      mostCommonDays: (j['mostCommonDays'] as num?)?.toInt() ?? 0,
      topReason: j['topReason'] as String?,
      nudge: n == null ? null : MoodNudge(date: DateTime.parse(n['date'] as String), mood: n['mood'] as String, reason: n['reason'] as String?),
    );
  }

  final DateTime today;
  final List<MoodDay> days;
  final String? mostCommon;
  final int mostCommonDays;
  final String? topReason;
  final MoodNudge? nudge;

  bool get isEmpty => days.every((d) => d.mood == null);
}

abstract interface class MoodRepository {
  Future<MoodWeek> moods(String familyId, String childId, {required DateTime from, required DateTime to});
}

class ApiMoodRepository implements MoodRepository {
  ApiMoodRepository(this._api);

  final ApiClient _api;

  @override
  Future<MoodWeek> moods(String familyId, String childId, {required DateTime from, required DateTime to}) async {
    try {
      final res = await _api.dio
          .get<Map<String, dynamic>>('/api/v1/families/$familyId/children/$childId/moods', queryParameters: {'from': insightsDay(from), 'to': insightsDay(to)});
      return MoodWeek.fromJson(res.data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }
}

final moodRepositoryProvider = Provider<MoodRepository>((ref) => ApiMoodRepository(ref.watch(apiClientProvider)));

/// (familyId, childId, days) — 7 or 28 days ending today.
final childMoodsProvider = FutureProvider.autoDispose.family<MoodWeek, (String, String, int)>((ref, key) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return ref.watch(moodRepositoryProvider).moods(key.$1, key.$2, from: today.subtract(Duration(days: key.$3 - 1)), to: today);
});

/// The child tapped "Sonra" today; the card comes back tomorrow (or after the app restarts).
final moodSkippedProvider = StateProvider<bool>((ref) => false);
