import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

double _num(Object? v) => (v as num?)?.toDouble() ?? 0;

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class Expense {
  const Expense({required this.id, required this.title, required this.amount, required this.category, required this.date, required this.paidByUserId, this.paidByName, this.childId, this.note, this.myShare = 0});

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] as String,
        title: j['title'] as String,
        amount: _num(j['amount']),
        category: j['category'] as String,
        date: DateTime.parse(j['date'] as String),
        paidByUserId: j['paidByUserId'] as String,
        paidByName: j['paidByName'] as String?,
        childId: j['childId'] as String?,
        note: j['note'] as String?,
        myShare: _num(j['myShare']),
      );

  final String id;
  final String title;
  final double amount;

  /// School, Health, Clothes, Activity, Food or Other.
  final String category;
  final DateTime date;
  final String paidByUserId;
  final String? paidByName;
  final String? childId;
  final String? note;
  final double myShare;
}

class Settlement {
  const Settlement({required this.id, required this.fromUserId, this.fromName, required this.toUserId, this.toName, required this.amount, required this.date});

  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
        id: j['id'] as String,
        fromUserId: j['fromUserId'] as String,
        fromName: j['fromName'] as String?,
        toUserId: j['toUserId'] as String,
        toName: j['toName'] as String?,
        amount: _num(j['amount']),
        date: DateTime.parse(j['date'] as String),
      );

  final String id;
  final String fromUserId;
  final String? fromName;
  final String toUserId;
  final String? toName;
  final double amount;
  final DateTime date;
}

class ExpenseBalance {
  const ExpenseBalance({required this.userId, required this.name, this.net = 0});

  factory ExpenseBalance.fromJson(Map<String, dynamic> j) => ExpenseBalance(userId: j['userId'] as String, name: j['name'] as String, net: _num(j['net']));

  final String userId;
  final String name;

  /// Positive: the others owe this adult.
  final double net;
}

class SettleSuggestion {
  const SettleSuggestion({required this.fromUserId, required this.fromName, required this.toUserId, required this.toName, required this.amount});

  factory SettleSuggestion.fromJson(Map<String, dynamic> j) => SettleSuggestion(
        fromUserId: j['fromUserId'] as String,
        fromName: j['fromName'] as String,
        toUserId: j['toUserId'] as String,
        toName: j['toName'] as String,
        amount: _num(j['amount']),
      );

  final String fromUserId;
  final String fromName;
  final String toUserId;
  final String toName;
  final double amount;
}

class ExpenseMonth {
  const ExpenseMonth({
    required this.month,
    this.currency = 'TRY',
    this.total = 0,
    this.byCategory = const {},
    this.expenses = const [],
    this.settlements = const [],
    this.balances = const [],
    this.suggestion,
  });

  factory ExpenseMonth.fromJson(Map<String, dynamic> j) => ExpenseMonth(
        month: j['month'] as String,
        currency: j['currency'] as String? ?? 'TRY',
        total: _num(j['total']),
        byCategory: {for (final c in j['byCategory'] as List) (c as Map)['category'] as String: _num(c['amount'])},
        expenses: [for (final e in j['expenses'] as List) Expense.fromJson(e as Map<String, dynamic>)],
        settlements: [for (final s in j['settlements'] as List) Settlement.fromJson(s as Map<String, dynamic>)],
        balances: [for (final b in j['balances'] as List) ExpenseBalance.fromJson(b as Map<String, dynamic>)],
        suggestion: j['suggestion'] is Map ? SettleSuggestion.fromJson(Map<String, dynamic>.from(j['suggestion'] as Map)) : null,
      );

  /// yyyy-MM.
  final String month;
  final String currency;
  final double total;
  final Map<String, double> byCategory;
  final List<Expense> expenses;
  final List<Settlement> settlements;
  final List<ExpenseBalance> balances;
  final SettleSuggestion? suggestion;
}

abstract interface class ExpensesRepository {
  Future<ExpenseMonth> month(String familyId, String? month);
  Future<ExpenseMonth> add(String familyId,
      {required String title, required double amount, required String category, DateTime? date, String? paidByUserId, String? childId, String? note});
  Future<ExpenseMonth> delete(String familyId, String expenseId);
  Future<ExpenseMonth> settle(String familyId, {required String toUserId, required double amount});
  Future<ExpenseMonth> deleteSettlement(String familyId, String settlementId);
}

class ApiExpensesRepository implements ExpensesRepository {
  ApiExpensesRepository(this._api);

  final ApiClient _api;

  Future<ExpenseMonth> _month(Future<dynamic> Function() fn) async {
    try {
      return ExpenseMonth.fromJson((await fn()).data as Map<String, dynamic>);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _u(String familyId) => '/api/v1/families/$familyId/expenses';

  @override
  Future<ExpenseMonth> month(String familyId, String? month) =>
      _month(() => _api.dio.get<Map<String, dynamic>>(_u(familyId), queryParameters: {if (month != null) 'month': month}));

  @override
  Future<ExpenseMonth> add(String familyId,
          {required String title, required double amount, required String category, DateTime? date, String? paidByUserId, String? childId, String? note}) =>
      _month(() => _api.dio.post<Map<String, dynamic>>(_u(familyId), data: {
            'title': title,
            'amount': amount,
            'category': category,
            if (date != null) 'date': _day(date),
            'paidByUserId': paidByUserId,
            'childId': childId,
            'note': note,
          }));

  @override
  Future<ExpenseMonth> delete(String familyId, String expenseId) => _month(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId)}/$expenseId'));

  @override
  Future<ExpenseMonth> settle(String familyId, {required String toUserId, required double amount}) =>
      _month(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId)}/settlements', data: {'toUserId': toUserId, 'amount': amount}));

  @override
  Future<ExpenseMonth> deleteSettlement(String familyId, String settlementId) =>
      _month(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId)}/settlements/$settlementId'));
}

final expensesRepositoryProvider = Provider<ExpensesRepository>((ref) => ApiExpensesRepository(ref.watch(apiClientProvider)));

/// One month (null: this month) of expenses; follows the other parent's changes live.
final expenseMonthProvider = FutureProvider.autoDispose.family<ExpenseMonth, (String, String?)>((ref, key) async {
  final live = ref.watch(chatRealtimeProvider).expensesEvents.where((e) => e['familyId'] == key.$1).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(expensesRepositoryProvider).month(key.$1, key.$2);
});
