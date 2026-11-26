import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';

/// Language names are written in their own language so they can be found whatever the current language is.
String languageLabel(AppLocalizations l10n, AppLanguage language) => switch (language) {
      AppLanguage.system => l10n.languageSystem,
      AppLanguage.tr => 'Türkçe',
      AppLanguage.en => 'English',
      AppLanguage.de => 'Deutsch',
      AppLanguage.ja => '日本語',
      AppLanguage.ko => '한국어',
      AppLanguage.zh => '中文',
      AppLanguage.pt => 'Português (Brasil)',
      AppLanguage.hi => 'हिन्दी',
      AppLanguage.id => 'Bahasa Indonesia',
    };

Future<void> showLanguageSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (_) => const _LanguageSheet(),
    );

class _LanguageSheet extends ConsumerWidget {
  const _LanguageSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(languageProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(l10n.languageTitle, style: Theme.of(context).textTheme.titleLarge),
          ),
          // Nine languages do not fit a short phone's sheet, so the list scrolls.
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
          for (final language in AppLanguage.values)
            ListTile(
              key: Key('language.${language.name}'),
              title: Text(languageLabel(l10n, language)),
              subtitle: language == AppLanguage.system ? Text(l10n.languageSystemBody) : null,
              trailing: language == current ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
              selected: language == current,
              onTap: () {
                ref.read(languageProvider.notifier).set(language);
                Navigator.of(context).pop();
              },
            ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
