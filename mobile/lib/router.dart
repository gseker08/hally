import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/auth/auth_repository.dart';
import 'core/design/widgets.dart';
import 'features/activities/activity_screens.dart' show FamilyActivitiesScreen;
import 'features/bedtime/bedtime_screens.dart' show BedtimeSettingsScreen;
import 'features/child_mode/child_mode_repository.dart';
import 'features/goal/goal_widgets.dart' show FamilyGoalScreen;
import 'features/child_mode/kid_screens.dart';
import 'features/child_mode/parent_child_mode.dart';
import 'features/kids/kids_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/billing/paywall_screen.dart';
import 'features/points/points_screen.dart';
import 'features/privacy/privacy_screen.dart';
import 'features/capture/capture_text_screen.dart';
import 'features/capture/review_screen.dart';
import 'features/demo/demo_scan_screen.dart';
import 'features/duties/duties_screen.dart';
import 'features/expenses/expenses_screen.dart';
import 'features/family/caregiver_screen.dart';
import 'features/family/family_screen.dart';
import 'features/health/health_screen.dart';
import 'features/balance/balance_screen.dart';
import 'features/handoff/handoff_cards.dart';
import 'features/handoff/handoff_screen.dart';
import 'features/insights/insights_screen.dart';
import 'features/mood/mood_widgets.dart';
import 'features/feeding/feeding_screen.dart';
import 'features/family/family_setup_screen.dart';
import 'features/family/invite_partner_screen.dart';
import 'features/family/join_family_screen.dart';
import 'features/habits/habits_screen.dart';
import 'features/home/home_shell.dart';
import 'features/medications/medications_screen.dart';
import 'features/messages/chat_screen.dart';
import 'features/messages/chats_screen.dart';
import 'features/assistant/assistant_screen.dart';
import 'features/home/today_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/screen_time/screen_time_screen.dart';
import 'features/shopping/shopping_screen.dart';
import 'features/sleep/sleep_screen.dart';
import 'features/study/study_screen.dart';
import 'features/sharing/weekly_card_screen.dart';
import 'features/planning/calendar_screen.dart';
import 'features/planning/tasks_screen.dart';
import 'features/onboarding/trust_screen.dart';
import 'features/onboarding/welcome_screen.dart';

const _publicRoutes = {'/welcome', '/trust', '/demo', '/sign-in', '/join', '/kid/pair'};

/// Pure redirect rules so they can be unit tested.
String? resolveRedirect({
  required String location,
  required bool loading,
  required Me? me,
  required String? pendingInviteToken,
  bool childMode = false,
}) {
  final isInvite = location.startsWith('/i/');
  if (loading) return location == '/' ? null : (isInvite ? null : '/');

  // A paired child's phone only ever shows child mode.
  if (childMode) return location == '/kid' ? null : '/kid';
  if (location == '/kid') return '/';

  if (me == null) {
    if (isInvite || _publicRoutes.contains(location)) return null;
    return '/welcome';
  }

  if (pendingInviteToken != null && !isInvite) return '/i/$pendingInviteToken';
  if (isInvite) return null;

  if (me.primaryFamily == null) {
    return location == '/family/new' ? null : '/family/new';
  }

  final onboarding = location == '/' || _publicRoutes.contains(location) || location == '/family/new';
  return onboarding ? '/today' : null;
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(meProvider, (_, __) => refresh.value++);
  ref.listen(pendingInviteTokenProvider, (_, __) => refresh.value++);
  ref.listen(childSessionProvider, (_, __) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final me = ref.read(meProvider);
      final child = ref.read(childSessionProvider);
      return resolveRedirect(
        location: state.matchedLocation,
        loading: (me.isLoading && !me.hasValue) || (child.isLoading && !child.hasValue),
        childMode: child.valueOrNull != null,
        me: me.valueOrNull,
        pendingInviteToken: ref.read(pendingInviteTokenProvider),
      );
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: HallyLoading())),
      GoRoute(path: '/welcome', builder: (_, __) => const WelcomeScreen()),
      GoRoute(path: '/trust', builder: (_, __) => const TrustScreen()),
      GoRoute(path: '/demo', builder: (_, __) => const DemoScanScreen()),
      GoRoute(path: '/sign-in', builder: (_, __) => const SignInScreen()),
      GoRoute(path: '/join', builder: (_, __) => const EnterInviteScreen()),
      GoRoute(path: '/kid/pair', builder: (_, __) => const KidPairScreen()),
      GoRoute(path: '/kid', builder: (_, __) => const KidShell()),
      GoRoute(path: '/i/:token', builder: (_, s) => JoinFamilyScreen(token: s.pathParameters['token']!)),
      GoRoute(path: '/family/new', builder: (_, __) => const FamilySetupScreen()),
      GoRoute(path: '/family/:id/invite', builder: (_, s) => InvitePartnerScreen(familyId: s.pathParameters['id']!)),
      GoRoute(
        path: '/family/:id/caregiver/:userId',
        builder: (_, s) => CaregiverScreen(familyId: s.pathParameters['id']!, userId: s.pathParameters['userId']!),
      ),
      GoRoute(path: '/capture/text', builder: (_, __) => const CaptureTextScreen()),
      GoRoute(path: '/capture/review', builder: (_, __) => const ReviewScreen()),
      GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
      GoRoute(path: '/tasks', builder: (_, __) => const TasksScreen()),
      GoRoute(path: '/chats', builder: (_, __) => const ChatsScreen()),
      GoRoute(path: '/chats/:key', builder: (_, s) => ChatScreen(chatKey: s.pathParameters['key']!, title: s.extra as String?, draft: s.uri.queryParameters['draft'])),
      GoRoute(path: '/sleep', builder: (_, __) => const SleepScreen()),
      GoRoute(path: '/feeding', builder: (_, __) => const FeedingScreen()),
      GoRoute(path: '/study', builder: (_, __) => const StudyScreen()),
      GoRoute(path: '/stars', builder: (_, __) => const PointsScreen()),
      GoRoute(path: '/habits', builder: (_, __) => const HabitsScreen()),
      GoRoute(path: '/school-run', builder: (_, __) => const DutiesScreen()),
      GoRoute(path: '/expenses', builder: (_, __) => const ExpensesScreen()),
      GoRoute(path: '/health', builder: (_, __) => const HealthScreen()),
      GoRoute(
        path: '/family/:id/child/:childId/phone',
        builder: (_, s) => ConnectPhoneScreen(familyId: s.pathParameters['id']!, childId: s.pathParameters['childId']!),
      ),
      GoRoute(path: '/child/:id/moods', builder: (_, s) => MoodScreen(childId: s.pathParameters['id']!)),
      GoRoute(path: '/child/:id/insights', builder: (_, s) => InsightsScreen(childId: s.pathParameters['id']!)),
      GoRoute(path: '/shopping', builder: (_, __) => const ShoppingScreen()),
      GoRoute(path: '/medications', builder: (_, __) => const MedicationsScreen()),
      GoRoute(path: '/screen-time', builder: (_, __) => const ScreenTimeScreen()),
      GoRoute(path: '/handoff/:childId', builder: (_, s) => HandoffScreen(childId: s.pathParameters['childId']!)),
      GoRoute(path: '/handoffs', builder: (_, s) => HandoffHistoryScreen(childId: s.uri.queryParameters['childId'])),
      GoRoute(path: '/balance', builder: (_, __) => const BalanceScreen()),
      GoRoute(path: '/family-goal', builder: (_, s) => FamilyGoalScreen(familyId: s.uri.queryParameters['familyId'])),
      GoRoute(
          path: '/bedtime/:childId',
          builder: (_, s) => BedtimeSettingsScreen(familyId: s.uri.queryParameters['familyId'] ?? '', childId: s.pathParameters['childId']!)),
      GoRoute(path: '/activities', builder: (_, s) => FamilyActivitiesScreen(familyId: s.uri.queryParameters['familyId'] ?? '')),
      GoRoute(path: '/weekly-card', builder: (_, __) => const WeeklyCardScreen()),
      GoRoute(path: '/share-links', builder: (_, __) => const ShareLinksScreen()),
      GoRoute(
        path: '/paywall',
        pageBuilder: (_, s) => MaterialPage(
          fullscreenDialog: true,
          child: PaywallScreen(trigger: s.uri.queryParameters['trigger'] ?? 'plan_screen'),
        ),
      ),
      GoRoute(path: '/plan', builder: (_, __) => const PlanScreen()),
      GoRoute(path: '/assistant', builder: (_, s) => AssistantScreen(startVoice: s.uri.queryParameters['voice'] == '1')),
      GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
      GoRoute(path: '/privacy', builder: (_, __) => const PrivacyScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/today', builder: (_, __) => const TodayScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/calendar', builder: (_, __) => const CalendarScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/kids', builder: (_, __) => const KidsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/family', builder: (_, __) => const FamilyScreen())]),
        ],
      ),
    ],
  );
});
