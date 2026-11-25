import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../capture/capture_repository.dart';
import '../privacy/ai_consent.dart';
import 'assistant_repository.dart';
import 'voice_input.dart';

/// Chat with Hally. Answers come from the family's own data; anything to add arrives as a suggestion to approve.
///
/// The microphone button (and `/assistant?voice=1`, used by the home screen widget and the app icon shortcut)
/// lets the parent speak instead of type: the words are sent as a message when they stop talking.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key, this.startVoice = false});

  /// Starts listening as soon as the screen opens.
  final bool startVoice;

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <ChatEntry>[];
  String? _conversationId;
  bool _sending = false;
  bool _listening = false;
  bool _voiceStarted = false;
  late final VoiceInput _voice;

  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceInputProvider);
  }

  @override
  void dispose() {
    if (_listening) unawaited(_voice.cancel());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Mic button: starts listening, or while listening, sends what was heard so far.
  Future<void> _toggleVoice(String familyId) async {
    final voice = _voice;
    if (_listening) {
      await voice.stop();
      return;
    }
    if (_sending) return;
    // The words go to the AI service, so ask for that consent before the parent speaks, not after.
    if (!await ensureAiConsent(context, ref) || !mounted) return;
    final l10n = AppLocalizations.of(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    if (!await voice.ensureReady()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.voiceUnavailable)));
      return;
    }
    if (!mounted) return;
    setState(() {
      _listening = true;
      _input.clear();
    });
    await voice.listen(
      localeId: voiceLocaleFor(languageCode),
      onText: (words) {
        if (mounted) _input.text = words;
      },
      onDone: (words) {
        if (!mounted) return;
        setState(() => _listening = false);
        if (words.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.voiceNotHeard)));
        } else {
          unawaited(_send(familyId, words));
        }
      },
    );
  }

  Future<void> _send(String familyId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;
    if (!await ensureAiConsent(context, ref) || !mounted) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _entries.add(ChatEntry(id: 'local-${_entries.length}', fromUser: true, text: trimmed));
      _sending = true;
      _input.clear();
    });
    _toBottom();
    try {
      final reply = await ref.read(assistantRepositoryProvider).send(familyId, trimmed, conversationId: _conversationId);
      if (!mounted) return;
      setState(() {
        _conversationId = reply.conversationId;
        _entries.add(reply.reply);
      });
    } catch (_) {
      if (mounted) setState(() => _entries.add(ChatEntry(id: 'err-${_entries.length}', fromUser: false, text: l10n.assistantError)));
    } finally {
      if (mounted) setState(() => _sending = false);
      _toBottom();
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: HallyMotion.medium, curve: HallyMotion.curve);
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final starters = [l10n.assistantStarterTomorrow, l10n.assistantStarterWeek, l10n.assistantStarterAdd];
    if (widget.startVoice && !_voiceStarted) {
      _voiceStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_toggleVoice(familyId));
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabAssistant)),
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(HallySpace.lg),
                    children: [
                      HallyEmptyState(icon: Icons.auto_awesome_rounded, color: HallyModule.assistant, title: l10n.assistantEmptyTitle, body: l10n.assistantEmptyBody),
                      const SizedBox(height: HallySpace.md),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: HallySpace.sm,
                        runSpacing: HallySpace.sm,
                        children: [
                          for (final (i, s) in starters.indexed)
                            ActionChip(key: Key('assistant.starter.$i'), label: Text(s), onPressed: () => i == 2 ? _input.text = s : _send(familyId, s)),
                        ],
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.md, HallySpace.md, HallySpace.md),
                    itemCount: _entries.length + (_sending ? 1 : 0),
                    itemBuilder: (context, i) => i == _entries.length ? const _Typing() : _Bubble(entry: _entries[i]),
                  ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 92), // clear the floating tab bar
            child: Padding(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.sm, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('assistant.input'),
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      textInputAction: TextInputAction.send,
                      readOnly: _listening,
                      onSubmitted: (t) => _send(familyId, t),
                      decoration: InputDecoration(hintText: _listening ? l10n.voiceListening : l10n.assistantHint, counterText: ''),
                    ),
                  ),
                  IconButton(
                    key: const Key('assistant.voice'),
                    tooltip: _listening ? l10n.voiceStop : l10n.voiceSpeak,
                    onPressed: _sending ? null : () => _toggleVoice(familyId),
                    style: _listening ? IconButton.styleFrom(backgroundColor: HallyColors.softOf(HallyColors.cherry, Theme.of(context).brightness)) : null,
                    color: _listening ? HallyColors.cherry : null,
                    icon: Icon(_listening ? Icons.stop_rounded : Icons.mic_none_rounded),
                  ),
                  IconButton.filled(
                    key: const Key('assistant.send'),
                    tooltip: l10n.assistantSend,
                    onPressed: _sending || _listening ? null : () => _send(familyId, _input.text),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final mine = entry.fromUser;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: Container(
          margin: const EdgeInsets.only(bottom: HallySpace.sm),
          padding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.sm + 2),
          decoration: BoxDecoration(
            // Hally speaks on sage (the assistant's colour); the parent's own messages sit on a blush tint.
            color: HallyColors.softOf(mine ? HallyColors.cherry : HallyModule.assistant, theme.brightness),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(HallyRadius.md),
              topRight: const Radius.circular(HallyRadius.md),
              bottomLeft: Radius.circular(mine ? HallyRadius.md : 4),
              bottomRight: Radius.circular(mine ? 4 : HallyRadius.md),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(entry.text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface, height: 1.4)),
              if (entry.proposals.isNotEmpty) ...[
                const SizedBox(height: HallySpace.sm),
                for (final p in entry.proposals)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HallySpace.xs),
                    child: HallyPill(
                      label: [p.payload.title, if (p.payload.date != null) p.payload.date!, if (p.payload.time != null) p.payload.time!].join(' · '),
                      icon: p.isEvent ? Icons.event_rounded : Icons.check_circle_outline_rounded,
                      color: p.isEvent ? HallyModule.calendar : HallyModule.tasks,
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: Key('assistant.review.${entry.id}'),
                    onPressed: () {
                      ref.read(lastCaptureProvider.notifier).state = null;
                      context.push('/capture/review');
                    },
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(l10n.assistantReview),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) => const Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.all(HallySpace.sm),
          child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
}
