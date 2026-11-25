import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

/// "10 kiraz = 5 ₺", the weekly allowance in cherries (0 = off) and whether "Ödedim" also writes Harcamalar.
class AllowanceSettings {
  const AllowanceSettings({this.rateCherries = 10, this.rateAmount = 5, this.currency = 'TRY', this.weeklyCherries = 0, this.addToExpenses = true});

  factory AllowanceSettings.fromJson(Map<String, dynamic> j) => AllowanceSettings(
        rateCherries: (j['rateCherries'] as num?)?.toInt() ?? 10,
        rateAmount: (j['rateAmount'] as num?)?.toDouble() ?? 5,
        currency: j['currency'] as String? ?? 'TRY',
        weeklyCherries: (j['weeklyCherries'] as num?)?.toInt() ?? 0,
        addToExpenses: j['addToExpenses'] as bool? ?? true,
      );

  final int rateCherries;
  final double rateAmount;
  final String currency;
  final int weeklyCherries;
  final bool addToExpenses;

  /// The money for [cherries] (whole steps only).
  double amountFor(int cherries) => cherries ~/ rateCherries * rateAmount;

  AllowanceSettings copyWith({int? rateCherries, double? rateAmount, int? weeklyCherries, bool? addToExpenses}) => AllowanceSettings(
        rateCherries: rateCherries ?? this.rateCherries,
        rateAmount: rateAmount ?? this.rateAmount,
        currency: currency,
        weeklyCherries: weeklyCherries ?? this.weeklyCherries,
        addToExpenses: addToExpenses ?? this.addToExpenses,
      );

  Map<String, dynamic> toJson() =>
      {'rateCherries': rateCherries, 'rateAmount': rateAmount, 'currency': currency, 'weeklyCherries': weeklyCherries, 'addToExpenses': addToExpenses};
}

/// "20 ₺", "2,50 ₺".
String formatMoney(double amount, String currency, String locale) {
  final whole = amount == amount.roundToDouble();
  final text = NumberFormat(whole ? '0' : '0.00', locale).format(amount);
  if (currency != 'TRY') return '$text $currency';
  return locale.startsWith('tr') ? '$text ₺' : '₺$text';
}

class SavingsGoal {
  const SavingsGoal({required this.title, required this.emoji, required this.cherries});

  factory SavingsGoal.fromJson(Map<String, dynamic> j) =>
      SavingsGoal(title: j['title'] as String, emoji: j['emoji'] as String? ?? '🎯', cherries: (j['cherries'] as num).toInt());

  final String title;
  final String emoji;
  final int cherries;

  Map<String, dynamic> toJson() => {'title': title, 'emoji': emoji, 'cherries': cherries};
}

enum AllowanceStatus { pending, paid, declined }

class AllowanceRequestItem {
  const AllowanceRequestItem({
    required this.id,
    required this.childId,
    required this.childName,
    required this.cherries,
    required this.amount,
    this.currency = 'TRY',
    required this.status,
    required this.createdAt,
    this.decidedByName,
  });

  factory AllowanceRequestItem.fromJson(Map<String, dynamic> j) => AllowanceRequestItem(
        id: j['id'] as String,
        childId: j['childId'] as String,
        childName: j['childName'] as String? ?? '',
        cherries: (j['cherries'] as num).toInt(),
        amount: (j['amount'] as num).toDouble(),
        currency: j['currency'] as String? ?? 'TRY',
        status: switch (j['status']) {
          'Paid' => AllowanceStatus.paid,
          'Declined' => AllowanceStatus.declined,
          _ => AllowanceStatus.pending,
        },
        createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
        decidedByName: j['decidedByName'] as String?,
      );

  final String id;
  final String childId;
  final String childName;
  final int cherries;
  final double amount;
  final String currency;
  final AllowanceStatus status;
  final DateTime createdAt;
  final String? decidedByName;

  bool get isPending => status == AllowanceStatus.pending;
}

/// One line of "Son hareketler". [kind] is the ledger kind; for Allowance [title] is `weekly` or `converted`.
class LedgerLine {
  const LedgerLine({required this.kind, required this.title, required this.points, required this.day});

  factory LedgerLine.fromJson(Map<String, dynamic> j) => LedgerLine(
        kind: j['kind'] as String,
        title: j['title'] as String? ?? '',
        points: (j['points'] as num).toInt(),
        day: DateTime.parse(j['day'] as String),
      );

  final String kind;
  final String title;
  final int points;
  final DateTime day;
}

/// The child's Birikimim: jar balance, savings goal and the estimate, conversion rate, a waiting conversion, recent lines.
class ChildSavings {
  const ChildSavings({required this.balance, this.goal, this.weeksToGoal, this.settings = const AllowanceSettings(), this.pending, this.recent = const []});

  factory ChildSavings.fromJson(Map<String, dynamic> j) => ChildSavings(
        balance: (j['balance'] as num?)?.toInt() ?? 0,
        goal: j['goal'] == null ? null : SavingsGoal.fromJson(j['goal'] as Map<String, dynamic>),
        weeksToGoal: (j['weeksToGoal'] as num?)?.toInt(),
        settings: j['settings'] == null ? const AllowanceSettings() : AllowanceSettings.fromJson(j['settings'] as Map<String, dynamic>),
        pending: j['pending'] == null ? null : AllowanceRequestItem.fromJson(j['pending'] as Map<String, dynamic>),
        recent: [for (final l in (j['recent'] as List? ?? const [])) LedgerLine.fromJson(l as Map<String, dynamic>)],
      );

  final int balance;
  final SavingsGoal? goal;
  final int? weeksToGoal;
  final AllowanceSettings settings;
  final AllowanceRequestItem? pending;
  final List<LedgerLine> recent;

  /// The most that can be converted now, in whole steps.
  int get convertible => balance - balance % settings.rateCherries;
}

/// The parents' Harçlık page for one child.
class AllowanceState {
  const AllowanceState({this.settings = const AllowanceSettings(), this.goal, this.balance = 0, this.requests = const []});

  factory AllowanceState.fromJson(Map<String, dynamic> j) => AllowanceState(
        settings: AllowanceSettings.fromJson(j['settings'] as Map<String, dynamic>),
        goal: j['goal'] == null ? null : SavingsGoal.fromJson(j['goal'] as Map<String, dynamic>),
        balance: (j['balance'] as num?)?.toInt() ?? 0,
        requests: [for (final r in (j['requests'] as List? ?? const [])) AllowanceRequestItem.fromJson(r as Map<String, dynamic>)],
      );

  final AllowanceSettings settings;
  final SavingsGoal? goal;
  final int balance;
  final List<AllowanceRequestItem> requests;
}

abstract interface class AllowanceRepository {
  Future<AllowanceState> load(String familyId, String childId);
  Future<AllowanceState> save(String familyId, String childId, AllowanceSettings settings);

  /// Open conversion requests of all children.
  Future<List<AllowanceRequestItem>> pending(String familyId);

  /// "Ödedim" ([paid] true) or "Şimdi değil".
  Future<AllowanceRequestItem> decide(String familyId, String requestId, {required bool paid});
}

class ApiAllowanceRepository implements AllowanceRepository {
  ApiAllowanceRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _url(String familyId, String childId) => '/api/v1/families/$familyId/children/$childId/allowance';

  @override
  Future<AllowanceState> load(String familyId, String childId) =>
      _call(() async => AllowanceState.fromJson((await _api.dio.get<Map<String, dynamic>>(_url(familyId, childId))).data!));

  @override
  Future<AllowanceState> save(String familyId, String childId, AllowanceSettings settings) =>
      _call(() async => AllowanceState.fromJson((await _api.dio.put<Map<String, dynamic>>(_url(familyId, childId), data: settings.toJson())).data!));

  @override
  Future<List<AllowanceRequestItem>> pending(String familyId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/allowance-requests');
        return [for (final r in res.data!) AllowanceRequestItem.fromJson(r as Map<String, dynamic>)];
      });

  @override
  Future<AllowanceRequestItem> decide(String familyId, String requestId, {required bool paid}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/allowance-requests/$requestId/decide', data: {'paid': paid});
        return AllowanceRequestItem.fromJson(res.data!);
      });
}

final allowanceRepositoryProvider = Provider<AllowanceRepository>((ref) => ApiAllowanceRepository(ref.watch(apiClientProvider)));

final allowanceProvider =
    FutureProvider.autoDispose.family<AllowanceState, (String, String)>((ref, key) => ref.watch(allowanceRepositoryProvider).load(key.$1, key.$2));

/// Waiting "Harçlığa çevir" requests for Today; refreshes with the cherry ledger.
final allowanceRequestsProvider = FutureProvider.autoDispose.family<List<AllowanceRequestItem>, String>((ref, familyId) async {
  final live = ref.watch(chatRealtimeProvider).pointsEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(allowanceRepositoryProvider).pending(familyId);
});
