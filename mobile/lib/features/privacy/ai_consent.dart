import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/token_storage.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'privacy_repository.dart';

/// Whether the user agreed that photos, text and assistant messages are sent to the AI provider.
///
/// App Store guideline 5.1.2(i) and KVKK ask for clear disclosure and permission before personal data
/// (here possibly about children) goes to a third-party AI service. The answer is kept on the device
/// next to the tokens, and can be withdrawn on the privacy screen.
abstract interface class AiConsentStorage {
  Future<bool> read();
  Future<void> write(bool granted);
}

class SecureAiConsentStorage implements AiConsentStorage {
  SecureAiConsentStorage([FlutterSecureStorage? storage]) : _storage = storage ?? hallySecureStorage;

  static const _key = 'hally.ai_consent';
  final FlutterSecureStorage _storage;

  @override
  Future<bool> read() async {
    try {
      return await _storage.read(key: _key) != null;
    } catch (_) {
      return false; // Unreadable: ask again rather than assume a yes.
    }
  }

  @override
  Future<void> write(bool granted) => granted
      ? _storage.write(key: _key, value: DateTime.now().toUtc().toIso8601String())
      : _storage.delete(key: _key);
}

final aiConsentStorageProvider = Provider<AiConsentStorage>((ref) => SecureAiConsentStorage());

class AiConsentController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref.watch(aiConsentStorageProvider).read();

  Future<void> set(bool granted) async {
    await ref.read(aiConsentStorageProvider).write(granted);
    state = AsyncData(granted);
  }
}

final aiConsentProvider = AsyncNotifierProvider<AiConsentController, bool>(AiConsentController.new);

/// Call before anything that sends the user's content to the AI provider. Returns true when the user already
/// agreed or agrees now; false means "do not send".
Future<bool> ensureAiConsent(BuildContext context, WidgetRef ref) async {
  if (await ref.read(aiConsentProvider.future)) return true;
  String? provider;
  try {
    provider = (await ref.read(privacyInfoProvider.future)).aiProviderName;
  } catch (_) {
    // Offline: the sheet still explains what happens, just without the provider's name.
  }
  if (!context.mounted) return false;
  final agreed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AiConsentSheet(providerName: provider),
  );
  if (agreed != true) return false;
  await ref.read(aiConsentProvider.notifier).set(true);
  return true;
}

class AiConsentSheet extends StatelessWidget {
  const AiConsentSheet({super.key, this.providerName});

  final String? providerName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final points = [
      (Icons.cloud_upload_rounded, providerName == null ? l10n.aiConsentWhat : l10n.aiConsentWhatNamed(providerName!)),
      (Icons.child_care_rounded, l10n.aiConsentChildren),
      (Icons.block_rounded, l10n.aiConsentNoAds),
      (Icons.undo_rounded, l10n.aiConsentWithdraw),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.lg, HallySpace.lg, HallySpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.aiConsentTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.md),
          for (final (icon, text) in points)
            Padding(
              padding: const EdgeInsets.only(bottom: HallySpace.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HallyIconBadge(icon: icon, color: HallyColors.sky, size: 36),
                  const SizedBox(width: HallySpace.md),
                  Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
          const SizedBox(height: HallySpace.md),
          FilledButton(
            key: const Key('aiConsent.accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.aiConsentAccept),
          ),
          TextButton(
            key: const Key('aiConsent.decline'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.aiConsentDecline),
          ),
        ],
      ),
    );
  }
}
