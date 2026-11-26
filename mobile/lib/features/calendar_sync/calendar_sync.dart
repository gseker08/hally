import 'dart:async';
import 'dart:convert';

import 'package:device_calendar_plus/device_calendar_plus.dart' as dc;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/token_storage.dart';
import '../family/family_repository.dart';
import '../planning/planning_repository.dart';

/// Calendar sync works through the phone's own calendars (Android Calendar Provider / iOS EventKit): Google, iCloud
/// and Outlook accounts that are on the phone show up there, so Hally needs no passwords and no Google or Microsoft
/// sign-in. Per calendar the parent picks "only me" (read live on this phone, never uploaded) or "my family" (a
/// read-only copy goes to the server, see ExternalEventsController). Hally's own family events can also be written
/// into a separate "Hally" calendar on the phone, and a private iCal link serves them to computers.

enum CalendarProvider {
  google('Google'),
  icloud('ICloud'),
  outlook('Outlook'),
  other('Other');

  const CalendarProvider(this.api);

  final String api;

  static CalendarProvider fromApi(String? value) => values.firstWhere((p) => p.api == value, orElse: () => other);
}

/// Best guess of the account behind a phone calendar. Android reports the account type (com.google, …) and the
/// account name (usually the e-mail); iOS reports the source type (calDav, exchange, …) and the source title.
CalendarProvider providerOf(String? accountName, String? accountType) {
  final t = (accountType ?? '').toLowerCase();
  final n = (accountName ?? '').toLowerCase();
  bool mail(List<String> domains) => domains.any((d) => n.endsWith('@$d'));
  if (t.contains('google') || n == 'gmail' || n.contains('google') || mail(['gmail.com', 'googlemail.com'])) return CalendarProvider.google;
  if (n.contains('icloud') || t.contains('icloud') || t.contains('apple') || mail(['icloud.com', 'me.com', 'mac.com'])) return CalendarProvider.icloud;
  if (t.contains('exchange') || t.contains('outlook') || t.contains('microsoft') || t.contains('office') || t.contains('eas') ||
      n.contains('outlook') || n.contains('exchange') || mail(['outlook.com', 'hotmail.com', 'live.com', 'msn.com'])) {
    return CalendarProvider.outlook;
  }
  return CalendarProvider.other;
}

class PhoneCalendar {
  const PhoneCalendar({
    required this.id,
    required this.name,
    required this.provider,
    this.accountName,
    this.colorHex,
    this.readOnly = false,
    this.subscribed = false,
  });

  final String id;
  final String name;
  final CalendarProvider provider;
  final String? accountName;
  final String? colorHex;
  final bool readOnly;

  /// Holidays, birthdays and other subscribed feeds: offered, but not ticked by default.
  final bool subscribed;
}

class PhoneEvent {
  const PhoneEvent({
    required this.calendarId,
    required this.eventId,
    required this.instanceId,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
  });

  final String calendarId;
  final String eventId;

  /// Opens this occurrence in the phone's calendar app.
  final String instanceId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
}

enum CalendarAccess { granted, denied, notDetermined, unavailable }

/// The phone's calendars. The real one talks to device_calendar_plus; tests use a fake. Every method is safe to call
/// where the plugin is missing (tests, web): reads return nothing and [access] says [CalendarAccess.unavailable].
abstract interface class PhoneCalendarGateway {
  Future<CalendarAccess> access();

  /// Shows the system prompt when the answer is still open. True when access is granted.
  Future<bool> requestAccess();
  Future<void> openSettings();
  Future<List<PhoneCalendar>> calendars();
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> calendarIds);
  Future<String> createCalendar(String name, String colorHex);
  Future<void> deleteCalendar(String id);
  Future<String> createEvent(String calendarId, {required String title, required DateTime start, required DateTime end, required bool allDay, String? location});
  Future<void> deleteEvent(String instanceId);
  Future<void> openEvent(String instanceId);
}

class DevicePhoneCalendarGateway implements PhoneCalendarGateway {
  dc.DeviceCalendar get _plugin => dc.DeviceCalendar.instance;

  static bool _missing(Object e) => e is MissingPluginException || e is UnimplementedError;

  @override
  Future<CalendarAccess> access() async {
    try {
      return switch (await _plugin.hasPermissions()) {
        dc.CalendarPermissionStatus.granted => CalendarAccess.granted,
        dc.CalendarPermissionStatus.notDetermined => CalendarAccess.notDetermined,
        _ => CalendarAccess.denied,
      };
    } catch (e) {
      return _missing(e) ? CalendarAccess.unavailable : CalendarAccess.denied;
    }
  }

  @override
  Future<bool> requestAccess() async {
    try {
      return await _plugin.requestPermissions() == dc.CalendarPermissionStatus.granted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await _plugin.openAppSettings();
    } catch (_) {}
  }

  @override
  Future<List<PhoneCalendar>> calendars() async {
    final all = await _plugin.listCalendars();
    return [
      for (final c in all)
        if (!c.hidden)
          PhoneCalendar(
            id: c.id,
            name: c.name,
            provider: providerOf(c.accountName, c.accountType),
            accountName: c.accountName,
            colorHex: c.colorHex,
            readOnly: c.readOnly,
            subscribed: (c.accountType ?? '').toLowerCase().contains('subscri') || (c.accountType ?? '').toLowerCase().contains('birthday') ||
                c.id.contains('#holiday@') || (c.accountName ?? '').contains('#holiday@'),
          ),
    ];
  }

  @override
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> calendarIds) async {
    if (calendarIds.isEmpty) return const [];
    final events = await _plugin.listEvents(from, to, calendarIds: calendarIds);
    return [
      for (final e in events)
        PhoneEvent(
          calendarId: e.calendarId,
          eventId: e.eventId,
          instanceId: e.instanceId,
          title: e.title,
          start: e.startDate,
          end: e.endDate,
          allDay: e.isAllDay,
        ),
    ];
  }

  @override
  Future<String> createCalendar(String name, String colorHex) => _plugin.createCalendar(name: name, colorHex: colorHex);

  @override
  Future<void> deleteCalendar(String id) => _plugin.deleteCalendar(id);

  @override
  Future<String> createEvent(String calendarId,
          {required String title, required DateTime start, required DateTime end, required bool allDay, String? location}) =>
      _plugin.createEvent(calendarId: calendarId, title: title, startDate: start, endDate: end, isAllDay: allDay, location: location);

  @override
  Future<void> deleteEvent(String instanceId) => _plugin.deleteEvent(instanceId: instanceId);

  @override
  Future<void> openEvent(String instanceId) => _plugin.showEventModal(instanceId);
}

final phoneCalendarGatewayProvider = Provider<PhoneCalendarGateway>((ref) => DevicePhoneCalendarGateway());

enum ShareMode { onlyMe, family }

/// One Hally event written to the phone's "Hally" calendar: its phone id and a fingerprint to spot changes.
class ExportedEvent {
  const ExportedEvent(this.phoneId, this.fingerprint);

  final String phoneId;
  final String fingerprint;
}

/// What this phone syncs. Kept on the device (secure storage), never on the server.
class CalendarSyncSettings {
  const CalendarSyncSettings({
    this.familyId,
    this.calendars = const {},
    this.busyOnly = false,
    this.exportEnabled = false,
    this.exportChildId,
    this.hallyCalendarId,
    this.exported = const {},
    this.inviteDone = false,
    this.sharedBefore = false,
    this.feedUrl,
    this.lastSync,
  });

  factory CalendarSyncSettings.fromJson(Map<String, dynamic> j) => CalendarSyncSettings(
        familyId: j['familyId'] as String?,
        calendars: {
          for (final e in (j['calendars'] as Map? ?? const {}).entries)
            e.key as String: e.value == 'family' ? ShareMode.family : ShareMode.onlyMe,
        },
        busyOnly: j['busyOnly'] as bool? ?? false,
        exportEnabled: j['exportEnabled'] as bool? ?? false,
        exportChildId: j['exportChildId'] as String?,
        hallyCalendarId: j['hallyCalendarId'] as String?,
        exported: {
          for (final e in (j['exported'] as Map? ?? const {}).entries)
            e.key as String: ExportedEvent((e.value as List)[0] as String, (e.value as List)[1] as String),
        },
        inviteDone: j['inviteDone'] as bool? ?? false,
        sharedBefore: j['sharedBefore'] as bool? ?? false,
        feedUrl: j['feedUrl'] as String?,
        lastSync: j['lastSync'] == null ? null : DateTime.tryParse(j['lastSync'] as String),
      );

  final String? familyId;

  /// Selected phone calendars and who sees them.
  final Map<String, ShareMode> calendars;

  /// Family-shared events go up without their titles ("Ayşe is busy").
  final bool busyOnly;
  final bool exportEnabled;

  /// Export only events tagged with this child; null exports every family event.
  final String? exportChildId;
  final String? hallyCalendarId;
  final Map<String, ExportedEvent> exported;
  final bool inviteDone;

  /// Something was shared with the family, so turning the last family calendar off must clear it on the server.
  final bool sharedBefore;

  /// The iCal link made on this phone (the server keeps only its hash).
  final String? feedUrl;
  final DateTime? lastSync;

  bool get isEmpty => calendars.isEmpty && !exportEnabled;

  List<String> get familyCalendarIds => [for (final e in calendars.entries) if (e.value == ShareMode.family) e.key];

  Map<String, dynamic> toJson() => {
        'familyId': familyId,
        'calendars': {for (final e in calendars.entries) e.key: e.value == ShareMode.family ? 'family' : 'me'},
        'busyOnly': busyOnly,
        'exportEnabled': exportEnabled,
        'exportChildId': exportChildId,
        'hallyCalendarId': hallyCalendarId,
        'exported': {for (final e in exported.entries) e.key: [e.value.phoneId, e.value.fingerprint]},
        'inviteDone': inviteDone,
        'sharedBefore': sharedBefore,
        'feedUrl': feedUrl,
        'lastSync': lastSync?.toUtc().toIso8601String(),
      };

  CalendarSyncSettings copyWith({
    Map<String, ShareMode>? calendars,
    bool? busyOnly,
    bool? exportEnabled,
    Object? exportChildId = _keep,
    Object? hallyCalendarId = _keep,
    Map<String, ExportedEvent>? exported,
    bool? inviteDone,
    bool? sharedBefore,
    Object? feedUrl = _keep,
    DateTime? lastSync,
  }) =>
      CalendarSyncSettings(
        familyId: familyId,
        calendars: calendars ?? this.calendars,
        busyOnly: busyOnly ?? this.busyOnly,
        exportEnabled: exportEnabled ?? this.exportEnabled,
        exportChildId: exportChildId == _keep ? this.exportChildId : exportChildId as String?,
        hallyCalendarId: hallyCalendarId == _keep ? this.hallyCalendarId : hallyCalendarId as String?,
        exported: exported ?? this.exported,
        inviteDone: inviteDone ?? this.inviteDone,
        sharedBefore: sharedBefore ?? this.sharedBefore,
        feedUrl: feedUrl == _keep ? this.feedUrl : feedUrl as String?,
        lastSync: lastSync ?? this.lastSync,
      );

  static const _keep = Object();
}

abstract interface class CalendarSyncStorage {
  /// Null when the device storage can't be read (then nothing syncs and nothing is offered).
  Future<CalendarSyncSettings?> read();
  Future<void> write(CalendarSyncSettings settings);
}

class SecureCalendarSyncStorage implements CalendarSyncStorage {
  SecureCalendarSyncStorage([FlutterSecureStorage? storage]) : _storage = storage ?? hallySecureStorage;

  static const _key = 'hally.calendar_sync';
  final FlutterSecureStorage _storage;

  @override
  Future<CalendarSyncSettings?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      return raw == null ? const CalendarSyncSettings() : CalendarSyncSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(CalendarSyncSettings settings) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(settings.toJson()));
    } catch (_) {}
  }
}

final calendarSyncStorageProvider = Provider<CalendarSyncStorage>((ref) => SecureCalendarSyncStorage());

/// This phone's settings for the signed-in parent's family. A different family (another account signed in) starts fresh.
class CalendarSyncSettingsController extends AsyncNotifier<CalendarSyncSettings?> {
  @override
  Future<CalendarSyncSettings?> build() async {
    String? familyId;
    try {
      familyId = (await ref.watch(meProvider.future))?.primaryFamily?.id;
    } catch (_) {
      return null; // signed out or offline
    }
    if (familyId == null) return null;
    final stored = await ref.watch(calendarSyncStorageProvider).read();
    if (stored == null) return null;
    if (stored.familyId == familyId) return stored;
    return CalendarSyncSettings(familyId: familyId, inviteDone: stored.familyId == null ? stored.inviteDone : false);
  }

  Future<void> save(CalendarSyncSettings settings) async {
    await ref.read(calendarSyncStorageProvider).write(settings);
    state = AsyncData(settings);
  }
}

final calendarSyncSettingsProvider = AsyncNotifierProvider<CalendarSyncSettingsController, CalendarSyncSettings?>(CalendarSyncSettingsController.new);

/// A phone event a parent shared with the family, as the server returns it.
class SharedEvent {
  const SharedEvent({
    required this.id,
    required this.ownerName,
    required this.mine,
    required this.provider,
    required this.calendarName,
    required this.busyOnly,
    required this.startsAt,
    required this.endsAt,
    required this.allDay,
    this.title,
    this.colorHex,
  });

  factory SharedEvent.fromJson(Map<String, dynamic> j) => SharedEvent(
        id: j['id'] as String,
        ownerName: j['ownerName'] as String? ?? '',
        mine: j['mine'] as bool? ?? false,
        provider: CalendarProvider.fromApi(j['provider'] as String?),
        calendarName: j['calendarName'] as String? ?? '',
        title: j['title'] as String?,
        busyOnly: j['busyOnly'] as bool? ?? false,
        startsAt: DateTime.parse(j['startsAt'] as String).toLocal(),
        endsAt: DateTime.parse(j['endsAt'] as String).toLocal(),
        allDay: j['allDay'] as bool? ?? false,
        colorHex: j['colorHex'] as String?,
      );

  final String id;
  final String ownerName;
  final bool mine;
  final CalendarProvider provider;
  final String calendarName;
  final String? title;
  final bool busyOnly;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool allDay;
  final String? colorHex;
}

class FeedLink {
  const FeedLink(this.url, this.webcalUrl);

  final String url;
  final String webcalUrl;
}

abstract interface class CalendarSyncApi {
  Future<List<SharedEvent>> sharedEvents(String familyId, DateTime from, DateTime to);

  /// Replaces everything this parent shares with [events] (JSON maps in the server's shape).
  Future<void> share(String familyId, List<Map<String, dynamic>> events);
  Future<void> stopSharing(String familyId);

  /// Whether a link exists (made on any phone).
  Future<bool> feedActive(String familyId);
  Future<FeedLink> createFeed(String familyId);
  Future<void> revokeFeed(String familyId);
}

class HttpCalendarSyncApi implements CalendarSyncApi {
  HttpCalendarSyncApi(this._api);

  final ApiClient _api;

  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<List<SharedEvent>> sharedEvents(String familyId, DateTime from, DateTime to) => _guard(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/external-events',
            queryParameters: {'from': from.toUtc().toIso8601String(), 'to': to.toUtc().toIso8601String()});
        return [for (final e in res.data!) SharedEvent.fromJson(e as Map<String, dynamic>)];
      });

  @override
  Future<void> share(String familyId, List<Map<String, dynamic>> events) =>
      _guard(() => _api.dio.put<dynamic>('/api/v1/families/$familyId/external-events', data: {'events': events}));

  @override
  Future<void> stopSharing(String familyId) => _guard(() => _api.dio.delete<dynamic>('/api/v1/families/$familyId/external-events'));

  @override
  Future<bool> feedActive(String familyId) => _guard(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/calendar-feed');
        return res.data!['active'] as bool? ?? false;
      });

  @override
  Future<FeedLink> createFeed(String familyId) => _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/calendar-feed');
        return FeedLink(res.data!['url'] as String, res.data!['webcalUrl'] as String);
      });

  @override
  Future<void> revokeFeed(String familyId) => _guard(() => _api.dio.delete<dynamic>('/api/v1/families/$familyId/calendar-feed'));
}

final calendarSyncApiProvider = Provider<CalendarSyncApi>((ref) => HttpCalendarSyncApi(ref.watch(apiClientProvider)));

/// The window that syncs: a week back, three months ahead.
({DateTime from, DateTime to}) syncWindow(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return (from: DateTime(today.year, today.month, today.day - 7), to: DateTime(today.year, today.month, today.day + 90));
}

const hallyCalendarColor = '#AD5268';
const maxSharedEvents = 2000;

/// Runs one sync: shares the family calendars' events, then writes Hally events into the phone's "Hally" calendar.
class CalendarSyncService {
  CalendarSyncService(this._ref);

  final Ref _ref;
  Future<void>? _running;
  DateTime? _lastRun;

  static const minInterval = Duration(minutes: 5);

  /// Skips quietly when nothing is set up, access is missing or a sync ran a moment ago (unless [force]).
  Future<void> run({bool force = false}) {
    if (_running != null) return _running!;
    if (!force && _lastRun != null && DateTime.now().difference(_lastRun!) < minInterval) return Future.value();
    final future = _run().whenComplete(() => _running = null);
    _running = future;
    return future;
  }

  Future<void> _run() async {
    final me = await _ref.read(meProvider.future);
    final familyId = me?.primaryFamily?.id;
    if (me == null || familyId == null || me.primaryFamily!.isCaregiver) return;
    var settings = await _ref.read(calendarSyncSettingsProvider.future);
    if (settings == null || (settings.isEmpty && !settings.sharedBefore && settings.hallyCalendarId == null)) return;
    final phone = _ref.read(phoneCalendarGatewayProvider);
    if (await phone.access() != CalendarAccess.granted) return;
    _lastRun = DateTime.now();
    final window = syncWindow(DateTime.now());

    try {
      settings = await _share(settings, familyId, phone, window.from, window.to);
    } catch (_) {
      // Offline or server error: the next sync sends the full set again.
    }
    try {
      settings = await _export(settings!, familyId, phone, window.from, window.to);
    } catch (_) {}
    await _ref.read(calendarSyncSettingsProvider.notifier).save(settings!.copyWith(lastSync: DateTime.now()));
  }

  Future<CalendarSyncSettings> _share(CalendarSyncSettings s, String familyId, PhoneCalendarGateway phone, DateTime from, DateTime to) async {
    final api = _ref.read(calendarSyncApiProvider);
    final calendars = {for (final c in await phone.calendars()) c.id: c};
    final ids = [for (final id in s.familyCalendarIds) if (calendars.containsKey(id) && id != s.hallyCalendarId) id];
    if (ids.isEmpty) {
      if (s.sharedBefore) await api.stopSharing(familyId);
      return s.copyWith(sharedBefore: false);
    }
    final events = await phone.events(from, to, ids);
    final payload = [
      for (final e in events.take(maxSharedEvents))
        {
          'sourceKey': _clip('${e.calendarId}|${e.eventId}|${e.start.toUtc().millisecondsSinceEpoch}', 200),
          'provider': calendars[e.calendarId]!.provider.api,
          'calendarName': _clip(calendars[e.calendarId]!.name.trim().isEmpty ? '-' : calendars[e.calendarId]!.name.trim(), 100),
          'title': s.busyOnly ? null : _clip(e.title, 200),
          'busyOnly': s.busyOnly,
          'startsAt': e.start.toUtc().toIso8601String(),
          'endsAt': (e.end.isBefore(e.start) ? e.start : e.end).toUtc().toIso8601String(),
          'allDay': e.allDay,
          'colorHex': _color(calendars[e.calendarId]!.colorHex),
        },
    ];
    await api.share(familyId, payload);
    return s.copyWith(sharedBefore: true);
  }

  Future<CalendarSyncSettings> _export(CalendarSyncSettings s, String familyId, PhoneCalendarGateway phone, DateTime from, DateTime to) async {
    final existing = {for (final c in await phone.calendars()) c.id};
    if (!s.exportEnabled) {
      if (s.hallyCalendarId case final id? when existing.contains(id)) await phone.deleteCalendar(id);
      return s.copyWith(hallyCalendarId: null, exported: const {});
    }

    var calendarId = s.hallyCalendarId;
    var exported = Map.of(s.exported);
    if (calendarId == null || !existing.contains(calendarId)) {
      // First run, or the user deleted the calendar on the phone: start over.
      calendarId = await phone.createCalendar('Hally', hallyCalendarColor);
      exported = {};
    }

    final events = await _ref.read(planningRepositoryProvider).events(familyId, from, to);
    final wanted = <String, EventItem>{
      for (final e in events)
        if (s.exportChildId == null || e.childIds.contains(s.exportChildId)) exportKey(e): e,
    };
    for (final key in exported.keys.toList()) {
      final e = wanted[key];
      if (e == null || exported[key]!.fingerprint != exportFingerprint(e)) {
        try {
          await phone.deleteEvent(exported[key]!.phoneId);
        } catch (_) {}
        exported.remove(key);
      }
    }
    for (final entry in wanted.entries) {
      if (exported.containsKey(entry.key)) continue;
      final e = entry.value;
      final start = e.allDay ? DateTime(e.startsAt.year, e.startsAt.month, e.startsAt.day) : e.startsAt;
      final end = e.allDay
          ? DateTime(start.year, start.month, start.day + 1)
          : (e.endsAt != null && e.endsAt!.isAfter(e.startsAt) ? e.endsAt! : e.startsAt.add(const Duration(hours: 1)));
      final id = await phone.createEvent(calendarId, title: e.title, start: start, end: end, allDay: e.allDay, location: e.location);
      exported[entry.key] = ExportedEvent(id, exportFingerprint(e));
    }
    return s.copyWith(hallyCalendarId: calendarId, exported: exported);
  }

  /// Stops everything on this phone: forgets the calendars, clears what was shared and removes the "Hally" calendar.
  Future<void> disconnect() async {
    final familyId = (await _ref.read(meProvider.future))?.primaryFamily?.id;
    final s = await _ref.read(calendarSyncSettingsProvider.future);
    if (familyId == null || s == null) return;
    try {
      await _ref.read(calendarSyncApiProvider).stopSharing(familyId);
    } catch (_) {}
    if (s.hallyCalendarId case final id?) {
      try {
        await _ref.read(phoneCalendarGatewayProvider).deleteCalendar(id);
      } catch (_) {}
    }
    await _ref.read(calendarSyncSettingsProvider.notifier).save(CalendarSyncSettings(familyId: s.familyId, inviteDone: true, feedUrl: s.feedUrl));
  }

  static String _clip(String v, int max) => v.length > max ? v.substring(0, max) : v;

  static String? _color(String? hex) {
    if (hex == null) return null;
    final h = hex.startsWith('#') ? hex.substring(1) : hex;
    final rgb = h.length == 8 ? h.substring(2) : h; // ARGB from some Android calendars
    return RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(rgb) ? '#${rgb.toUpperCase()}' : null;
  }
}

/// One occurrence of a Hally event (series share an id, so the start is part of the key).
String exportKey(EventItem e) => '${e.id}|${e.startsAt.toUtc().toIso8601String()}';

String exportFingerprint(EventItem e) =>
    [e.title, e.startsAt.toUtc().toIso8601String(), e.endsAt?.toUtc().toIso8601String() ?? '', e.allDay, e.location ?? ''].join('\u0001');

final calendarSyncServiceProvider = Provider<CalendarSyncService>((ref) => CalendarSyncService(ref));

/// A phone or shared event shown in Hally's calendar next to Hally's own events. Never editable in Hally.
class OutsideEvent {
  const OutsideEvent({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.provider,
    required this.calendarName,
    required this.mine,
    this.mode = ShareMode.family,
    this.ownerName,
    this.busyOnly = false,
    this.colorHex,
    this.instanceId,
  });

  final String? title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final CalendarProvider provider;
  final String calendarName;

  /// From this phone (read live); otherwise shared by another parent.
  final bool mine;
  final ShareMode mode;
  final String? ownerName;
  final bool busyOnly;
  final String? colorHex;
  final String? instanceId;
}

/// Outside events for a calendar range: this phone's selected calendars (read live, so "only me" never leaves the
/// phone) plus what the other parents shared. Empty when nothing is set up or anything fails.
final outsideEventsProvider = FutureProvider.autoDispose.family<List<OutsideEvent>, CalendarRange>((ref, range) async {
  if (ref.watch(isCaregiverProvider)) return const [];
  final settings = await ref.watch(calendarSyncSettingsProvider.future);
  if (settings == null) return const [];
  final result = <OutsideEvent>[];

  if (settings.calendars.isNotEmpty) {
    final phone = ref.watch(phoneCalendarGatewayProvider);
    try {
      if (await phone.access() == CalendarAccess.granted) {
        final calendars = {for (final c in await phone.calendars()) c.id: c};
        final ids = [for (final id in settings.calendars.keys) if (calendars.containsKey(id) && id != settings.hallyCalendarId) id];
        for (final e in await phone.events(range.from, range.to, ids)) {
          final c = calendars[e.calendarId]!;
          result.add(OutsideEvent(
            title: e.title,
            start: e.start,
            end: e.end,
            allDay: e.allDay,
            provider: c.provider,
            calendarName: c.name,
            mine: true,
            mode: settings.calendars[c.id]!,
            colorHex: c.colorHex,
            instanceId: e.instanceId,
          ));
        }
      }
    } catch (_) {}
  }

  try {
    for (final e in await ref.watch(calendarSyncApiProvider).sharedEvents(range.familyId, range.from, range.to)) {
      if (e.mine) continue; // shown live from the phone above
      result.add(OutsideEvent(
        title: e.title,
        start: e.startsAt,
        end: e.endsAt,
        allDay: e.allDay,
        provider: e.provider,
        calendarName: e.calendarName,
        mine: false,
        ownerName: e.ownerName,
        busyOnly: e.busyOnly,
        colorHex: e.colorHex,
      ));
    }
  } catch (_) {}
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
});

/// Whether the phone has a calendar plugin at all (false in tests and on unsupported platforms).
final phoneCalendarAvailableProvider = FutureProvider.autoDispose<bool>(
    (ref) async => await ref.watch(phoneCalendarGatewayProvider).access() != CalendarAccess.unavailable);
