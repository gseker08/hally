# Languages

Hally speaks Turkish (template), English, German, Japanese, Korean and Chinese (Simplified; iOS folder `zh-Hans.lproj`). A phone in another language gets English; Turkish stays the
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

Server (backend/):

1. Add the code to `Locales.Supported` and `Locales.EnglishName` (`Hally.Domain/Users/User.cs`).
2. `Hally.Domain/Localization/<code>.json`: every key of `en.json`. These are the pushes, the morning summary, the
   helper page, the weekly card, built-in screen-free ideas and "Bir şey iste" requests. `Texts.Get(locale, key,
   ("name", value))` fills `{name}`; `Texts.Plural` picks `key.one` / `key.other`. `format.*` keys are .NET date
   patterns. A missing key falls back to English, and a test checks every language has every key and placeholder.
3. If the language has its own words for "exam", add them to `ExamTexts.ExamWord` so scanned notes become exams.
   Languages without spaces (Japanese, Chinese) and Korean go after the `\b(...)\b` group, since word boundaries do not work there.
4. The weekly PNG card (`SummaryCard`) only bundles Latin fonts. Languages in other scripts get the card in English
   (`SummaryCard.CardLocale`) until a font for that script is bundled.

Translations are machine-made and should be read by a native speaker before a store release.

## Layout

German words are long. Run the widget tests with `Locale('de')` to catch overflowing rows; the ones found so far
were fixed with shorter labels or `Flexible` text.
