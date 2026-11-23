import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import 'chat_realtime.dart';
import 'messages_repository.dart';

/// How often an open chat list or chat checks for new messages.
const chatPollInterval = Duration(seconds: 5);

/// How often the unread badge refreshes while the app shows it.
const chatBadgeInterval = Duration(seconds: 30);

/// Family chat first, then a direct chat with each other adult.
class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  Timer? _timer;
  StreamSubscription<ChatMessageEvent>? _live;

  void _refresh() {
    final familyId = ref.read(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId != null) ref.invalidate(chatListProvider(familyId));
  }

  @override
  void initState() {
    super.initState();
    _live = ref.read(chatRealtimeProvider).events.listen((_) => _refresh());
    _timer = Timer.periodic(chatPollInterval, (_) {
      if (!ref.read(chatRealtimeProvider).isConnected) _refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _live?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final me = ref.watch(meProvider).valueOrNull;
    final familyId = me?.primaryFamily?.id;
    if (me == null || familyId == null) return const Scaffold(body: HallyLoading());
    final chats = ref.watch(chatListProvider(familyId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.chatsTitle)),
      body: chats.when(
        skipLoadingOnRefresh: true,
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(chatListProvider(familyId))),
        data: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(chatListProvider(familyId).future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 120),
            children: [
              for (final c in list.chats) _ChatTile(chat: c, myId: me.id),
              if (list.chats.length == 1)
                Padding(
                  padding: const EdgeInsets.only(top: HallySpace.md),
                  child: Card(
                    child: ListTile(
                      key: const Key('chats.invite'),
                      leading: const HallyIconBadge(icon: Icons.person_add_alt_1_rounded, color: HallyColors.mint),
                      title: Text(l10n.chatsAlone),
                      subtitle: Text(l10n.chatsAloneBody),
                      onTap: () => context.push('/family/$familyId/invite'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  const _ChatTile({required this.chat, required this.myId});

  final ChatSummary chat;
  final String myId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final last = chat.lastMessage;
    final title = chat.isFamily ? l10n.chatFamily : (chat.otherName ?? l10n.chatFormerMember);
    // A photo shows as "📷 Fotoğraf", or "📷 caption" when it has one.
    final text = last == null || !last.hasPhoto ? last?.body ?? '' : '📷 ${last.body.isEmpty ? l10n.chatPhoto : last.body}';
    final preview = last == null
        ? (chat.isFamily ? l10n.chatFamilyEmpty : l10n.chatDirectEmpty)
        : last.senderUserId == myId
            ? l10n.chatYou(text)
            : chat.isFamily
                ? '${_firstName(last.senderName ?? l10n.chatFormerMember)}: $text'
                : text;
    return Card(
      child: ListTile(
        key: Key('chat.${chat.key}'),
        leading: chat.isFamily
            ? const HallyIconBadge(icon: Icons.forum_rounded, color: HallyColors.cherry, size: 44)
            : HallyAvatar(name: chat.otherName ?? '?', size: 44),
        title: Text(title, style: theme.textTheme.titleMedium),
        subtitle: Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: chat.unread > 0 ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700) : null,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (last != null) Text(chatTime(context, last.createdAt), style: theme.textTheme.labelSmall),
            if (chat.unread > 0) ...[
              const SizedBox(height: 4),
              Badge(key: Key('chat.${chat.key}.unread'), label: Text('${chat.unread}'), backgroundColor: HallyColors.cherry),
            ],
          ],
        ),
        onTap: () async {
          final familyId = ref.read(meProvider).valueOrNull?.primaryFamily?.id;
          await context.push('/chats/${chat.key}', extra: title);
          if (familyId != null) ref.invalidate(chatListProvider(familyId));
        },
      ),
    );
  }
}

String _firstName(String name) => name.trim().split(' ').first;

/// "14:05" today, otherwise a short date.
String chatTime(BuildContext context, DateTime utc) {
  final local = utc.toLocal();
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateUtils.isSameDay(local, DateTime.now()) ? DateFormat.Hm(locale).format(local) : DateFormat.MMMd(locale).format(local);
}

/// Chat icon with the unread count, for the Today header. Updates on live events, and every [chatBadgeInterval] as a fallback.
class ChatsButton extends ConsumerStatefulWidget {
  const ChatsButton({super.key, this.color = Colors.white});

  final Color color;

  @override
  ConsumerState<ChatsButton> createState() => _ChatsButtonState();
}

class _ChatsButtonState extends ConsumerState<ChatsButton> {
  Timer? _timer;
  StreamSubscription<ChatMessageEvent>? _live;

  void _refresh() {
    final familyId = ref.read(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId != null) ref.invalidate(chatListProvider(familyId));
  }

  void _listen(ChatRealtime realtime) {
    _live?.cancel();
    _live = realtime.events.listen((_) => _refresh());
  }

  @override
  void initState() {
    super.initState();
    // Reading the provider here also opens the live connection once the user is signed in.
    _listen(ref.read(chatRealtimeProvider));
    _timer = Timer.periodic(chatBadgeInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _live?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A new sign-in replaces the connection: follow it.
    ref.listen(chatRealtimeProvider, (_, next) => _listen(next));
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    final unread = familyId == null ? 0 : ref.watch(chatListProvider(familyId)).valueOrNull?.totalUnread ?? 0;
    return IconButton(
      key: const Key('today.chats'),
      tooltip: AppLocalizations.of(context).chatsTitle,
      onPressed: () async {
        await context.push('/chats');
        if (familyId != null) ref.invalidate(chatListProvider(familyId));
      },
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text('$unread'),
        backgroundColor: HallyColors.rose,
        child: Icon(Icons.chat_bubble_outline_rounded, color: widget.color),
      ),
    );
  }
}
