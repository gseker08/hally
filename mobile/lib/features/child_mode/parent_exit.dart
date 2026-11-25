import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import 'child_lock.dart';
import 'child_mode_repository.dart';

/// How long a parent holds the child's name before "Ebeveyn çıkışı" opens. Long enough that a child does not find it by
/// accident; nothing on the screen says it is there.
const parentExitHold = Duration(seconds: 3);

/// The hidden way out of child mode: holding [child] for [parentExitHold] asks for the parents' PIN.
class ParentExitGesture extends StatelessWidget {
  const ParentExitGesture({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
        key: const Key('kid.parentExit'),
        behavior: HitTestBehavior.opaque,
        gestures: {
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: parentExitHold),
            (r) => r.onLongPress = () {
              HapticFeedback.heavyImpact();
              showParentExitSheet(context);
            },
          ),
        },
        child: child,
      );
}

Future<void> showParentExitSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ParentExitSheet(),
    );

class _ParentExitSheet extends ConsumerStatefulWidget {
  const _ParentExitSheet();

  @override
  ConsumerState<_ParentExitSheet> createState() => _ParentExitSheetState();
}

class _ParentExitSheetState extends ConsumerState<_ParentExitSheet> {
  final _pad = GlobalKey<PinPadState>();
  String? _error;
  bool _busy = false;

  Future<void> _submit(String pin) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(childApiProvider).exit(pin);
      HapticFeedback.mediumImpact();
      await ref.read(childLockProvider).stop();
      if (mounted) Navigator.of(context).pop();
      // No session any more: the router goes back to the start screen.
      ref.invalidate(childSessionProvider);
    } on ChildExitException catch (e) {
      HapticFeedback.vibrate();
      setState(() => _error = e.wrong
          ? l10n.kidExitWrong(e.triesLeft ?? 0)
          : e.blocked
              ? l10n.kidExitBlocked
              : l10n.kidExitNoPin);
      _pad.currentState?.clear();
    } catch (_) {
      setState(() => _error = l10n.errorGeneric);
      _pad.currentState?.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.kidExitTitle, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(l10n.kidExitBody, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: HallySpace.md),
            PinPad(key: _pad, enabled: !_busy, error: _error, onComplete: _submit),
            const SizedBox(height: HallySpace.md),
            Text(l10n.kidExitHelp, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Four dots and a number pad. Calls [onComplete] when four digits are in.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onComplete, this.enabled = true, this.error, this.hint});

  final ValueChanged<String> onComplete;
  final bool enabled;
  final String? error;
  final String? hint;

  static const length = 4;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _pin = '';

  void clear() => setState(() => _pin = '');

  void _tap(String digit) {
    if (!widget.enabled || _pin.length >= PinPad.length) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += digit);
    if (_pin.length == PinPad.length) widget.onComplete(_pin);
  }

  void _back() {
    if (!widget.enabled || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final ink = HallyColors.accent(HallyColors.cherry, b);
    final message = widget.error ?? widget.hint;
    Widget key(String label, {Key? k, VoidCallback? onTap, Widget? child}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Material(
              color: onTap == null ? Colors.transparent : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(HallyRadius.md),
              child: InkWell(
                key: k,
                borderRadius: BorderRadius.circular(HallyRadius.md),
                onTap: onTap,
                child: SizedBox(
                  height: 56,
                  child: Center(child: child ?? Text(label, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
                ),
              ),
            ),
          ),
        );
    Widget digit(String d) => key(d, k: Key('pin.$d'), onTap: () => _tap(d));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          key: const Key('pin.dots'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < PinPad.length; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 18,
                height: 18,
                decoration: BoxDecoration(shape: BoxShape.circle, color: i < _pin.length ? ink : null, border: Border.all(color: ink, width: 2.5)),
              ),
          ],
        ),
        const SizedBox(height: HallySpace.sm),
        SizedBox(
          height: 36,
          child: message == null
              ? null
              : Text(message,
                  key: const Key('pin.message'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: widget.error != null ? ink : theme.colorScheme.onSurfaceVariant, fontWeight: widget.error != null ? FontWeight.w700 : null)),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(children: [for (final d in row) digit(d)]),
        Row(children: [
          key(''),
          digit('0'),
          key('', k: const Key('pin.back'), onTap: _back, child: const Icon(Icons.backspace_outlined)),
        ]),
      ],
    );
  }
}

/// A parent sets (or changes) the exit PIN: typed twice.
Future<bool?> showSetExitPinSheet(BuildContext context, String familyId) => showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SetExitPinSheet(familyId: familyId),
    );

class _SetExitPinSheet extends ConsumerStatefulWidget {
  const _SetExitPinSheet({required this.familyId});

  final String familyId;

  @override
  ConsumerState<_SetExitPinSheet> createState() => _SetExitPinSheetState();
}

class _SetExitPinSheetState extends ConsumerState<_SetExitPinSheet> {
  final _pad = GlobalKey<PinPadState>();
  String? _first;
  String? _error;
  bool _busy = false;

  Future<void> _entered(String pin) async {
    final l10n = AppLocalizations.of(context);
    if (_first == null) {
      setState(() {
        _first = pin;
        _error = null;
      });
      _pad.currentState?.clear();
      return;
    }
    if (pin != _first) {
      setState(() {
        _first = null;
        _error = l10n.exitPinMismatch;
      });
      _pad.currentState?.clear();
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(childModeRepositoryProvider).setExitPin(widget.familyId, pin);
      ref.invalidate(childExitPinProvider(widget.familyId));
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      setState(() {
        _busy = false;
        _first = null;
        _error = l10n.errorGeneric;
      });
      _pad.currentState?.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_first == null ? l10n.exitPinNew : l10n.exitPinRepeat, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: HallySpace.md),
            PinPad(key: _pad, enabled: !_busy, error: _error, hint: _first == null ? l10n.exitPinNewHint : null, onComplete: _entered),
          ],
        ),
      ),
    );
  }
}
