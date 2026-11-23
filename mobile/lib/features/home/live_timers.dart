import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../family/family_repository.dart';
import '../screen_time/screen_time_repository.dart';
import '../sleep/sleep_repository.dart';
import '../study/study_repository.dart';
import '../../l10n/gen/app_localizations.dart';

/// A timer that runs on the server right now: screen time, homework/reading or sleep. Shown outside the app,
/// on the lock screen and status bar (for timers this user started) and in the home screen "Şu an" widget.
class LiveTimer {
  const LiveTimer({
    required this.type,
    required this.familyId,
    required this.childId,
    required this.title,
    required this.body,
    required this.emoji,
    required this.countingSince,
    this.until,
    this.startedByUserId,
  });

  /// `screen`, `study` or `sleep`; also the notification target type, so Durdur knows which timer to stop.
  final String type;
  final String familyId;
  final String childId;
  final String title;
  final String body;
  final String emoji;

  /// The clock counts up from here. For screen time and homework/reading that is today's total, for sleep this
  /// stretch of sleep.
  final DateTime countingSince;

  /// The server's cap for a forgotten timer; outside the app the timer disappears by itself then.
  final DateTime? until;
  final String? startedByUserId;

  String get key => '$type:$childId';

  Map<String, Object?> toJson() => {
        'type': type,
        'familyId': familyId,
        'childId': childId,
        'title': title,
        'body': body,
        'emoji': emoji,
        'since': countingSince.millisecondsSinceEpoch,
        'until': until?.millisecondsSinceEpoch,
      };
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Every running timer of the family, ordered screen time, homework/reading, sleep, then by child name.
List<LiveTimer> liveTimers({
  required String familyId,
  required Map<String, ChildScreenTime> screen,
  required Map<String, ChildStudyStatus> study,
  required Map<String, ChildSleepStatus> sleep,
  required Map<String, String> childNames,
  required AppLocalizations l10n,
  required DateTime now,
}) {
  String name(String id) => childNames[id] ?? '';
  final byName = [...childNames.keys]..sort((a, b) => name(a).compareTo(name(b)));
  // Server times only compared with server times; the local clock only anchors "since".
  DateTime? cap(DateTime? until, DateTime? asOf) => until != null && asOf != null ? now.add(until.difference(asOf)) : null;

  return [
    for (final id in byName)
      if (screen[id] case final s? when s.isRunning)
        LiveTimer(
          type: 'screen',
          familyId: familyId,
          childId: id,
          title: l10n.screenNoticeTitle(name(id)),
          body: s.dailyGoalMinutes == null ? l10n.screenNoticeBody : l10n.screenNoticeGoal(s.dailyGoalMinutes!),
          emoji: '📱',
          countingSince: now.subtract(Duration(seconds: s.secondsAt(now))),
          until: cap(s.runningUntil, s.asOf),
          startedByUserId: s.startedByUserId,
        ),
    for (final id in byName)
      if (study[id] case final s? when s.isRunning)
        LiveTimer(
          type: 'study',
          familyId: familyId,
          childId: id,
          title: s.runningKind == 'Reading' ? l10n.liveTimerReading(name(id)) : l10n.liveTimerHomework(name(id)),
          body: s.dailyGoalMinutes == null ? l10n.liveTimerToday : l10n.screenNoticeGoal(s.dailyGoalMinutes!),
          emoji: s.runningKind == 'Reading' ? '📖' : '✏️',
          countingSince: now.subtract(Duration(seconds: s.secondsAt(now))),
          until: s.runningUntil?.toLocal(),
          startedByUserId: s.startedByUserId,
        ),
    for (final id in byName)
      if (sleep[id]?.asleep case final e?)
        LiveTimer(
          type: 'sleep',
          familyId: familyId,
          childId: id,
          title: l10n.liveTimerSleep(name(id)),
          body: l10n.liveTimerSleepSince(_clock(e.startedAt.toLocal())),
          emoji: '🌙',
          countingSince: e.startedAt.toLocal(),
          startedByUserId: e.startedByUserId,
        ),
  ];
}

/// The family's running timers, kept live (the three sources follow the other parent's taps over the hub).
/// Null until all three have loaded, so nothing is removed from the tray or the widget by a half-loaded list.
final liveTimersProvider = Provider.autoDispose.family<List<LiveTimer>?, ({String familyId, String language})>((ref, arg) {
  final screen = ref.watch(screenTimeProvider(arg.familyId)).valueOrNull;
  final study = ref.watch(studyStatusProvider(arg.familyId)).valueOrNull;
  final sleep = ref.watch(sleepStatusProvider(arg.familyId)).valueOrNull;
  final children = ref.watch(familyProvider(arg.familyId)).valueOrNull?.children;
  if (screen == null || study == null || sleep == null || children == null) return null;
  return liveTimers(
    familyId: arg.familyId,
    screen: screen,
    study: study,
    sleep: sleep,
    childNames: {for (final c in children) c.id: c.firstName},
    l10n: lookupAppLocalizations(Locale(arg.language)),
    now: DateTime.now(),
  );
});
