import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../child_mode/child_mode_repository.dart';
import 'asks.dart';
import '../../core/locale/units.dart';

String _lang(BuildContext context) => langOf(context);

/// The child's requests; [lang] picks the language of the starting list.
final kidAsksProvider = FutureProvider.autoDispose.family<ChildAsks, String>((ref, lang) => ref.watch(childApiProvider).asks(lang));

String _clock(BuildContext context, DateTime t) => DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(t);

/// Status pill: waiting is butter, yes is sage, no is peach (never red).
Widget _statusPill(AppLocalizations l10n, ChildAskItem a) => switch (a.status) {
      AskStatus.pending => HallyPill(label: l10n.askWaiting, color: HallyColors.butter),
      AskStatus.yes => HallyPill(label: l10n.askYes, color: HallyColors.sage, icon: Icons.check_rounded),
      AskStatus.no => HallyPill(label: l10n.askNo, color: HallyColors.peach),
      AskStatus.expired => HallyPill(label: l10n.askExpired, color: HallyColors.mist),
    };

// ─── Child ────────────────────────────────────────────────────────────────────

/// On the child's Bugünüm: "Bir şey iste", with the latest answer.
class KidAskCard extends ConsumerWidget {
  const KidAskCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final latest = ref.watch(kidAsksProvider(_lang(context))).valueOrNull?.asks.firstOrNull;
    return Card(
      key: const Key('kid.ask'),
      margin: const EdgeInsets.only(bottom: HallySpace.md),
      color: HallyColors.softOf(HallyColors.cherry, b),
      child: InkWell(
        borderRadius: BorderRadius.circular(HallyRadius.md),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const KidAsksScreen())),
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.md),
          child: Row(children: [
            const Text('🙋', style: TextStyle(fontSize: 30)),
            const SizedBox(width: HallySpace.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.askTitle,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b))),
                if (latest == null)
                  Text(l10n.askCardHint, style: theme.textTheme.bodySmall)
                else
                  Row(children: [
                    Flexible(child: Text('${latest.emoji} ${latest.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                    const SizedBox(width: 6),
                    _statusPill(l10n, latest),
                  ]),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      ),
    );
  }
}

/// "Bir şey iste": tap a ready-made request (or write one); answers show up here while the page is open.
class KidAsksScreen extends ConsumerStatefulWidget {
  const KidAsksScreen({super.key});

  @override
  ConsumerState<KidAsksScreen> createState() => _KidAsksScreenState();
}

class _KidAsksScreenState extends ConsumerState<KidAsksScreen> {
  Timer? _poll;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // The child's phone gets no push: look for answers every few seconds while something waits.
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      final lang = _lang(context);
      if (ref.read(kidAsksProvider(lang)).valueOrNull?.anyPending ?? false) ref.invalidate(kidAsksProvider(lang));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _send({String? presetId, String? text, String? detail}) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final lang = _lang(context);
    setState(() => _sending = true);
    try {
      await ref.read(childApiProvider).ask(presetId: presetId, text: text, detail: detail, lang: lang);
      HapticFeedback.mediumImpact();
      messenger.showSnackBar(SnackBar(content: Text(l10n.askSent)));
    } on UnpairedException {
      ref.invalidate(childSessionProvider);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(switch (e.code) {
        'ask.already_pending' => l10n.askAlreadyPending,
        'ask.too_many' => l10n.askTooMany,
        _ => l10n.errorGeneric,
      })));
    } finally {
      ref.invalidate(kidAsksProvider(lang));
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _tap(AskPreset p) async {
    if (p.question == null) return _send(presetId: p.id);
    final detail = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AskDetailSheet(preset: p),
    );
    if (detail != null) await _send(presetId: p.id, detail: detail.isEmpty ? null : detail);
  }

  Future<void> _write() async {
    final text = await showDialog<String>(context: context, builder: (_) => const _OwnAskDialog());
    if (text != null && text.trim().isNotEmpty) await _send(text: text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final lang = _lang(context);
    final page = ref.watch(kidAsksProvider(lang));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.askTitle)),
      body: page.when(
        loading: () => const HallyLoading(),
        error: (e, _) => HallyErrorState(onRetry: () => ref.invalidate(kidAsksProvider(lang))),
        data: (data) {
          final pendingPresets = {
            for (final a in data.asks)
              if (a.isPending) a.title
          };
          return RefreshIndicator(
            onRefresh: () => ref.refresh(kidAsksProvider(lang).future),
            child: ListView(
              padding: const EdgeInsets.all(HallySpace.md),
              children: [
                Text(l10n.askIntro, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: HallySpace.md),
                for (final p in data.presets)
                  _AskTile(
                    key: Key('ask.preset.${p.id}'),
                    emoji: p.emoji,
                    title: p.title,
                    waiting: pendingPresets.contains(p.title),
                    onTap: _sending || pendingPresets.contains(p.title) ? null : () => _tap(p),
                  ),
                _AskTile(
                  key: const Key('ask.own'),
                  emoji: '✏️',
                  title: l10n.askOwn,
                  muted: true,
                  onTap: _sending ? null : _write,
                ),
                if (data.asks.isNotEmpty) HallySectionHeader(title: l10n.askToday),
                for (final a in data.asks)
                  Card(
                    key: Key('ask.mine.${a.id}'),
                    margin: const EdgeInsets.only(bottom: HallySpace.sm),
                    child: Padding(
                      padding: const EdgeInsets.all(HallySpace.md),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text(a.emoji, style: const TextStyle(fontSize: 22)),
                          const SizedBox(width: HallySpace.sm),
                          Expanded(child: Text(a.line, style: const TextStyle(fontWeight: FontWeight.w700))),
                          _statusPill(l10n, a),
                        ]),
                        if (a.note != null) ...[
                          const SizedBox(height: HallySpace.sm),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(HallySpace.sm),
                            decoration: BoxDecoration(
                              color: HallyColors.softOf(HallyColors.cherry, b),
                              borderRadius: BorderRadius.circular(HallyRadius.sm),
                            ),
                            child: Text(a.answeredByName == null ? a.note! : '${a.answeredByName}: ${a.note}'),
                          ),
                        ] else if (a.answeredByName != null && !a.isPending)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(l10n.askAnsweredBy(a.answeredByName!), style: theme.textTheme.bodySmall),
                          ),
                      ]),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AskTile extends StatelessWidget {
  const _AskTile({super.key, required this.emoji, required this.title, this.waiting = false, this.muted = false, this.onTap});

  final String emoji;
  final String title;
  final bool waiting;
  final bool muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final l10n = AppLocalizations.of(context);
    final accent = HallyColors.accent(HallyColors.cherry, b);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: waiting ? HallyColors.softOf(HallyColors.cherry, b) : theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: waiting ? accent : theme.colorScheme.outlineVariant, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.cherry, b), borderRadius: BorderRadius.circular(16)),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: muted ? theme.colorScheme.onSurfaceVariant : null)),
              ),
              if (waiting) HallyPill(label: l10n.askWaiting, color: HallyColors.butter),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The follow-up question ("Kimin evine?") with quick answers and "＋ Yaz".
class _AskDetailSheet extends StatefulWidget {
  const _AskDetailSheet({required this.preset});

  final AskPreset preset;

  @override
  State<_AskDetailSheet> createState() => _AskDetailSheetState();
}

class _AskDetailSheetState extends State<_AskDetailSheet> {
  String? _picked;
  bool _writing = false;
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _answer => _writing ? _text.text.trim() : _picked ?? '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final p = widget.preset;
    return Padding(
      padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${p.emoji} ${p.title}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: HallySpace.sm),
          Text(p.question!, style: theme.textTheme.titleMedium),
          const SizedBox(height: HallySpace.sm),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final o in p.options)
              ChoiceChip(
                key: Key('ask.option.$o'),
                label: Text(o),
                selected: !_writing && _picked == o,
                onSelected: (_) => setState(() {
                  _picked = o;
                  _writing = false;
                }),
              ),
            ChoiceChip(
              key: const Key('ask.option.write'),
              label: Text(l10n.askWrite),
              selected: _writing,
              onSelected: (_) => setState(() => _writing = true),
            ),
          ]),
          if (_writing) ...[
            const SizedBox(height: HallySpace.sm),
            TextField(
              key: const Key('ask.detail'),
              controller: _text,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: HallySpace.md),
          FilledButton(
            key: const Key('ask.send'),
            onPressed: _answer.isEmpty && p.options.isNotEmpty ? null : () => Navigator.pop(context, _answer),
            child: Text(l10n.askSend),
          ),
        ],
      ),
    );
  }
}

class _OwnAskDialog extends StatefulWidget {
  const _OwnAskDialog();

  @override
  State<_OwnAskDialog> createState() => _OwnAskDialogState();
}

class _OwnAskDialogState extends State<_OwnAskDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.askOwn),
      content: TextField(
        key: const Key('ask.own.text'),
        controller: _text,
        autofocus: true,
        maxLength: 60,
        decoration: InputDecoration(hintText: l10n.askOwnHint),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
        FilledButton(
          key: const Key('ask.own.send'),
          onPressed: _text.text.trim().isEmpty ? null : () => Navigator.pop(context, _text.text),
          child: Text(l10n.askSend),
        ),
      ],
    );
  }
}

// ─── Parents ──────────────────────────────────────────────────────────────────

/// One open request with an optional note and Evet / Hayır.
class AskAnswerCard extends ConsumerStatefulWidget {
  const AskAnswerCard({super.key, required this.familyId, required this.ask});

  final String familyId;
  final ChildAskItem ask;

  @override
  ConsumerState<AskAnswerCard> createState() => _AskAnswerCardState();
}

class _AskAnswerCardState extends ConsumerState<AskAnswerCard> {
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _answer(bool yes) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(asksRepositoryProvider).answer(widget.familyId, widget.ask.id, yes: yes, note: _note.text.trim().isEmpty ? null : _note.text.trim());
      messenger.showSnackBar(SnackBar(content: Text(yes ? l10n.askAnsweredYes(widget.ask.childName) : l10n.askAnsweredNo(widget.ask.childName))));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(switch (e.code) {
        'ask.already_answered' => l10n.askAlreadyAnswered,
        'ask.expired' => l10n.askExpiredError,
        _ => l10n.errorGeneric,
      })));
    } finally {
      ref.invalidate(familyAsksProvider(widget.familyId));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final a = widget.ask;
    return Card(
      key: Key('ask.${a.id}'),
      margin: const EdgeInsets.only(bottom: HallySpace.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HallyRadius.md),
        side: BorderSide(color: HallyColors.softOf(HallyColors.cherry, b), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              HallyAvatar(name: a.childName, size: 36),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${a.emoji} ${a.line}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${a.childName} · ${_clock(context, a.createdAt)}', style: theme.textTheme.bodySmall),
                ]),
              ),
            ]),
            const SizedBox(height: HallySpace.sm),
            TextField(
              key: Key('ask.note.${a.id}'),
              controller: _note,
              maxLength: 140,
              decoration: InputDecoration(hintText: l10n.askNoteHint, counterText: '', isDense: true),
            ),
            const SizedBox(height: HallySpace.sm),
            Row(children: [
              Expanded(
                child: FilledButton(key: Key('ask.yes.${a.id}'), onPressed: _busy ? null : () => _answer(true), child: Text(l10n.askYes)),
              ),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: OutlinedButton(key: Key('ask.no.${a.id}'), onPressed: _busy ? null : () => _answer(false), child: Text(l10n.askNo)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// On a parent's Today: the children's open requests. Hidden when nothing waits.
class ParentAsksCard extends ConsumerWidget {
  const ParentAsksCard({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = (ref.watch(familyAsksProvider(familyId)).valueOrNull ?? const []).where((a) => a.isPending).toList();
    if (open.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HallySectionHeader(title: l10n.askParentTitle, color: HallyColors.cherry, count: open.length),
        for (final a in open) AskAnswerCard(key: ValueKey(a.id), familyId: familyId, ask: a),
      ],
    );
  }
}

/// `/asks`: open requests to answer and today's answers.
class AsksScreen extends ConsumerWidget {
  const AsksScreen({super.key, this.familyId});

  final String? familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final id = familyId ?? ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (id == null) return const Scaffold(body: HallyLoading());
    final asks = ref.watch(familyAsksProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.askParentTitle),
        actions: [
          IconButton(
            key: const Key('asks.presets'),
            tooltip: l10n.askPresetsTitle,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.push('/ask-presets?familyId=$id'),
          ),
        ],
      ),
      body: asks.when(
        loading: () => const HallyLoading(),
        error: (e, _) => HallyErrorState(onRetry: () => ref.invalidate(familyAsksProvider(id))),
        data: (list) {
          final open = list.where((a) => a.isPending).toList();
          final done = list.where((a) => !a.isPending).toList();
          return RefreshIndicator(
            onRefresh: () => ref.refresh(familyAsksProvider(id).future),
            child: ListView(
              padding: const EdgeInsets.all(HallySpace.md),
              children: [
                if (list.isEmpty)
                  HallyEmptyState(icon: Icons.front_hand_outlined, color: HallyColors.cherry, title: l10n.askEmptyTitle, body: l10n.askEmptyBody)
                else ...[
                  for (final a in open) AskAnswerCard(key: ValueKey(a.id), familyId: id, ask: a),
                  if (done.isNotEmpty) HallySectionHeader(title: l10n.askToday),
                  for (final a in done)
                    Card(
                      margin: const EdgeInsets.only(bottom: HallySpace.sm),
                      child: ListTile(
                        leading: Text(a.emoji, style: const TextStyle(fontSize: 22)),
                        title: Text(a.line, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          [
                            '${a.childName} · ${_clock(context, a.createdAt)}',
                            if (a.answeredByName != null) l10n.askAnsweredBy(a.answeredByName!),
                            if (a.note != null) '“${a.note}”',
                          ].join('\n'),
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: _statusPill(l10n, a),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// `/ask-presets`: the ready-made requests the child sees.
class AskPresetsScreen extends ConsumerStatefulWidget {
  const AskPresetsScreen({super.key, required this.familyId});

  final String familyId;

  @override
  ConsumerState<AskPresetsScreen> createState() => _AskPresetsScreenState();
}

class _AskPresetsScreenState extends ConsumerState<AskPresetsScreen> {
  List<AskPreset>? _items;
  bool _dirty = false;
  bool _saving = false;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final items = await ref.read(asksRepositoryProvider).presets(widget.familyId, _lang(context));
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _edit([int? index]) async {
    final result = await showDialog<AskPreset>(context: context, builder: (_) => _PresetDialog(preset: index == null ? null : _items![index]));
    if (result == null) return;
    setState(() {
      index == null ? _items!.add(result) : _items![index] = result;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final saved = await ref.read(asksRepositoryProvider).savePresets(widget.familyId, _items!);
      setState(() {
        _items = saved;
        _dirty = false;
      });
      messenger.showSnackBar(SnackBar(content: Text(l10n.askPresetsSaved)));
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
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.askPresetsTitle),
        actions: [
          TextButton(key: const Key('presets.save'), onPressed: _dirty && !_saving ? _save : null, child: Text(l10n.askSave)),
        ],
      ),
      body: _error != null
          ? HallyErrorState(onRetry: () {
              setState(() => _error = null);
              _load();
            })
          : items == null
              ? const HallyLoading()
              : ListView(
                  padding: const EdgeInsets.all(HallySpace.md),
                  children: [
                    Text(l10n.askPresetsBody, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: HallySpace.md),
                    for (var i = 0; i < items.length; i++)
                      Card(
                        key: Key('preset.$i'),
                        margin: const EdgeInsets.only(bottom: HallySpace.sm),
                        child: ListTile(
                          leading: Text(items[i].emoji, style: const TextStyle(fontSize: 24)),
                          title: Text(items[i].title, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            [
                              if (items[i].question != null) '${items[i].question} ${items[i].options.join(', ')}'.trim(),
                              if (items[i].screenMinutes != null) l10n.askPresetMinutes(items[i].screenMinutes!),
                            ].join('\n'),
                          ),
                          onTap: () => _edit(i),
                          trailing: IconButton(
                            key: Key('preset.delete.$i'),
                            tooltip: l10n.askDelete,
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () => setState(() {
                              items.removeAt(i);
                              _dirty = true;
                            }),
                          ),
                        ),
                      ),
                    if (items.length < 8)
                      OutlinedButton.icon(
                        key: const Key('preset.add'),
                        onPressed: () => _edit(),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(l10n.askPresetAdd),
                      ),
                  ],
                ),
    );
  }
}

class _PresetDialog extends StatefulWidget {
  const _PresetDialog({this.preset});

  final AskPreset? preset;

  @override
  State<_PresetDialog> createState() => _PresetDialogState();
}

class _PresetDialogState extends State<_PresetDialog> {
  late final _emoji = TextEditingController(text: widget.preset?.emoji ?? '💬');
  late final _title = TextEditingController(text: widget.preset?.title ?? '');
  late final _question = TextEditingController(text: widget.preset?.question ?? '');
  late final _options = TextEditingController(text: widget.preset?.options.join(', ') ?? '');
  late int? _minutes = widget.preset?.screenMinutes;

  @override
  void dispose() {
    for (final c in [_emoji, _title, _question, _options]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.preset == null ? l10n.askPresetAdd : l10n.askPresetEdit),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            SizedBox(width: 64, child: TextField(controller: _emoji, maxLength: 8, decoration: const InputDecoration(counterText: ''))),
            const SizedBox(width: HallySpace.sm),
            Expanded(
              child: TextField(
                key: const Key('preset.title'),
                controller: _title,
                maxLength: 40,
                decoration: InputDecoration(labelText: l10n.askPresetTitleLabel),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          TextField(
              controller: _question, maxLength: 40, decoration: InputDecoration(labelText: l10n.askPresetQuestionLabel, hintText: l10n.askPresetQuestionHint)),
          TextField(controller: _options, decoration: InputDecoration(labelText: l10n.askPresetOptionsLabel, hintText: l10n.askPresetOptionsHint)),
          const SizedBox(height: HallySpace.sm),
          DropdownButtonFormField<int?>(
            initialValue: _minutes,
            decoration: InputDecoration(labelText: l10n.askPresetMinutesLabel),
            items: [
              DropdownMenuItem(value: null, child: Text(l10n.askPresetNoMinutes)),
              for (final m in const [15, 30, 60]) DropdownMenuItem(value: m, child: Text(l10n.askPresetMinutes(m))),
            ],
            onChanged: (v) => setState(() => _minutes = v),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
        FilledButton(
          key: const Key('preset.ok'),
          onPressed: _title.text.trim().isEmpty
              ? null
              : () {
                  final question = _question.text.trim();
                  final base = widget.preset ?? const AskPreset(emoji: '💬', title: '');
                  Navigator.pop(
                    context,
                    base.copyWith(
                      emoji: _emoji.text.trim().isEmpty ? '💬' : _emoji.text.trim(),
                      title: _title.text.trim(),
                      question: question,
                      clearQuestion: question.isEmpty,
                      options: question.isEmpty
                          ? const []
                          : [
                              for (final o in _options.text.split(','))
                                if (o.trim().isNotEmpty) o.trim()
                            ].take(6).toList(),
                      screenMinutes: _minutes,
                      clearMinutes: _minutes == null,
                    ),
                  );
                },
          child: Text(l10n.askOk),
        ),
      ],
    );
  }
}
