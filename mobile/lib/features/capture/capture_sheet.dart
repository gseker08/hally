import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/analytics/analytics.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../billing/paywall_screen.dart';
import '../privacy/ai_consent.dart';
import 'capture_models.dart';
import 'capture_repository.dart';
import 'quick_log.dart';

/// Bottom sheet opened by the central "Ekle" button: let Hally capture a photo or message, or log something for a
/// child in one tap.
Future<void> showCaptureSheet(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context);
  final familyId = ref.read(meProvider).valueOrNull?.primaryFamily?.id;
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.addTitle, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: HallySpace.md),
              Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: HallyColors.cherry, size: 18),
                  const SizedBox(width: 6),
                  Text(l10n.addCaptureSection, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 4),
              Text(l10n.captureSubtitle, style: theme.textTheme.bodySmall),
              const SizedBox(height: HallySpace.sm + 2),
              Row(
                children: [
                  Expanded(
                    child: CaptureOption(
                      key: const Key('capture.camera'),
                      icon: Icons.photo_camera_rounded,
                      color: HallyColors.cherry,
                      label: l10n.captureCameraShort,
                      onTap: () => _pick(sheetContext, context, ref, ImageSource.camera, 'Camera'),
                    ),
                  ),
                  const SizedBox(width: HallySpace.sm),
                  Expanded(
                    child: CaptureOption(
                      key: const Key('capture.gallery'),
                      icon: Icons.photo_library_rounded,
                      color: HallyColors.mint,
                      label: l10n.captureGalleryShort,
                      onTap: () => _pick(sheetContext, context, ref, ImageSource.gallery, 'Gallery'),
                    ),
                  ),
                  const SizedBox(width: HallySpace.sm),
                  Expanded(
                    child: CaptureOption(
                      key: const Key('capture.text'),
                      icon: Icons.chat_rounded,
                      color: HallyColors.apricot,
                      label: l10n.captureTextShort2,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        context.push('/capture/text');
                      },
                    ),
                  ),
                ],
              ),
              if (familyId != null) ...[
                const SizedBox(height: HallySpace.lg),
                QuickLog(
                  familyId: familyId,
                  onDone: ({message, route}) {
                    Navigator.of(sheetContext).pop();
                    if (route != null) context.push(route);
                    if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
                  },
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// Starts a photo capture without the sheet (used by the quick actions on Today).
Future<void> startPhotoCapture(BuildContext context, WidgetRef ref, {required bool camera}) => _pick(
      null,
      context,
      ref,
      camera ? ImageSource.camera : ImageSource.gallery,
      camera ? 'Camera' : 'Gallery',
    );

Future<void> _pick(BuildContext? sheetContext, BuildContext context, WidgetRef ref, ImageSource source, String sourceName) async {
  if (sheetContext != null) Navigator.of(sheetContext).pop();
  final file = await ImagePicker().pickImage(source: source, maxWidth: 2400, imageQuality: 85);
  if (file == null || !context.mounted) return;
  final familyId = ref.read(meProvider).valueOrNull?.primaryFamily?.id;
  if (familyId == null) return;

  ref.read(analyticsProvider).track(AnalyticsEvent.captureStarted, {'source': sourceName.toLowerCase()});
  final bytes = await file.readAsBytes();
  final name = file.name.toLowerCase();
  final type = name.endsWith('.png') ? 'image/png' : name.endsWith('.heic') ? 'image/heic' : name.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
  if (!context.mounted) return;
  await runCapture(context, ref, () => ref.read(captureRepositoryProvider).captureImage(familyId, bytes, file.name, type, source: sourceName));
}

/// Shows a progress dialog while the API extracts, then opens the review screen.
Future<void> runCapture(BuildContext context, WidgetRef ref, Future<CaptureResult> Function() action) async {
  if (!await ensureAiConsent(context, ref) || !context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const CaptureProgressDialog(),
  );
  try {
    final result = await action();
    navigator.pop();
    ref.read(lastCaptureProvider.notifier).state = result;
    if (context.mounted) context.push('/capture/review');
  } catch (e) {
    navigator.pop();
    if (context.mounted && !openPaywallIfLimited(context, e)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.captureFailed)));
    }
  }
}

/// Compact capture tile in the add sheet.
class CaptureOption extends StatelessWidget {
  const CaptureOption({super.key, required this.icon, required this.color, required this.label, required this.onTap});

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HallyPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: HallySpace.md - 2, horizontal: 6),
        decoration: BoxDecoration(
          color: HallyColors.softOf(color, theme.brightness),
          borderRadius: BorderRadius.circular(HallyRadius.md + 2),
        ),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(HallyRadius.sm)),
              child: Icon(icon, color: HallyColors.readableOn(color, theme.brightness), size: 22),
            ),
            const SizedBox(height: HallySpace.sm),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// Shown while the API extracts tasks: a breathing gradient orb and rotating status lines.
class CaptureProgressDialog extends StatefulWidget {
  const CaptureProgressDialog({super.key});

  @override
  State<CaptureProgressDialog> createState() => _CaptureProgressDialogState();
}

class _CaptureProgressDialogState extends State<CaptureProgressDialog> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1800), (_) => setState(() => _step = (_step + 1) % 3));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final steps = [l10n.captureStepRead, l10n.captureStepDates, l10n.captureStepTasks];
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.xl, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) {
                final t = Curves.easeInOut.transform(_pulse.value);
                return Transform.scale(
                  scale: 0.92 + t * 0.12,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: HallyGradients.magic,
                      boxShadow: [BoxShadow(color: HallyColors.rose.withValues(alpha: 0.25 + t * 0.25), blurRadius: 20 + t * 20)],
                    ),
                    child: child,
                  ),
                );
              },
              child: const Icon(Icons.auto_awesome, color: Colors.white, size: 38),
            ),
            const SizedBox(height: HallySpace.lg),
            Text(l10n.captureWorking, style: theme.textTheme.titleLarge),
            const SizedBox(height: HallySpace.sm),
            AnimatedSwitcher(
              duration: HallyMotion.medium,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a), child: child),
              ),
              child: Text(steps[_step], key: ValueKey(_step), style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(height: HallySpace.lg),
            ClipRRect(
              borderRadius: BorderRadius.circular(HallyRadius.pill),
              child: const LinearProgressIndicator(minHeight: 6),
            ),
          ],
        ),
      ),
    );
  }
}
