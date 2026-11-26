import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/auth_repository.dart';
import '../auth/token_storage.dart';

/// The language the user picked in settings. [system] follows the device, with Turkish as the fallback.
enum AppLanguage {
  system(null),
  tr('tr'),
  en('en'),
  de('de'),
  ja('ja');

  const AppLanguage(this.code);

  /// Language code, or null for "follow the device".
  final String? code;

  Locale? get locale => code == null ? null : Locale(code!);

  static AppLanguage fromCode(String? code) =>
      AppLanguage.values.firstWhere((l) => l.code != null && l.code == code, orElse: () => AppLanguage.system);
}

const supportedLanguageCodes = ['tr', 'en', 'de', 'ja'];

/// Picks a supported language for a device locale. A phone in a language Hally does not speak gets English.
Locale resolveDeviceLocale(Locale? device) =>
    supportedLanguageCodes.contains(device?.languageCode) ? Locale(device!.languageCode) : const Locale('en');

/// The speech recognizer / text-to-speech locale for an app language, e.g. tr_TR.
String speechLocaleFor(String languageCode) => switch (languageCode) {
      'tr' => 'tr_TR',
      'de' => 'de_DE',
      'ja' => 'ja_JP',
      _ => 'en_US',
    };

/// The time zone suggested when a family is created; the user can change it there.
String defaultTimeZoneFor(String languageCode) => switch (languageCode) {
      'tr' => 'Europe/Istanbul',
      'de' => 'Europe/Berlin',
      'ja' => 'Asia/Tokyo',
      _ => 'Europe/London',
    };

/// Where the choice is kept between launches. It sits next to the tokens in the platform keystore,
/// so no extra plugin is needed.
abstract interface class LanguageStorage {
  Future<AppLanguage> read();
  Future<void> write(AppLanguage language);
}

class SecureLanguageStorage implements LanguageStorage {
  SecureLanguageStorage([FlutterSecureStorage? storage]) : _storage = storage ?? hallySecureStorage;

  static const _key = 'hally.language';
  final FlutterSecureStorage _storage;

  @override
  Future<AppLanguage> read() async {
    try {
      return AppLanguage.fromCode(await _storage.read(key: _key));
    } catch (_) {
      return AppLanguage.system; // An unreadable value must never block app start.
    }
  }

  @override
  Future<void> write(AppLanguage language) => language.code == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: language.code);
}

final languageStorageProvider = Provider<LanguageStorage>((ref) => SecureLanguageStorage());

/// The stored choice, read once in main() before the first frame so the app never flashes the wrong language.
final initialLanguageProvider = Provider<AppLanguage>((ref) => AppLanguage.system);

/// Device locale used when the choice is [AppLanguage.system]. Overridable in tests.
final deviceLocaleProvider = Provider<Locale>((ref) => PlatformDispatcher.instance.locale);

class LanguageController extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => ref.watch(initialLanguageProvider);

  /// Saves the choice, then tells the server so reminders and other pushes use the same language.
  Future<void> set(AppLanguage language) async {
    state = language;
    await ref.read(languageStorageProvider).write(language);
    final code = language.code ?? resolveDeviceLocale(ref.read(deviceLocaleProvider)).languageCode;
    try {
      final me = await ref.read(meProvider.future);
      if (me != null && me.locale != code) {
        await ref.read(authRepositoryProvider).updateLocale(me.displayName, code);
        ref.invalidate(meProvider);
      }
    } catch (_) {
      // Offline or signed out: the app language still changes; the server catches up on the next change.
    }
  }
}

final languageProvider = NotifierProvider<LanguageController, AppLanguage>(LanguageController.new);
