import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:hally/features/messages/chat_photo.dart';

import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/messages/chat_screen.dart';
import 'package:hally/features/messages/chats_screen.dart';
import 'package:hally/features/messages/messages_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeMessages implements MessagesRepository {
  final byKey = <String, List<FamilyChatMessage>>{};
  final read = <String>[];
  var _n = 0;

  final photos = <String, ({String key, String contentType, String? caption})>{};

  FamilyChatMessage add(String key, String sender, String body, {String? name, bool photo = false}) {
    final m = FamilyChatMessage(
      id: 'm${_n++}',
      senderUserId: sender,
      senderName: name,
      body: body,
      createdAt: DateTime.utc(2026, 11, 22, 10, _n),
      hasPhoto: photo,
    );
    byKey.putIfAbsent(key, () => []).add(m);
    return m;
  }

  @override
  Future<ChatList> chats(String familyId) async {
    final chats = [
      ChatSummary(key: familyChatKey, isFamily: true, lastMessage: byKey[familyChatKey]?.last, unread: read.contains(familyChatKey) ? 0 : 2),
      ChatSummary(key: 'u2', isFamily: false, otherUserId: 'u2', otherName: 'Mehmet', lastMessage: byKey['u2']?.last, unread: 0),
    ];
    return ChatList(chats: chats, totalUnread: chats.fold(0, (a, c) => a + c.unread));
  }

  @override
  Future<List<FamilyChatMessage>> messages(String familyId, String key, {DateTime? after, DateTime? before}) async {
    final all = byKey[key] ?? [];
    if (after != null) return all.where((m) => m.createdAt.isAfter(after)).toList();
    return List.of(all);
  }

  @override
  Future<FamilyChatMessage> send(String familyId, String key, String body, {String? taskId, String? eventId}) async => add(key, 'u1', body);

  @override
  Future<void> markRead(String familyId, String key) async => read.add(key);

  @override
  Future<FamilyChatMessage> sendPhoto(String familyId, String key, List<int> bytes, String fileName, String contentType, {String? caption}) async {
    final m = add(key, 'u1', caption ?? '', photo: true);
    photos[m.id] = (key: key, contentType: contentType, caption: caption);
    return m;
  }

  @override
  Future<Uint8List> photo(String familyId, String key, String messageId) async => _png;
}

// 1x1 transparent PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

class _FakeRealtime implements ChatRealtime {
  final controller = StreamController<ChatMessageEvent>.broadcast();
  @override
  bool isConnected = false;

  @override
  Stream<ChatMessageEvent> get events => controller.stream;

  @override
  Stream<Map<String, dynamic>> get medicationEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get shoppingEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get sleepEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get feedingEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get studyEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get pointsEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get habitsEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get dutiesEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get expensesEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get healthEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get screenTimeEvents => const Stream.empty();

  @override
  Future<void> dispose() => controller.close();
}

Widget _app(Widget child, _FakeMessages repo, {ChatRealtime? realtime, PhotoPicker? picker}) => ProviderScope(
      overrides: [
        if (picker != null) photoPickerProvider.overrideWithValue(picker),
        meProvider.overrideWith((ref) async => _me),
        messagesRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(realtime ?? NoChatRealtime()),
      ],
      child: MaterialApp(
        theme: buildHallyTheme(Brightness.light),
        locale: const Locale('tr'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('chat list shows the family chat first with its unread count', (tester) async {
    _phone(tester);
    final repo = _FakeMessages()..add(familyChatKey, 'u2', 'Akşam yemeği bende', name: 'Mehmet Yılmaz');
    await tester.pumpWidget(_app(const ChatsScreen(), repo));
    await tester.pumpAndSettle();

    expect(find.text('Aile sohbeti'), findsOneWidget);
    expect(find.text('Mehmet: Akşam yemeği bende'), findsOneWidget);
    expect(find.byKey(const Key('chat.family.unread')), findsOneWidget);
    expect(find.text('Mehmet'), findsOneWidget);
    expect(find.text('Henüz mesaj yok'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a chat shows names in the family chat, sends, and picks up new messages', (tester) async {
    _phone(tester);
    final repo = _FakeMessages()..add(familyChatKey, 'u2', 'Okuldan kim alıyor?', name: 'Mehmet');
    await tester.pumpWidget(_app(const ChatScreen(chatKey: familyChatKey), repo));
    await tester.pumpAndSettle();

    expect(find.text('Mehmet'), findsOneWidget);
    expect(find.text('Okuldan kim alıyor?'), findsOneWidget);
    expect(repo.read, contains(familyChatKey));

    await tester.enterText(find.byKey(const Key('chat.input')), 'Ben alırım');
    await tester.tap(find.byKey(const Key('chat.send')));
    await tester.pumpAndSettle();
    expect(find.text('Ben alırım'), findsOneWidget);
    expect(repo.byKey[familyChatKey]!.last.senderUserId, 'u1');

    repo.add(familyChatKey, 'u2', 'Teşekkürler!', name: 'Mehmet');
    await tester.pump(chatPollInterval);
    await tester.pumpAndSettle();
    expect(find.text('Teşekkürler!'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a live event shows up at once, without waiting for a poll', (tester) async {
    _phone(tester);
    final repo = _FakeMessages()..add('u2', 'u2', 'Merhaba', name: 'Mehmet');
    final live = _FakeRealtime()..isConnected = true;
    await tester.pumpWidget(_app(const ChatScreen(chatKey: 'u2', title: 'Mehmet'), repo, realtime: live));
    await tester.pumpAndSettle();
    repo.read.clear();

    final message = repo.add('u2', 'u2', 'Yoldayım', name: 'Mehmet');
    live.controller.add(ChatMessageEvent(familyId: 'f1', chatKey: 'u2', message: message));
    // Another chat's event is ignored.
    live.controller.add(ChatMessageEvent(familyId: 'f1', chatKey: familyChatKey, message: repo.add(familyChatKey, 'u3', 'Başka sohbet')));
    await tester.pump(); // deliver the stream events
    await tester.pump(); // rebuild
    expect(find.text('Yoldayım'), findsOneWidget);
    expect(find.text('Başka sohbet'), findsNothing);
    expect(repo.read, ['u2']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an empty direct chat explains it is private', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ChatScreen(chatKey: 'u2', title: 'Mehmet'), _FakeMessages()));
    await tester.pumpAndSettle();
    expect(find.text('Bu yazışmayı yalnızca ikiniz görürsünüz.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a photo is picked, previewed with a caption, sent and opened full screen', (tester) async {
    _phone(tester);
    final repo = _FakeMessages()..add('u2', 'u2', 'Karneyi gönderir misin?', name: 'Mehmet');
    ImageSource? asked;
    Future<PickedPhoto?> picker(ImageSource source) async {
      asked = source;
      return PickedPhoto(bytes: _png, fileName: 'IMG_1.jpg', contentType: PickedPhoto.contentTypeOf('IMG_1.jpg'));
    }

    await tester.pumpWidget(_app(const ChatScreen(chatKey: 'u2', title: 'Mehmet'), repo, picker: picker));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat.photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat.photo.gallery')));
    await tester.pumpAndSettle();
    expect(asked, ImageSource.gallery);
    expect(find.byKey(const Key('chat.photo.preview')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat.photo.caption')), 'İşte karne');
    await tester.tap(find.byKey(const Key('chat.photo.send')));
    await tester.pumpAndSettle();

    final sent = repo.byKey['u2']!.last;
    expect(sent.hasPhoto, isTrue);
    expect(repo.photos[sent.id]!.contentType, 'image/jpeg');
    expect(find.text('İşte karne'), findsOneWidget);
    expect(find.byKey(Key('chat.photo.${sent.id}')), findsOneWidget);

    await tester.tap(find.byKey(Key('chat.photo.${sent.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat.photo.viewer')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the chat list shows a photo as "📷 Fotoğraf"', (tester) async {
    _phone(tester);
    final repo = _FakeMessages()..add(familyChatKey, 'u2', '', name: 'Mehmet Yılmaz', photo: true);
    await tester.pumpWidget(_app(const ChatsScreen(), repo));
    await tester.pumpAndSettle();
    expect(find.text('Mehmet: 📷 Fotoğraf'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
