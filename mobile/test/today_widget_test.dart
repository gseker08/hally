import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hally/features/home/today_widget.dart';
import 'package:hally/features/planning/planning_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';

TaskItem task(String title, {DateTime? due, bool allDay = false}) =>
    TaskItem(id: title, title: title, dueAt: due, allDay: allDay, state: 'Open');

EventItem event(String title, DateTime at, {bool allDay = false}) =>
    EventItem(id: title, title: title, startsAt: at, allDay: allDay);

void main() {
  final now = DateTime(2026, 11, 23, 14, 0);

  test('orders timed items first, then all-day events, then tasks without a time; drops what has passed', () {
    final d = TodayData(
      overdue: [task('Old', due: DateTime(2026, 11, 22, 9))],
      dueToday: [
        task('Milk'),
        task('Call school', due: DateTime(2026, 11, 23, 16, 30)),
        task('Done earlier', due: DateTime(2026, 11, 23, 9))
      ],
      events: [
        event('Swimming', DateTime(2026, 11, 23, 17)),
        event('Holiday', DateTime(2026, 11, 23), allDay: true),
        event('Started', DateTime(2026, 11, 23, 13, 50)),
        event('Morning', DateTime(2026, 11, 23, 8)),
      ],
      waiting: const [],
    );

    final entries = todayWidgetEntries(d, now);

    expect([for (final e in entries) e.title], ['Started', 'Call school', 'Swimming', 'Holiday', 'Milk']);
    expect(entries.first.kind, 'event');
    expect(entries[3].allDay, isTrue);
    expect(entries.last.at, isNull);
  });

  test('widget data carries the items and texts in the app language', () {
    final entries = [TodayWidgetEntry(title: 'Swimming', kind: 'event', at: DateTime(2026, 11, 23, 17))];
    final data = todayWidgetData(entries, now, lookupAppLocalizations(const Locale('tr')));

    expect(data['today.day'], '2026-11-23');
    expect(data['today.lang'], 'tr');
    expect(data['today.title'], 'Bugün');
    expect(data['today.more'], '+%d daha');
    final items = jsonDecode(data['today.items']!) as List;
    expect(items.single['title'], 'Swimming');
    expect(items.single['at'], DateTime(2026, 11, 23, 17).millisecondsSinceEpoch);
  });

  test('redraws when each timed item leaves and after midnight', () {
    final entries = [
      TodayWidgetEntry(title: 'A', kind: 'event', at: DateTime(2026, 11, 23, 17)),
      const TodayWidgetEntry(title: 'B', kind: 'task'),
    ];

    expect(todayWidgetRefreshTimes(entries, now), [DateTime(2026, 11, 23, 17, 15), DateTime(2026, 11, 24, 0, 1)]);
  });
}
