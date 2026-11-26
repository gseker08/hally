# Languages

Hally speaks Turkish (template), English and German. A phone in another language gets English; Turkish stays the
default when the server gets no language at all (old clients).

## Adding a language

App (mobile/):

1. `lib/l10n/app_<code>.arb`: every key of `app_en.arb`. Keep `{placeholders}` and ICU plurals as they are; the
   `examsSubjects`, `timetableSubjects` and `timetableItems` lists use `|` and may have a different count.
2. `lib/core/locale/app_language.dart`: the `AppLanguage` value, `supportedLanguageCodes`, `speechLocaleFor`
   (speech recognizer / text-to-speech) and `defaultTimeZoneFor`.
3. `lib/core/locale/units.dart`: short hour/minute units.
4. `lib/features/family/language_sheet.dart`: the language's name, written in that language.
5. `lib/features/bedtime/bedtime.dart`: bedtime stories (English is used when a language has none).
6. Android `res/values-<code>/strings.xml` (home-screen widgets, child-mode lock overlay).
7. iOS `Runner/<code>.lproj/InfoPlist.strings` (permission texts), `CFBundleLocalizations` in `Info.plist`
   and the language in `knownRegions` of `Runner.xcodeproj`.

Server (backend/): add the code to `Locales.Supported` (`Hally.Domain/Users/User.cs`). Until the server texts
have the language, pushes, the morning summary and built-in ideas for it are in English.

Translations are machine-made and should be read by a native speaker before a store release.

## Layout

German words are long. Run the widget tests with `Locale('de')` to catch overflowing rows; the ones found so far
were fixed with shorter labels or `Flexible` text.
