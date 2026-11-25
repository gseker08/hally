import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../bedtime/bedtime.dart';

/// One line of "Bugün ne var?": `📅 16:00 Yüzme (Ela)`.
class BriefingLine {
  const BriefingLine({required this.kind, required this.emoji, required this.text});

  factory BriefingLine.fromJson(Map<String, dynamic> j) =>
      BriefingLine(kind: j['kind'] as String? ?? 'Event', emoji: j['emoji'] as String? ?? '•', text: j['text'] as String);

  final String kind;
  final String emoji;
  final String text;
}

/// The day read aloud. Built by the server from the family's own data, so it needs no AI key and no AI consent.
class Briefing {
  const Briefing({required this.tomorrow, required this.greeting, required this.lines, required this.speech, required this.shortSpeech});

  factory Briefing.fromJson(Map<String, dynamic> j) => Briefing(
        tomorrow: j['day'] == 'tomorrow',
        greeting: j['greeting'] as String,
        lines: [for (final l in (j['lines'] as List? ?? const [])) BriefingLine.fromJson(l as Map<String, dynamic>)],
        speech: j['speech'] as String,
        shortSpeech: j['shortSpeech'] as String,
      );

  final bool tomorrow;
  final String greeting;
  final List<BriefingLine> lines;

  /// Everything, without emoji, for the phone's voice.
  final String speech;

  /// "Daha kısa": the greeting and the counts.
  final String shortSpeech;
}

/// Which day a message asks about, or null when it is a question for the AI.
///
/// Only short, plain day questions count ("Bugün ne var?", "yarın neler var", "What's on tomorrow?"), so
/// "Bu hafta ne var?" or "Yarın ne lazım?" still go to the assistant.
enum BriefingDay { today, tomorrow }

BriefingDay? briefingDayOf(String text) {
  final t = text.trim().toLowerCase().replaceAll(RegExp(r'[?!.,]'), '').replaceAll(RegExp(r'\s+'), ' ');
  if (t.length > 40) return null;
  final tr = RegExp(r'^(hally )?(bugün|yarın)(ki)?( için| programda| takvimde)? (ne|neler) (var|varmış)( hally)?$').firstMatch(t);
  if (tr != null) return tr.group(2) == 'bugün' ? BriefingDay.today : BriefingDay.tomorrow;
  final en = RegExp(r"^(hally )?(what's|whats|what is) (on |happening |planned )?(for )?(today|tomorrow)( hally)?$").firstMatch(t);
  if (en != null) return en.group(5) == 'today' ? BriefingDay.today : BriefingDay.tomorrow;
  return null;
}

abstract interface class BriefingRepository {
  Future<Briefing> get(String familyId, {required bool tomorrow, required String lang});

  /// "HH:mm", or null when the morning notification is off.
  Future<String?> time(String familyId);
  Future<String?> setTime(String familyId, String? time);
}

class ApiBriefingRepository implements BriefingRepository {
  ApiBriefingRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<Briefing> get(String familyId, {required bool tomorrow, required String lang}) => _call(() async {
        final res = await _api.dio
            .get<Map<String, dynamic>>('/api/v1/families/$familyId/briefing', queryParameters: {'day': tomorrow ? 'tomorrow' : 'today', 'lang': lang});
        return Briefing.fromJson(res.data!);
      });

  @override
  Future<String?> time(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/briefing/settings');
        return res.data!['time'] as String?;
      });

  @override
  Future<String?> setTime(String familyId, String? time) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/briefing/settings', data: {'time': time});
        return res.data!['time'] as String?;
      });
}

final briefingRepositoryProvider = Provider<BriefingRepository>((ref) => ApiBriefingRepository(ref.watch(apiClientProvider)));

/// The phone's own Turkish/English voice, a little brisker than the bedtime story.
final briefingSpeakerProvider = Provider<StorySpeaker>((ref) => TtsStorySpeaker(rate: 0.5));
