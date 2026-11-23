import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';
import '../planning/planning_repository.dart';

/// One row of the home screen "Today" widget (Android and iPhone).
class TodayWidgetEntry {
  const TodayWidgetEntry({required this.title, required this.kind, this.at, this.allDay = false});

  final String title;

  /// `event` or `task`.
  final String kind;

  /// Start (event) or due time (task); null for all-day events and tasks without a time.
  final DateTime? at;
  final bool allDay;

  Map<String, Object?> toJson() => {'title': title, 'kind': kind, 'at': at?.millisecondsSinceEpoch, 'allDay': allDay};
}

/// How long a started event stays on the widget ("now"), so it does not vanish the minute it begins.
const todayWidgetGrace = Duration(minutes: 15);

/// Today's events and tasks for the widget: timed ones by time, then all-day events, then tasks without a time.
/// Overdue tasks stay in the app; the widget is about what is still ahead today. Items that already passed are
/// left out here, and the widget itself hides the rest as the day goes on.
List<TodayWidgetEntry> todayWidgetEntries(TodayData d, DateTime now) {
  final timed = <TodayWidgetEntry>[];
  final allDayEvents = <TodayWidgetEntry>[];
  final untimedTasks = <TodayWidgetEntry>[];
  for (final e in d.events) {
    if (e.allDay) {
      allDayEvents.add(TodayWidgetEntry(title: e.title, kind: 'event', allDay: true));
    } else if (e.startsAt.add(todayWidgetGrace).isAfter(now)) {
      timed.add(TodayWidgetEntry(title: e.title, kind: 'event', at: e.startsAt));
    }
  }
  for (final t in d.dueToday) {
    final due = t.dueAt;
    if (t.allDay || due == null) {
      untimedTasks.add(TodayWidgetEntry(title: t.title, kind: 'task'));
    } else if (due.add(todayWidgetGrace).isAfter(now)) {
      timed.add(TodayWidgetEntry(title: t.title, kind: 'task', at: due));
    }
  }
  timed.sort((a, b) => a.at!.compareTo(b.at!));
  return [...timed, ...allDayEvents, ...untimedTasks].take(20).toList();
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// What the native widget reads. The texts come in the app's language, because the widget cannot read the ARB files.
Map<String, String> todayWidgetData(List<TodayWidgetEntry> entries, DateTime now, AppLocalizations l10n) => {
      'today.day': _day(now),
      'today.lang': l10n.localeName,
      'today.items': jsonEncode([for (final e in entries) e.toJson()]),
      'today.title': l10n.widgetTodayTitle,
      'today.empty': l10n.widgetTodayEmpty,
      'today.stale': l10n.widgetTodayStale,
      'today.allDay': l10n.widgetTodayAllDay,
      'today.more': l10n.widgetTodayMore(999).replaceFirst('999', '%d'),
      'today.taskMark': l10n.widgetTodayTask,
    };

/// Writes to the widget storage and redraws the widget. A fake in tests.
abstract interface class TodayWidgetStore {
  Future<void> save(Map<String, String> data, List<DateTime> refreshAt);
  Future<void> clear();
}

class HomeWidgetTodayStore implements TodayWidgetStore {
  static const _provider = 'app.hally.hally.TodayWidgetProvider';

  /// The WidgetKit kind of the iPhone widget (ios/HallyWidgets/TodayWidget.swift).
  static const _iosKind = 'TodayWidget';

  @override
  Future<void> save(Map<String, String> data, List<DateTime> refreshAt) async {
    for (final e in data.entries) {
      await HomeWidget.saveWidgetData<String>(e.key, e.value);
    }
    await HomeWidget.updateWidget(qualifiedAndroidName: _provider, iOSName: _iosKind);
    // Redraw when an item drops off and just after midnight, also while the app is closed (inexact alarms). The
    // iPhone widget plans the same moments in its own timeline.
    if (Platform.isAndroid) await HomeWidget.scheduleWidgetUpdates(refreshAt, qualifiedAndroidName: _provider);
  }

  @override
  Future<void> clear() async {
    await HomeWidget.saveWidgetData<String>('today.items', null);
    await HomeWidget.saveWidgetData<String>('today.day', null);
    await HomeWidget.updateWidget(qualifiedAndroidName: _provider, iOSName: _iosKind);
    if (Platform.isAndroid) await HomeWidget.cancelScheduledWidgetUpdates(qualifiedAndroidName: _provider);
  }
}

class NoTodayWidgetStore implements TodayWidgetStore {
  @override
  Future<void> save(Map<String, String> data, List<DateTime> refreshAt) async {}
  @override
  Future<void> clear() async {}
}

final todayWidgetStoreProvider = Provider<TodayWidgetStore>((ref) {
  // `flutter test` has no native side.
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS) || Platform.environment.containsKey('FLUTTER_TEST')) return NoTodayWidgetStore();
  return HomeWidgetTodayStore();
});

/// The moments the widget should redraw: when each timed item leaves, and a minute after midnight.
List<DateTime> todayWidgetRefreshTimes(List<TodayWidgetEntry> entries, DateTime now) {
  final midnight = DateTime(now.year, now.month, now.day + 1, 0, 1);
  return {
    for (final e in entries)
      if (e.at case final at?) at.add(todayWidgetGrace),
    midnight,
  }.where((t) => t.isAfter(now)).toList()
    ..sort();
}

/// Keeps the home screen widget in step with Today: every time Today loads (app start, pull to refresh, a task
/// done, a live change) the widget gets the new list. Signed out, the widget is cleared.
final todayWidgetSyncProvider = Provider<void>((ref) {
  final store = ref.watch(todayWidgetStoreProvider);
  final familyId = ref.watch(meProvider.select((me) => me.valueOrNull?.primaryFamily?.id));
  final signedOut = ref.watch(meProvider.select((me) => me.hasValue && me.value == null));
  if (familyId == null) {
    if (signedOut) unawaited(store.clear().catchError((Object e) => debugPrint('widget: $e')));
    return;
  }
  final language = ref.watch(languageProvider);
  final locale = language.locale ?? resolveDeviceLocale(ref.watch(deviceLocaleProvider));
  final l10n = lookupAppLocalizations(locale);

  void push(TodayData d) {
    final now = DateTime.now();
    final entries = todayWidgetEntries(d, now);
    unawaited(store
        .save(todayWidgetData(entries, now, l10n), todayWidgetRefreshTimes(entries, now))
        .catchError((Object e) => debugPrint('widget: $e')));
  }

  ref.listen<AsyncValue<TodayData>>(todayProvider(familyId), (_, next) {
    if (next case AsyncData(:final value)) push(value);
  }, fireImmediately: true);

  // Today reloads when the app comes back, so a widget left from yesterday is fixed on the next open.
  final lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(todayProvider(familyId)));
  ref.onDispose(lifecycle.dispose);
});
