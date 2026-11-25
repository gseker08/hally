import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'chat_photo.dart';
import 'chat_realtime.dart';
import 'chats_screen.dart';
import 'messages_repository.dart';

/// One chat (family or direct). Loads the latest page, polls for new messages while open and marks them read.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatKey, this.title, this.draft});

  final String chatKey;
  final String? title;

  /// Pre-filled into the message box (never sent on its own), e.g. a request from the load balance page.
  final String? draft;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <FamilyChatMessage>[];
  Timer? _timer;
  StreamSubscription<ChatMessageEvent>? _live;
  int _ticks = 0;
  bool _loading = true;
  bool _failed = false;
  bool _sending = false;
  bool _hasOlder = false;
  bool _polling = false;

  String? get _familyId => ref.read(meProvider).valueOrNull?.primaryFamily?.id;
  MessagesRepository get _repo => ref.read(messagesRepositoryProvider);

  @override
  void initState() {
    super.initState();
    if (widget.draft case final draft? when draft.isNotEmpty) _input.text = draft;
    _load();
    _live = ref.read(chatRealtimeProvider).events.listen(_onLive);
    _timer = Timer.periodic(chatPollInterval, (_) {
      // With a live connection a slow safety poll is enough; without one, poll every tick.
      if (!ref.read(chatRealtimeProvider).isConnected || ++_ticks % 6 == 0) _poll();
    });
  }

  void _onLive(ChatMessageEvent e) {
    if (e.chatKey != widget.chatKey || e.familyId != _familyId || _loading) return;
    if (_messages.any((m) => m.id == e.message.id)) return;
    setState(() => _messages.add(e.message));
    _markRead();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _live?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      // Opened from a notification the profile may still be loading.
      final familyId = _familyId ?? (await ref.read(meProvider.future))?.primaryFamily?.id;
      if (familyId == null) throw StateError('no family');
      final page = await _repo.messages(familyId, widget.chatKey);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(page);
        _hasOlder = page.length >= 50;
        _loading = false;
      });
      _markRead();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _loadOlder() async {
    final familyId = _familyId;
    if (familyId == null || _messages.isEmpty) return;
    try {
      final older = await _repo.messages(familyId, widget.chatKey, before: _messages.first.createdAt);
      if (!mounted) return;
      setState(() {
        _messages.insertAll(0, older);
        _hasOlder = older.length >= 50;
      });
    } catch (_) {
      _showError();
    }
  }

  Future<void> _poll() async {
    final familyId = _familyId;
    if (familyId == null || _loading || _polling) return;
    _polling = true;
    try {
      final fresh = _messages.isEmpty
          ? await _repo.messages(familyId, widget.chatKey)
          : await _repo.messages(familyId, widget.chatKey, after: _messages.last.createdAt);
      final known = _messages.map((m) => m.id).toSet();
      final added = fresh.where((m) => !known.contains(m.id)).toList();
      if (added.isNotEmpty && mounted) {
        setState(() => _messages.addAll(added));
        _markRead();
      }
    } catch (_) {
      // Polling is quiet: the next tick tries again.
    } finally {
      _polling = false;
    }
  }

  void _markRead() {
    final familyId = _familyId;
    if (familyId == null || _messages.isEmpty) return;
    _repo.markRead(familyId, widget.chatKey).then((_) => ref.invalidate(chatListProvider(familyId))).catchError((_) {});
  }

  Future<void> _send() async {
    final familyId = _familyId;
    final text = _input.text.trim();
    if (familyId == null || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final sent = await _repo.send(familyId, widget.chatKey, text);
      if (!mounted) return;
      _input.clear();
      setState(() {
        if (!_messages.any((m) => m.id == sent.id)) _messages.add(sent);
      });
    } catch (_) {
      _showError();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Camera or gallery, then a full-screen preview with an optional caption (prefilled with what was typed).
  Future<void> _sendPhoto() async {
    final familyId = _familyId;
    if (familyId == null || _sending) return;
    final source = await askPhotoSource(context);
    if (source == null || !mounted) return;
    final PickedPhoto? photo;
    try {
      photo = await ref.read(photoPickerProvider)(source);
    } catch (_) {
      // No permission for the camera or photos, or no camera at all.
      _showError(AppLocalizations.of(context).chatPhotoPickFailed);
      return;
    }
    if (photo == null || !mounted) return;
    final typed = _input.text.trim();
    final caption = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PhotoPreviewPage(photo: photo!, caption: typed),
    ));
    if (caption == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final sent = await _repo.sendPhoto(familyId, widget.chatKey, photo.bytes, photo.fileName, photo.contentType, caption: caption);
      if (!mounted) return;
      if (typed.isNotEmpty) _input.clear();
      setState(() {
        if (!_messages.any((m) => m.id == sent.id)) _messages.add(sent);
      });
    } catch (_) {
      if (mounted) _showError(AppLocalizations.of(context).chatPhotoSendFailed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showError([String? text]) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text ?? AppLocalizations.of(context).errorGeneric)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final myId = ref.watch(meProvider).valueOrNull?.id;
    final isFamily = widget.chatKey == familyChatKey;
    final title = widget.title ?? (isFamily ? l10n.chatFamily : l10n.chatsTitle);

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const HallyLoading()
                : _failed
                    ? HallyErrorState(onRetry: _load)
                    : _messages.isEmpty
                        ? HallyEmptyState(
                            icon: Icons.chat_bubble_outline_rounded,
                            title: isFamily ? l10n.chatFamilyEmpty : l10n.chatDirectEmpty,
                            body: isFamily ? l10n.chatFamilyEmptyBody : l10n.chatDirectEmptyBody,
                          )
                        : ListView.builder(
                            key: const Key('chat.messages'),
                            controller: _scroll,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, HallySpace.sm),
                            itemCount: _messages.length + (_hasOlder ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (i == _messages.length) {
                                return Center(
                                  child: TextButton(key: const Key('chat.older'), onPressed: _loadOlder, child: Text(l10n.chatOlder)),
                                );
                              }
                              final index = _messages.length - 1 - i;
                              final m = _messages[index];
                              final previous = index > 0 ? _messages[index - 1] : null;
                              final mine = m.senderUserId == myId;
                              final showName = isFamily && !mine && previous?.senderUserId != m.senderUserId;
                              return _Bubble(message: m, mine: mine, showName: showName, familyId: _familyId ?? '', chatKey: widget.chatKey);
                            },
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(HallySpace.xs, HallySpace.xs, HallySpace.sm, HallySpace.sm),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('chat.photo'),
                    tooltip: l10n.chatPhotoAdd,
                    onPressed: _sending ? null : _sendPhoto,
                    icon: const Icon(Icons.add_photo_alternate_rounded),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('chat.input'),
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(hintText: l10n.chatHint, counterText: ''),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: HallySpace.xs),
                  IconButton.filled(
                    key: const Key('chat.send'),
                    tooltip: l10n.chatSend,
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.showName, required this.familyId, required this.chatKey});

  final FamilyChatMessage message;
  final bool mine;
  final bool showName;
  final String familyId;
  final String chatKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final fg = mine ? Colors.white : theme.colorScheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Padding(
          padding: EdgeInsets.only(top: showName ? HallySpace.sm : 2, bottom: 2),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(left: HallySpace.sm, bottom: 2),
                  child: Text(message.senderName ?? l10n.chatFormerMember, style: theme.textTheme.labelMedium),
                ),
              Container(
                padding: message.hasPhoto ? const EdgeInsets.fromLTRB(4, 4, 4, 7) : const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: mine ? HallyColors.cherry : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(mine ? 18 : 4),
                    bottomRight: Radius.circular(mine ? 4 : 18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.linkTitle != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(message.taskId != null ? Icons.check_circle_outline_rounded : Icons.event_rounded, size: 16, color: fg),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(message.linkTitle!,
                                  style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      ),
                    if (message.hasPhoto) ChatPhoto(familyId: familyId, chatKey: chatKey, messageId: message.id),
                    Padding(
                      padding: message.hasPhoto ? const EdgeInsets.fromLTRB(10, 6, 10, 0) : EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (message.body.isNotEmpty) Text(message.body, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                          const SizedBox(height: 2),
                          Text(chatTime(context, message.createdAt),
                              style: theme.textTheme.labelSmall?.copyWith(color: mine ? Colors.white70 : theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
