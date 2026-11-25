import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../capture/capture_repository.dart';
import '../bedtime/bedtime.dart';
import '../privacy/ai_consent.dart';
import 'assistant_repository.dart';
import 'briefing.dart';
import 'voice_input.dart';

/// Chat with Hally. Answers come from the family's own data; anything to add arrives as a suggestion to approve.
///
/// The microphone button (and `/assistant?voice=1`, used by the home screen widget and the app icon shortcut)
/// lets the parent speak instead of type: the words are sent as a message when they stop talking.
///
/// "Bugün ne var?" / "Yarın ne var?" (spoken, typed or the 🔊 chip) is answered without the AI: the server lists the
/// day from the family's own data and the phone reads it aloud (Durdur, Tekrar oku, Daha kısa).
/// `/assistant?briefing=1` (the morning notification) opens with today's summary playing.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key, this.startVoice = false, this.startBriefing = false});

  /// Starts listening as soon as the screen opens.
  final bool startVoice;

  /// Reads today's summary as soon as the screen opens.
  final bool startBriefing;

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
  bool _briefingStarted = false;

  /// The briefing entry being read aloud right now.
  String? _speakingId;
  late final VoiceInput _voice;
  late final StorySpeaker _speaker;

  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceInputProvider);
    _speaker = ref.read(briefingSpeakerProvider);
  }

  @override
  void dispose() {
    if (_listening) unawaited(_voice.cancel());
    if (_speakingId != null) unawaited(_speaker.stop());
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
    final day = briefingDayOf(trimmed);
    if (day != null) return _brief(familyId, day, asked: trimmed);
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

  /// The day's summary from the family's own data, read aloud. No AI and no AI consent involved.
  Future<void> _brief(String familyId, BriefingDay day, {String? asked}) async {
    if (_sending) return;
    final l10n = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    await _stopSpeaking();
    setState(() {
      if (asked != null) _entries.add(ChatEntry(id: 'local-${_entries.length}', fromUser: true, text: asked));
      _sending = true;
      _input.clear();
    });
    _toBottom();
    try {
      final brief = await ref.read(briefingRepositoryProvider).get(familyId, tomorrow: day == BriefingDay.tomorrow, lang: lang);
      if (!mounted) return;
      final entry = ChatEntry(id: 'brief-${_entries.length}', fromUser: false, text: brief.speech, briefing: brief);
      setState(() => _entries.add(entry));
      unawaited(_speak(entry, short: false));
    } catch (_) {
      if (mounted) setState(() => _entries.add(ChatEntry(id: 'err-${_entries.length}', fromUser: false, text: l10n.briefingError)));
    } finally {
      if (mounted) setState(() => _sending = false);
      _toBottom();
    }
  }

  Future<void> _speak(ChatEntry entry, {required bool short}) async {
    final brief = entry.briefing;
    if (brief == null) return;
    await _speaker.stop();
    if (!mounted) return;
    setState(() => _speakingId = entry.id);
    await _speaker.speak(
      short ? brief.shortSpeech : brief.speech,
      language: Localizations.localeOf(context).languageCode,
      onDone: () {
        if (mounted && _speakingId == entry.id) setState(() => _speakingId = null);
      },
    );
  }

  Future<void> _stopSpeaking() async {
    if (_speakingId == null) return;
    setState(() => _speakingId = null);
    await _speaker.stop();
  }

  Future<void> _morningSettings(String familyId) async {
    final l10n = AppLocalizations.of(context);
    final repo = ref.read(briefingRepositoryProvider);
    String? current;
    try {
      current = await repo.time(familyId);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.briefingError)));
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<_MorningChoice>(
      context: context,
      useSafeArea: true,
      builder: (_) => _MorningSheet(time: current),
    );
    if (chosen == null || !mounted) return;
    try {
      final saved = await repo.setTime(familyId, chosen.time);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(saved == null ? l10n.briefingMorningOffDone : l10n.briefingMorningOnDone(saved))));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.briefingError)));
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
    if (widget.startBriefing && !_briefingStarted) {
      _briefingStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_brief(familyId, BriefingDay.today));
      });
    }
    if (widget.startVoice && !_voiceStarted) {
      _voiceStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_toggleVoice(familyId));
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabAssistant),
        actions: [
          IconButton(
            key: const Key('assistant.morning'),
            tooltip: l10n.briefingMorningTitle,
            onPressed: () => _morningSettings(familyId),
            icon: const Icon(Icons.wb_sunny_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(HallySpace.lg),
                    children: [
                      HallyEmptyState(
                          icon: Icons.auto_awesome_rounded, color: HallyModule.assistant, title: l10n.assistantEmptyTitle, body: l10n.assistantEmptyBody),
                      const SizedBox(height: HallySpace.md),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: HallySpace.sm,
                        runSpacing: HallySpace.sm,
                        children: [
                          ActionChip(
                            key: const Key('assistant.briefing'),
                            avatar: const Icon(Icons.volume_up_rounded, size: 18),
                            label: Text(l10n.briefingStarter),
                            onPressed: () => _brief(familyId, BriefingDay.today, asked: l10n.briefingStarter),
                          ),
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
                    itemBuilder: (context, i) {
                      if (i == _entries.length) return const _Typing();
                      final e = _entries[i];
                      if (e.briefing == null) return _Bubble(entry: e);
                      return _BriefingBubble(
                        entry: e,
                        speaking: _speakingId == e.id,
                        onStop: _stopSpeaking,
                        onAgain: () => _speak(e, short: false),
                        onShorter: () => _speak(e, short: true),
                      );
                    },
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

/// "Bugün ne var?": the day's lines with 🔊 controls.
class _BriefingBubble extends StatelessWidget {
  const _BriefingBubble({required this.entry, required this.speaking, required this.onStop, required this.onAgain, required this.onShorter});

  final ChatEntry entry;
  final bool speaking;
  final VoidCallback onStop;
  final VoidCallback onAgain;
  final VoidCallback onShorter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final brief = entry.briefing!;
    final compact = TextButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm));
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.88),
        child: Container(
          key: Key('assistant.brief.${entry.id}'),
          margin: const EdgeInsets.only(bottom: HallySpace.sm),
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm + 2, HallySpace.md, HallySpace.xs),
          decoration: BoxDecoration(
            color: HallyColors.softOf(HallyModule.assistant, theme.brightness),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(HallyRadius.md),
              topRight: Radius.circular(HallyRadius.md),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(HallyRadius.md),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(speaking ? Icons.volume_up_rounded : Icons.volume_mute_rounded, size: 18, color: HallyModule.assistant),
                  const SizedBox(width: HallySpace.xs),
                  Expanded(child: Text(brief.greeting, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface))),
                ],
              ),
              const SizedBox(height: HallySpace.xs),
              for (final line in brief.lines)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${line.emoji}  ${line.text}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface, height: 1.4)),
                ),
              Wrap(
                spacing: HallySpace.xs,
                children: [
                  if (speaking)
                    TextButton.icon(
                        key: Key('assistant.brief.stop.${entry.id}'),
                        style: compact,
                        onPressed: onStop,
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: Text(l10n.briefingStop))
                  else
                    TextButton.icon(
                        key: Key('assistant.brief.again.${entry.id}'),
                        style: compact,
                        onPressed: onAgain,
                        icon: const Icon(Icons.replay_rounded, size: 18),
                        label: Text(l10n.briefingAgain)),
                  TextButton.icon(
                      key: Key('assistant.brief.short.${entry.id}'),
                      style: compact,
                      onPressed: onShorter,
                      icon: const Icon(Icons.short_text_rounded, size: 18),
                      label: Text(l10n.briefingShorter)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MorningChoice {
  const _MorningChoice(this.time);

  final String? time;
}

/// "Her sabah oku": an optional notification at a chosen time that opens the summary.
class _MorningSheet extends StatefulWidget {
  const _MorningSheet({this.time});

  final String? time;

  @override
  State<_MorningSheet> createState() => _MorningSheetState();
}

class _MorningSheetState extends State<_MorningSheet> {
  late bool _on = widget.time != null;
  late TimeOfDay _at = _parse(widget.time) ?? const TimeOfDay(hour: 7, minute: 30);

  static TimeOfDay? _parse(String? t) {
    final parts = t?.split(':');
    if (parts == null || parts.length != 2) return null;
    final (h, m) = (int.tryParse(parts[0]), int.tryParse(parts[1]));
    return h == null || m == null ? null : TimeOfDay(hour: h, minute: m);
  }

  static String _format(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 05:00-11:30, the same window the server accepts.
  static bool _inWindow(TimeOfDay t) => t.hour >= 5 && (t.hour < 11 || (t.hour == 11 && t.minute <= 30));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HallySpace.lg, HallySpace.md, HallySpace.lg, HallySpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.briefingMorningTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: HallySpace.xs),
          Text(l10n.briefingMorningBody, style: theme.textTheme.bodyMedium),
          SwitchListTile(
            key: const Key('briefing.morning.switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.briefingMorningSwitch),
            value: _on,
            onChanged: (v) => setState(() => _on = v),
          ),
          if (_on)
            ListTile(
              key: const Key('briefing.morning.time'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded),
              title: Text(l10n.briefingMorningTime),
              trailing: Text(_format(_at), style: theme.textTheme.titleMedium),
              onTap: () async {
                final picked = await showTimePicker(context: context, initialTime: _at);
                if (picked == null || !context.mounted) return;
                if (!_inWindow(picked)) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.briefingMorningWindow)));
                  return;
                }
                setState(() => _at = picked);
              },
            ),
          const SizedBox(height: HallySpace.sm),
          FilledButton(
            key: const Key('briefing.morning.save'),
            onPressed: () => Navigator.of(context).pop(_MorningChoice(_on ? _format(_at) : null)),
            child: Text(l10n.briefingMorningSave),
          ),
        ],
      ),
    );
  }
}
