import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/assistant/assistant_repository.dart';
import 'package:hally/features/assistant/assistant_screen.dart';
import 'package:hally/features/assistant/voice_input.dart';
import 'package:hally/features/assistant/voice_launch.dart';
import 'package:hally/features/capture/capture_models.dart';
import 'package:hally/features/privacy/ai_consent.dart';
import 'package:hally/features/privacy/privacy_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeAssistant implements AssistantRepository {
  final sent = <(String, String?)>[];

  @override
  Future<AssistantReply> send(String familyId, String text, {String? conversationId}) async {
    sent.add((text, conversationId));
    final proposals = text.contains('ekle')
        ? [
            Proposal.fromJson({
              'id': 'p1',
              'kind': 'CreateEvent',
              'status': 'Pending',
              'payload': {'title': 'Yüzme dersi', 'date': '2026-11-14', 'time': '17:00', 'needsInfo': <String>[], 'confidence': 'medium'},
            }),
          ]
        : <Proposal>[];
    return AssistantReply(
      conversationId: 'c1',
      reply: ChatEntry(id: 'm${sent.length}', fromUser: false, text: proposals.isEmpty ? 'Yarın: Okul gezisi (09:00)' : 'Ekledim, onayını bekliyor.', proposals: proposals),
    );
  }
}

class _MemoryConsent implements AiConsentStorage {
  bool granted = false;

  @override
  Future<bool> read() async => granted;

  @override
  Future<void> write(bool value) async => granted = value;
}

/// Speech to text that "hears" whatever the test says.
class _FakeVoice implements VoiceInput {
  bool ready = true;
  String? localeId;
  void Function(String)? _onText;
  void Function(String)? _onDone;

  bool get listening => _onDone != null;

  void say(String words) => _onText?.call(words);

  void finish(String words) {
    final done = _onDone;
    _onDone = null;
    done?.call(words);
  }

  @override
  Future<bool> ensureReady() async => ready;

  @override
  Future<void> listen({required String localeId, required void Function(String words) onText, required void Function(String words) onDone}) async {
    this.localeId = localeId;
    _onText = onText;
    _onDone = onDone;
  }

  @override
  Future<void> stop() async => finish('Yarın ne var');

  @override
  Future<void> cancel() async => _onDone = null;
}

Widget _app(_FakeAssistant repo, _MemoryConsent consent, {_FakeVoice? voice, bool startVoice = false}) => ProviderScope(
      overrides: [
        voiceInputProvider.overrideWithValue(voice ?? _FakeVoice()),
        meProvider.overrideWith((ref) async => _me),
        assistantRepositoryProvider.overrideWithValue(repo),
        aiConsentStorageProvider.overrideWithValue(consent),
        privacyInfoProvider.overrideWith(
          (ref) async => const PrivacyInfo(aiProviderNoTraining: false, aiProviderName: 'TestAI', originalsRetentionDays: 30),
        ),
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
        home: AssistantScreen(startVoice: startVoice),
      ),
    );

void main() {
  testWidgets('starter question gets an answer and the conversation continues', (tester) async {
    // A phone-sized surface: the default 800x600 test window leaves the starters under the input bar.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final repo = _FakeAssistant();
    final consent = _MemoryConsent();
    await tester.pumpWidget(_app(repo, consent));
    await tester.pumpAndSettle();

    final starter = find.byKey(const Key('assistant.starter.0'));
    await tester.ensureVisible(starter);
    await tester.pumpAndSettle();

    // The first message asks for the AI consent; "Not now" sends nothing.
    await tester.tap(starter);
    await tester.pumpAndSettle();
    expect(find.textContaining('TestAI'), findsOneWidget);
    await tester.tap(find.byKey(const Key('aiConsent.decline')));
    await tester.pumpAndSettle();
    expect(repo.sent, isEmpty);
    expect(consent.granted, isFalse);

    await tester.tap(starter);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiConsent.accept')));
    await tester.pumpAndSettle();
    expect(consent.granted, isTrue);
    expect(find.text('Yarın ne lazım?'), findsOneWidget);
    expect(find.text('Yarın: Okul gezisi (09:00)'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('assistant.input')), 'Yarın 17:00\'de yüzme dersi ekle');
    await tester.tap(find.byKey(const Key('assistant.send')));
    await tester.pumpAndSettle();
    expect(repo.sent.last.$2, 'c1', reason: 'follow-up messages stay in the same conversation');
    expect(find.text('Yüzme dersi · 2026-11-14 · 17:00'), findsOneWidget);
    expect(find.byKey(const Key('assistant.review.m2')), findsOneWidget);
  });

  testWidgets('speaking sends the words as a message', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final repo = _FakeAssistant();
    final consent = _MemoryConsent()..granted = true;
    final voice = _FakeVoice();
    await tester.pumpWidget(_app(repo, consent, voice: voice));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('assistant.voice')));
    await tester.pumpAndSettle();
    expect(voice.listening, isTrue);
    expect(voice.localeId, 'tr_TR');
    expect(find.text('Dinliyorum… konuşabilirsin'), findsOneWidget);

    // Words appear in the field while the parent speaks; the message goes when they stop.
    voice.say('Yarın saat beşte');
    await tester.pump();
    expect(find.text('Yarın saat beşte'), findsOneWidget);
    voice.finish('Yarın saat beşte yüzme dersi ekle');
    await tester.pumpAndSettle();
    expect(repo.sent.single.$1, 'Yarın saat beşte yüzme dersi ekle');
    expect(find.text('Yüzme dersi · 2026-11-14 · 17:00'), findsOneWidget);

    // The stop button sends what was heard so far.
    await tester.tap(find.byKey(const Key('assistant.voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assistant.voice')));
    await tester.pumpAndSettle();
    expect(repo.sent.last.$1, 'Yarın ne var');

    // Silence sends nothing.
    await tester.tap(find.byKey(const Key('assistant.voice')));
    await tester.pumpAndSettle();
    voice.finish('');
    await tester.pumpAndSettle();
    expect(repo.sent, hasLength(2));
    expect(find.text('Seni duyamadım. Tekrar dener misin?'), findsOneWidget);
  });

  testWidgets('voice asks for the AI consent before listening, and opens listening from the widget link', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final consent = _MemoryConsent();
    final voice = _FakeVoice();
    await tester.pumpWidget(_app(_FakeAssistant(), consent, voice: voice, startVoice: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('aiConsent.decline')), findsOneWidget);
    expect(voice.listening, isFalse);
    await tester.tap(find.byKey(const Key('aiConsent.accept')));
    await tester.pumpAndSettle();
    expect(voice.listening, isTrue);

    expect(isVoiceLaunchUri(Uri.parse('hally://voice')), isTrue);
    expect(isVoiceLaunchUri(Uri.parse('hally://timer/stop')), isFalse);
    expect(isVoiceLaunchUri(null), isFalse);
  });

  testWidgets('a phone without a recognizer says so', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final voice = _FakeVoice()..ready = false;
    await tester.pumpWidget(_app(_FakeAssistant(), _MemoryConsent()..granted = true, voice: voice));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assistant.voice')));
    await tester.pumpAndSettle();
    expect(voice.listening, isFalse);
    expect(find.textContaining('Mikrofon kullanılamıyor'), findsOneWidget);
  });

  test('speech language follows the app language', () {
    expect(voiceLocaleFor('tr'), 'tr_TR');
    expect(voiceLocaleFor('en'), 'en_US');
  });
}
