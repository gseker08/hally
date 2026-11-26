import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';

/// A shortcut on Today ("Senin kısayolların"): an existing screen, opened with push.
class FocusShortcut {
  const FocusShortcut(this.key, this.icon, this.route);

  final String key;
  final IconData icon;

  /// `{familyId}` is filled in by [routeFor].
  final String route;

  String routeFor(String familyId) => route.replaceAll('{familyId}', familyId);
}

/// The setup wizard's areas ("Hally en çok neyde yardım etsin?"). Each groups existing features, so choosing one
/// only changes what Today puts first; nothing is turned off. Ids match the server's FocusArea constants.
enum FocusArea {
  school('school', Icons.school_rounded, HallyModule.study, [
    FocusShortcut('study', Icons.menu_book_rounded, '/study'),
    FocusShortcut('exams', Icons.edit_note_rounded, '/exams'),
    FocusShortcut('timetable', Icons.backpack_rounded, '/timetable'),
    FocusShortcut('schoolRun', Icons.directions_car_rounded, '/school-run'),
  ]),
  tasks('tasks', Icons.task_alt_rounded, HallyModule.tasks, [
    FocusShortcut('tasks', Icons.checklist_rounded, '/tasks'),
  ]),
  screen('screen', Icons.phone_iphone_rounded, HallyModule.screenTime, [
    FocusShortcut('screenTime', Icons.phone_iphone_rounded, '/screen-time'),
  ]),
  baby('baby', Icons.child_friendly_rounded, HallyModule.feeding, [
    FocusShortcut('sleep', Icons.bedtime_rounded, '/sleep'),
    FocusShortcut('feeding', Icons.baby_changing_station_rounded, '/feeding'),
  ]),
  health('health', Icons.medication_rounded, HallyModule.health, [
    FocusShortcut('medications', Icons.medication_rounded, '/medications'),
    FocusShortcut('healthCard', Icons.health_and_safety_rounded, '/health'),
  ]),
  cherries('cherries', Icons.stars_rounded, HallyModule.rewards, [
    FocusShortcut('cherries', Icons.stars_rounded, '/stars'),
    FocusShortcut('familyGoal', Icons.flag_rounded, '/family-goal?familyId={familyId}'),
  ]),
  routines('routines', Icons.nightlight_round, HallyModule.habits, [
    FocusShortcut('habits', Icons.repeat_rounded, '/habits'),
    FocusShortcut('activities', Icons.toys_rounded, '/activities?familyId={familyId}'),
  ]),
  shopping('shopping', Icons.shopping_cart_rounded, HallyModule.shopping, [
    FocusShortcut('shopping', Icons.shopping_basket_rounded, '/shopping'),
    FocusShortcut('expenses', Icons.account_balance_wallet_rounded, '/expenses'),
  ]),
  teamwork('teamwork', Icons.handshake_rounded, HallyModule.duties, [
    FocusShortcut('balance', Icons.balance_rounded, '/balance'),
    FocusShortcut('handoffs', Icons.assignment_turned_in_rounded, '/handoffs'),
  ]);

  const FocusArea(this.id, this.icon, this.color, this.shortcuts);

  final String id;
  final IconData icon;
  final Color color;
  final List<FocusShortcut> shortcuts;

  static FocusArea? byId(String id) => values.where((a) => a.id == id).firstOrNull;

  String label(AppLocalizations l10n) => switch (this) {
        school => l10n.focusSchool,
        tasks => l10n.focusTasks,
        screen => l10n.focusScreen,
        baby => l10n.focusBaby,
        health => l10n.focusHealth,
        cherries => l10n.focusCherries,
        routines => l10n.focusRoutines,
        shopping => l10n.focusShopping,
        teamwork => l10n.focusTeamwork,
      };
}

String shortcutLabel(AppLocalizations l10n, String key) => switch (key) {
      'study' => l10n.shortcutStudy,
      'exams' => l10n.shortcutExams,
      'timetable' => l10n.shortcutTimetable,
      'schoolRun' => l10n.shortcutSchoolRun,
      'tasks' => l10n.shortcutTasks,
      'screenTime' => l10n.shortcutScreenTime,
      'sleep' => l10n.shortcutSleep,
      'feeding' => l10n.shortcutFeeding,
      'medications' => l10n.shortcutMedications,
      'healthCard' => l10n.shortcutHealthCard,
      'cherries' => l10n.shortcutCherries,
      'familyGoal' => l10n.shortcutFamilyGoal,
      'habits' => l10n.shortcutHabits,
      'activities' => l10n.shortcutActivities,
      'shopping' => l10n.shortcutShopping,
      'expenses' => l10n.shortcutExpenses,
      'balance' => l10n.shortcutBalance,
      'handoffs' => l10n.shortcutHandoffs,
      _ => key,
    };

/// The most the wizard lets a parent pick, so Today stays short.
const maxFocusAreas = 4;

/// A first guess from the children's ages; the parent changes it. Babies → sleep and feeding, school age → school,
/// 9+ → screen time, preschoolers → routines. Tasks always fit. Never more than [maxFocusAreas].
List<FocusArea> suggestFocus(List<int> ages) {
  final out = <FocusArea>[];
  if (ages.any((a) => a >= 6)) out.add(FocusArea.school);
  out.add(FocusArea.tasks);
  if (ages.any((a) => a <= 3)) out.add(FocusArea.baby);
  if (ages.any((a) => a >= 9)) out.add(FocusArea.screen);
  if (ages.any((a) => a >= 3 && a <= 5)) out.add(FocusArea.routines);
  if (ages.isEmpty) out.addAll([FocusArea.shopping, FocusArea.teamwork]);
  return out.take(maxFocusAreas).toList();
}

/// This parent's choice. [areas] empty = Today shows everything (skipped, or chose nothing).
class FocusSettings {
  const FocusSettings({required this.areas, required this.setupDone});

  factory FocusSettings.fromJson(Map<String, dynamic> j) => FocusSettings(
        areas: [for (final id in (j['areas'] as List? ?? const [])) FocusArea.byId(id as String)].whereType<FocusArea>().toList(),
        setupDone: j['setupDone'] as bool? ?? false,
      );

  final List<FocusArea> areas;
  final bool setupDone;

  /// Whether Today shows [area]'s own cards: always when nothing was chosen.
  bool shows(FocusArea area) => areas.isEmpty || areas.contains(area);
}

abstract interface class FocusRepository {
  Future<FocusSettings> get(String familyId);
  Future<FocusSettings> set(String familyId, List<FocusArea> areas);
}

class ApiFocusRepository implements FocusRepository {
  ApiFocusRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<FocusSettings> get(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/focus');
        return FocusSettings.fromJson(res.data!);
      });

  @override
  Future<FocusSettings> set(String familyId, List<FocusArea> areas) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/focus', data: {
          'areas': [for (final a in areas) a.id],
        });
        return FocusSettings.fromJson(res.data!);
      });
}

final focusRepositoryProvider = Provider<FocusRepository>((ref) => ApiFocusRepository(ref.watch(apiClientProvider)));

final focusProvider = FutureProvider.family<FocusSettings, String>((ref, familyId) => ref.watch(focusRepositoryProvider).get(familyId));

/// An area's mark: the cherry for cherries, else its icon in the area's colour.
class FocusAreaIcon extends StatelessWidget {
  const FocusAreaIcon({super.key, required this.area, this.size = 24});

  final FocusArea area;
  final double size;

  @override
  Widget build(BuildContext context) => area == FocusArea.cherries
      ? CherryIcon(size: size + 2)
      : Icon(area.icon, size: size, color: HallyColors.readableOn(area.color, Theme.of(context).brightness));
}
