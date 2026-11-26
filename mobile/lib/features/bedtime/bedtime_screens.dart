import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../child_mode/child_mode_repository.dart';
import 'bedtime.dart';
import '../../core/locale/units.dart';
import '../child_mode/parent_exit.dart' show ParentExitGesture;

/// The night palette of the bedtime screens (the same in light and dark mode).
abstract final class _Night {
  static const sky = Color(0xFF2C2B45);
  static const skyDeep = Color(0xFF1F1E33);
  static const lavender = Color(0xFFB9AEDB);
  static const text = Color(0xFFE4DDF2);
  static const muted = Color(0xFFC9C0E2);
  static const faint = Color(0x33FFFFFF);
}

String _lang(BuildContext context) => langOf(context);

class _StarrySky extends StatelessWidget {
  const _StarrySky({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration:
            const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_Night.skyDeep, _Night.sky])),
        child: CustomPaint(painter: _StarsPainter(), child: child),
      );
}

class _StarsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(7);
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.7);
    for (var i = 0; i < 28; i++) {
      canvas.drawCircle(Offset(random.nextDouble() * size.width, random.nextDouble() * size.height * 0.6), random.nextDouble() * 1.4 + 0.6, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// "Uykuya hazırlık": the steps in order. The next one glows, later ones wait.
class KidBedtimeScreen extends ConsumerStatefulWidget {
  const KidBedtimeScreen({super.key, required this.bedtime});

  final ChildBedtime bedtime;

  @override
  ConsumerState<KidBedtimeScreen> createState() => _KidBedtimeScreenState();
}

class _KidBedtimeScreenState extends ConsumerState<KidBedtimeScreen> {
  late ChildBedtime _b = widget.bedtime;
  bool _busy = false;

  Future<void> _check(int index) async {
    if (_busy || index != _b.done) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final b = await ref.read(childApiProvider).bedtimeDone(index);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      setState(() => _b = b);
      if (b.finished) ref.invalidate(childHomeProvider);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'bedtime.not_open' ? l10n.bedNotOpen(_b.time) : l10n.errorGeneric)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final steps = _b.steps;
    return Scaffold(
      key: const Key('bed.steps'),
      backgroundColor: _Night.sky,
      body: _StarrySky(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.md, HallySpace.lg, HallySpace.xl),
            children: [
              Row(children: [
                Expanded(child: Text(l10n.bedTimeLine(_b.time), style: theme.textTheme.bodyMedium?.copyWith(color: _Night.muted))),
                TextButton(
                  key: const Key('bed.later'),
                  style: TextButton.styleFrom(foregroundColor: _Night.muted),
                  onPressed: () => ref.read(bedtimeLaterProvider.notifier).state = true,
                  child: Text(l10n.bedLater),
                ),
              ]),
              Text(l10n.bedTitle, style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
              const SizedBox(height: HallySpace.md),
              Row(children: [
                for (var i = 0; i < steps.length; i++)
                  Expanded(
                    child: Container(
                      height: 6,
                      margin: EdgeInsets.only(right: i == steps.length - 1 ? 0 : 6),
                      decoration: BoxDecoration(color: i < _b.done ? _Night.lavender : _Night.faint, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
              ]),
              const SizedBox(height: HallySpace.md),
              for (final (i, s) in steps.indexed)
                _StepTile(key: Key('bed.step.$i'), index: i, step: s, done: i < _b.done, now: i == _b.done, onTap: () => _check(i)),
              const SizedBox(height: HallySpace.md),
              Text(l10n.bedHint, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: _Night.muted, height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({super.key, required this.index, required this.step, required this.done, required this.now, required this.onTap});

  final int index;
  final BedtimeStep step;
  final bool done;
  final bool now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = !done && !now;
    return Opacity(
      opacity: waiting ? 0.45 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: HallySpace.sm),
        decoration: BoxDecoration(
          color: now ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(HallyRadius.lg),
          border: now ? Border.all(color: _Night.lavender, width: 2) : null,
          boxShadow: now ? [BoxShadow(color: _Night.lavender.withValues(alpha: 0.35), blurRadius: 18)] : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(HallyRadius.lg),
          onTap: now ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.md - 2),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done ? _Night.lavender : Colors.transparent,
                  border: Border.all(color: done ? _Night.lavender : _Night.muted, width: 2),
                ),
                child: done
                    ? const Icon(Icons.check_rounded, size: 20, color: _Night.sky)
                    : Text(now ? '' : '${index + 1}', style: const TextStyle(color: _Night.muted, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: HallySpace.sm + 4),
              Expanded(
                child: Text(step.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w700, decoration: done ? TextDecoration.lineThrough : null, decorationColor: _Night.muted)),
              ),
              Text(step.emoji, style: const TextStyle(fontSize: 24)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// After the routine: good night, a breathing circle and tonight's story read aloud; then the screen dims.
class KidNightView extends ConsumerStatefulWidget {
  const KidNightView({super.key, required this.home, this.onClose});

  final ChildHome home;

  /// Null while the phone is locked for the night.
  final VoidCallback? onClose;

  @override
  ConsumerState<KidNightView> createState() => _KidNightViewState();
}

class _KidNightViewState extends ConsumerState<KidNightView> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
  bool _speaking = false;
  bool _dim = false;

  @override
  void dispose() {
    _breath.dispose();
    if (_speaking) ref.read(storySpeakerProvider).stop();
    super.dispose();
  }

  Future<void> _toggle(BedtimeStory story) async {
    final speaker = ref.read(storySpeakerProvider);
    if (_speaking) {
      await speaker.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    setState(() {
      _speaking = true;
      _dim = false;
    });
    await speaker.speak('${story.title}. ${story.text}', language: _lang(context), onDone: () {
      if (mounted) {
        setState(() {
          _speaking = false;
          _dim = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = widget.home.bedtime;
    final story = storyFor(DateTime.now().subtract(const Duration(hours: 12)), _lang(context));
    final locked = widget.onClose == null;
    return Scaffold(
      key: const Key('bed.night'),
      backgroundColor: _Night.sky,
      body: Stack(children: [
        _StarrySky(
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.xl, HallySpace.lg, HallySpace.lg),
              children: [
                if (b != null)
                  Text(b.cherries > 0 ? l10n.bedDoneLine(b.cherries) : l10n.bedDoneNoCherries,
                      textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: _Night.muted, fontWeight: FontWeight.w600)),
                const SizedBox(height: HallySpace.sm),
                ParentExitGesture(
                  child: Text(l10n.bedGoodNight(widget.home.firstName),
                      textAlign: TextAlign.center, style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(height: HallySpace.lg),
                Center(
                  child: AnimatedBuilder(
                    animation: _breath,
                    builder: (context, _) {
                      final t = Curves.easeInOut.transform(_breath.value);
                      return Container(
                        width: 120 + 50 * t,
                        height: 120 + 50 * t,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _Night.lavender.withValues(alpha: 0.18 + 0.12 * t),
                          border: Border.all(color: _Night.lavender.withValues(alpha: 0.6), width: 2),
                        ),
                        child: Text(_breath.status == AnimationStatus.forward ? l10n.bedBreatheIn : l10n.bedBreatheOut,
                            style: theme.textTheme.titleMedium?.copyWith(color: _Night.text)),
                      );
                    },
                  ),
                ),
                const SizedBox(height: HallySpace.lg),
                Container(
                  padding: const EdgeInsets.all(HallySpace.md + 2),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(HallyRadius.lg)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.bedStoryLabel,
                        style: theme.textTheme.labelMedium?.copyWith(color: _Night.muted, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                    const SizedBox(height: 6),
                    Text(story.title, style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(story.text,
                        maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: _Night.text, height: 1.6)),
                    const SizedBox(height: HallySpace.sm + 4),
                    Row(children: [
                      FilledButton.icon(
                        key: const Key('bed.play'),
                        style: FilledButton.styleFrom(backgroundColor: _Night.lavender, foregroundColor: _Night.sky, minimumSize: const Size(0, 44)),
                        onPressed: () => _toggle(story),
                        icon: Icon(_speaking ? Icons.stop_rounded : Icons.play_arrow_rounded),
                        label: Text(_speaking ? l10n.bedStop : l10n.bedPlay),
                      ),
                      const SizedBox(width: HallySpace.sm + 4),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(value: _speaking ? null : 0, minHeight: 5, color: _Night.text, backgroundColor: _Night.faint),
                        ),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: HallySpace.md),
                Text(locked ? '${l10n.bedNightNote}\n${l10n.bedNightLock}' : l10n.bedNightNote,
                    textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: _Night.muted, height: 1.5)),
                const SizedBox(height: HallySpace.md),
                if (locked)
                  Row(children: [
                    Expanded(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: _Night.muted),
                        onPressed: () => launchUrl(Uri.parse('tel:112')),
                        icon: const Icon(Icons.call_rounded),
                        label: Text(l10n.kidLockEmergency),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: _Night.muted),
                        onPressed: () => ref.invalidate(childHomeProvider),
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(l10n.kidLockCheck),
                      ),
                    ),
                  ])
                else
                  TextButton(
                    key: const Key('bed.close'),
                    style: TextButton.styleFrom(foregroundColor: _Night.muted),
                    onPressed: widget.onClose,
                    child: Text(l10n.bedClose),
                  ),
              ],
            ),
          ),
        ),
        // When the story ends the screen slowly goes dark; a tap brings it back.
        IgnorePointer(
          ignoring: !_dim,
          child: GestureDetector(
            onTap: () => setState(() => _dim = false),
            child: AnimatedOpacity(
              key: const Key('bed.dim'),
              opacity: _dim ? 0.85 : 0,
              duration: const Duration(seconds: 20),
              child: const ColoredBox(color: Colors.black, child: SizedBox.expand()),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Bugünüm: brings tonight's steps back after "Sonra".
class KidBedtimeCard extends ConsumerWidget {
  const KidBedtimeCard({super.key, required this.bedtime});

  final ChildBedtime bedtime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      key: const Key('bed.card'),
      color: _Night.sky,
      margin: const EdgeInsets.only(bottom: HallySpace.md),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: 4),
        leading: const Text('🌙', style: TextStyle(fontSize: 28)),
        title: Text(l10n.bedCard, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
        subtitle: Text(l10n.bedCardBody(bedtime.done, bedtime.steps.length), style: const TextStyle(color: _Night.muted)),
        trailing: const Icon(Icons.chevron_right_rounded, color: _Night.muted),
        onTap: () => ref.read(bedtimeLaterProvider.notifier).state = false,
      ),
    );
  }
}

// ─── Parent side ──────────────────────────────────────────────────────────────

List<BedtimeStep> defaultBedtimeSteps(AppLocalizations l10n) => [
      BedtimeStep(title: l10n.bedStepPajamas, emoji: '👕'),
      BedtimeStep(title: l10n.bedStepTeeth, emoji: '🪥'),
      BedtimeStep(title: l10n.bedStepBag, emoji: '🎒'),
      BedtimeStep(title: l10n.bedStepWater, emoji: '💧'),
      BedtimeStep(title: l10n.bedStepBed, emoji: '🛏️'),
    ];

/// Parents: the routine's time, steps, cherries and the night lock, plus how tonight is going.
class BedtimeSettingsScreen extends ConsumerStatefulWidget {
  const BedtimeSettingsScreen({super.key, required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<BedtimeSettingsScreen> createState() => _BedtimeSettingsScreenState();
}

class _BedtimeSettingsScreenState extends ConsumerState<BedtimeSettingsScreen> {
  BedtimeRoutine? _r;
  bool _saving = false;

  (String, String) get _key => (widget.familyId, widget.childId);

  void _set({String? time, List<BedtimeStep>? steps, bool? enabled, bool? lock, int? cherries}) {
    final r = _r!;
    setState(() => _r = BedtimeRoutine(
          time: time ?? r.time,
          steps: steps ?? r.steps,
          enabled: enabled ?? r.enabled,
          lockUntilMorning: lock ?? r.lockUntilMorning,
          cherries: cherries ?? r.cherries,
        ));
  }

  Future<void> _pickTime() async {
    final parts = _r!.time.split(':');
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])));
    if (picked == null) return;
    _set(time: '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
  }

  Future<void> _addStep() async {
    final title = await showDialog<String>(context: context, builder: (_) => const _StepDialog());
    if (title == null || title.isEmpty) return;
    _set(steps: [..._r!.steps, BedtimeStep(title: title, emoji: '⭐')]);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(bedtimeRepositoryProvider).save(widget.familyId, widget.childId, _r!);
      ref.invalidate(bedtimeProvider(_key));
      messenger.showSnackBar(SnackBar(content: Text(l10n.bedSaved)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(bedtimeProvider(_key));
    if (_r == null && state.valueOrNull != null) {
      _r = state.value!.routine ?? BedtimeRoutine(time: '20:30', steps: defaultBedtimeSteps(l10n));
    }
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.bedSettingsTitle)),
      body: r == null
          ? state.hasError
              ? HallyErrorState(onRetry: () => ref.invalidate(bedtimeProvider(_key)))
              : const HallyLoading()
          : ListView(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.md, 120),
              children: [
                Text(l10n.bedSettingsBody, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (state.valueOrNull case final s? when s.tonightTotal > 0) ...[
                  const SizedBox(height: HallySpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: HallyPill(
                      key: const Key('bed.tonight'),
                      icon: Icons.bedtime_rounded,
                      color: HallyColors.lavender,
                      label: s.tonightFinishedAt != null
                          ? l10n.bedTonightDone(DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(s.tonightFinishedAt!.toLocal()))
                          : l10n.bedTonight(s.tonightDone, s.tonightTotal),
                    ),
                  ),
                ],
                const SizedBox(height: HallySpace.sm),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(children: [
                    SwitchListTile(key: const Key('bed.enabled'), title: Text(l10n.bedEnabled), value: r.enabled, onChanged: (v) => _set(enabled: v)),
                    ListTile(
                      key: const Key('bed.time'),
                      leading: const Icon(Icons.schedule_rounded),
                      title: Text(l10n.bedTime),
                      trailing: Text(r.time, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                      onTap: _pickTime,
                    ),
                  ]),
                ),
                HallySectionHeader(title: l10n.bedSteps, count: r.steps.length),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(children: [
                    for (final (i, s) in r.steps.indexed)
                      ListTile(
                        key: Key('bed.edit.$i'),
                        leading: Text(s.emoji, style: const TextStyle(fontSize: 22)),
                        title: Text(s.title),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (i > 0)
                            IconButton(
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onPressed: () => _set(
                                  steps: [...r.steps]
                                    ..insert(i - 1, r.steps[i])
                                    ..removeAt(i + 1)),
                            ),
                          if (r.steps.length > 1)
                            IconButton(
                              key: Key('bed.remove.$i'),
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => _set(steps: [...r.steps]..removeAt(i)),
                            ),
                        ]),
                      ),
                    if (r.steps.length < 8)
                      ListTile(key: const Key('bed.add'), leading: const Icon(Icons.add_rounded), title: Text(l10n.bedAddStep), onTap: _addStep),
                  ]),
                ),
                HallySectionHeader(title: l10n.bedCherries),
                Wrap(spacing: HallySpace.sm, children: [
                  for (final c in const [0, 1, 2, 3, 5])
                    ChoiceChip(
                      key: Key('bed.cherries.$c'),
                      avatar: c == 0 ? null : const CherryIcon(size: 16),
                      label: Text('$c'),
                      selected: r.cherries == c,
                      onSelected: (_) => _set(cherries: c),
                    ),
                ]),
                const SizedBox(height: HallySpace.md),
                Card(
                  margin: EdgeInsets.zero,
                  child: SwitchListTile(
                    key: const Key('bed.lock'),
                    secondary: const Icon(Icons.lock_clock_rounded),
                    title: Text(l10n.bedLockMorning),
                    value: r.lockUntilMorning,
                    onChanged: (v) => _set(lock: v),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: r == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, HallySpace.md),
                child: FilledButton(key: const Key('bed.save'), onPressed: _saving ? null : _save, child: Text(l10n.bedSave)),
              ),
            ),
    );
  }
}

class _StepDialog extends StatefulWidget {
  const _StepDialog();

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.bedAddStep),
      content: TextField(
        key: const Key('bed.step.title'),
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: l10n.bedStepHint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
        FilledButton(key: const Key('bed.step.save'), onPressed: () => Navigator.pop(context, _controller.text.trim()), child: Text(l10n.bedAddStep)),
      ],
    );
  }
}
