import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../l10n/gen/app_localizations.dart';

/// Current weather where the family lives (only when a parent picked a city).
class ActivityWeather {
  const ActivityWeather({required this.temperatureC, required this.sky, this.isDay = true});

  factory ActivityWeather.fromJson(Map<String, dynamic> j) =>
      ActivityWeather(temperatureC: (j['temperatureC'] as num).toInt(), sky: j['sky'] as String, isDay: j['isDay'] as bool? ?? true);

  final int temperatureC;

  /// Clear, Cloudy, Rain, Snow or Storm.
  final String sky;
  final bool isDay;

  String get emoji => switch (sky) {
        'Clear' => isDay ? '☀️' : '🌙',
        'Cloudy' => '☁️',
        'Rain' => '🌧️',
        'Snow' => '❄️',
        'Storm' => '⛈️',
        _ => '🌤️',
      };

  String label(AppLocalizations l10n) => switch (sky) {
        'Clear' => isDay ? l10n.actClear : l10n.actClearNight,
        'Cloudy' => l10n.actCloudy,
        'Rain' => l10n.actRain,
        'Snow' => l10n.actSnow,
        'Storm' => l10n.actStorm,
        _ => sky,
      };
}

class ActivityIdea {
  const ActivityIdea({
    required this.id,
    required this.emoji,
    required this.title,
    this.hint,
    required this.place,
    this.minutes,
    required this.cherries,
    this.own = false,
    this.state = 'Todo',
  });

  factory ActivityIdea.fromJson(Map<String, dynamic> j) => ActivityIdea(
        id: j['id'] as String,
        emoji: j['emoji'] as String,
        title: j['title'] as String,
        hint: j['hint'] as String?,
        place: j['place'] as String,
        minutes: (j['minutes'] as num?)?.toInt(),
        cherries: (j['cherries'] as num).toInt(),
        own: j['own'] as bool? ?? false,
        state: j['state'] as String? ?? 'Todo',
      );

  final String id;
  final String emoji;
  final String title;
  final String? hint;

  /// Indoor or Outdoor.
  final String place;
  final int? minutes;
  final int cherries;
  final bool own;

  /// Todo, Pending or Done (today).
  final String state;

  bool get outdoor => place == 'Outdoor';
  bool get isTodo => state == 'Todo';
}

class ChildActivities {
  const ChildActivities({this.weather, this.weatherPlace, this.age, this.doneToday = 0, this.dailyLimit = 3, this.ideas = const []});

  factory ChildActivities.fromJson(Map<String, dynamic> j) => ChildActivities(
        weather: j['weather'] == null ? null : ActivityWeather.fromJson(j['weather'] as Map<String, dynamic>),
        weatherPlace: j['weatherPlace'] as String?,
        age: (j['age'] as num?)?.toInt(),
        doneToday: (j['doneToday'] as num?)?.toInt() ?? 0,
        dailyLimit: (j['dailyLimit'] as num?)?.toInt() ?? 3,
        ideas: [for (final i in j['ideas'] as List) ActivityIdea.fromJson(i as Map<String, dynamic>)],
      );

  final ActivityWeather? weather;
  final String? weatherPlace;
  final int? age;
  final int doneToday;
  final int dailyLimit;
  final List<ActivityIdea> ideas;

  bool get limitReached => doneToday >= dailyLimit;
}

// ─── Parent side ──────────────────────────────────────────────────────────────

class WeatherPlace {
  const WeatherPlace({required this.name, this.region, this.country, required this.latitude, required this.longitude});

  factory WeatherPlace.fromJson(Map<String, dynamic> j) => WeatherPlace(
        name: j['name'] as String,
        region: j['region'] as String?,
        country: j['country'] as String?,
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
      );

  final String name;
  final String? region;
  final String? country;
  final double latitude;
  final double longitude;

  /// "Çankaya · Ankara, Türkiye" style second line for the search list.
  String get detail => [if (region != null && region != name) region, if (country != null) country].join(', ');
}

class OwnActivity {
  const OwnActivity({required this.id, required this.emoji, required this.title, required this.place, required this.cherries});

  factory OwnActivity.fromJson(Map<String, dynamic> j) => OwnActivity(
        id: j['id'] as String,
        emoji: j['emoji'] as String,
        title: j['title'] as String,
        place: j['place'] as String,
        cherries: (j['cherries'] as num).toInt(),
      );

  final String id;
  final String emoji;
  final String title;
  final String place;
  final int cherries;
}

class FamilyActivities {
  const FamilyActivities({this.place, this.own = const [], this.builtIn = 0});

  factory FamilyActivities.fromJson(Map<String, dynamic> j) => FamilyActivities(
        place: j['place'] == null ? null : WeatherPlace.fromJson(j['place'] as Map<String, dynamic>),
        own: [for (final o in j['own'] as List) OwnActivity.fromJson(o as Map<String, dynamic>)],
        builtIn: (j['builtIn'] as num?)?.toInt() ?? 0,
      );

  final WeatherPlace? place;
  final List<OwnActivity> own;
  final int builtIn;
}

abstract interface class ActivitiesRepository {
  Future<FamilyActivities> load(String familyId);
  Future<void> add(String familyId, {required String title, required String emoji, required int cherries, required bool outdoor});
  Future<void> delete(String familyId, String id);
  Future<void> setPlace(String familyId, WeatherPlace? place);
  Future<List<WeatherPlace>> searchPlaces(String query, String lang);
}

class ApiActivitiesRepository implements ActivitiesRepository {
  ApiActivitiesRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _f(String familyId) => '/api/v1/families/$familyId';

  @override
  Future<FamilyActivities> load(String familyId) =>
      _call(() async => FamilyActivities.fromJson((await _api.dio.get<Map<String, dynamic>>('${_f(familyId)}/activities')).data!));

  @override
  Future<void> add(String familyId, {required String title, required String emoji, required int cherries, required bool outdoor}) => _call(() => _api.dio
      .post<dynamic>('${_f(familyId)}/activities', data: {'title': title, 'emoji': emoji, 'cherries': cherries, 'place': outdoor ? 'Outdoor' : 'Indoor'}));

  @override
  Future<void> delete(String familyId, String id) => _call(() => _api.dio.delete<dynamic>('${_f(familyId)}/activities/$id'));

  @override
  Future<void> setPlace(String familyId, WeatherPlace? place) => _call(
      () => _api.dio.put<dynamic>('${_f(familyId)}/weather-place', data: {'name': place?.name, 'latitude': place?.latitude, 'longitude': place?.longitude}));

  @override
  Future<List<WeatherPlace>> searchPlaces(String query, String lang) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/weather/places', queryParameters: {'q': query, 'lang': lang});
        return [for (final p in res.data ?? const []) WeatherPlace.fromJson(p as Map<String, dynamic>)];
      });
}

final activitiesRepositoryProvider = Provider<ActivitiesRepository>((ref) => ApiActivitiesRepository(ref.watch(apiClientProvider)));

final familyActivitiesProvider =
    FutureProvider.autoDispose.family<FamilyActivities, String>((ref, familyId) => ref.watch(activitiesRepositoryProvider).load(familyId));
