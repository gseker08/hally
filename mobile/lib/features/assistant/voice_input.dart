import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../../core/locale/app_language.dart';

/// Speech to text for "Hally'ye söyle". The phone's own recognizer turns speech into text (Google on Android,
/// Apple on the iPhone); only the text goes on to the assistant, like a typed message.
abstract interface class VoiceInput {
  /// Asks for the microphone (and on the iPhone, speech recognition) the first time. False when refused or
  /// when the phone has no recognizer.
  Future<bool> ensureReady();

  /// Listens once. [onText] gets the words so far; [onDone] fires once with the final words (empty when
  /// nothing was understood), also after [stop].
  Future<void> listen({required String localeId, required void Function(String words) onText, required void Function(String words) onDone});

  Future<void> stop();

  Future<void> cancel();
}

/// Picks the recognizer's language for the app's, e.g. tr_TR for Turkish.
String voiceLocaleFor(String languageCode) => speechLocaleFor(languageCode);

final voiceInputProvider = Provider<VoiceInput>((ref) => SpeechToTextVoiceInput());

class SpeechToTextVoiceInput implements VoiceInput {
  final _speech = SpeechToText();
  bool? _ready;
  String _words = '';
  void Function(String words)? _onDone;

  @override
  Future<bool> ensureReady() async {
    if (_ready == true) return true;
    try {
      _ready = await _speech.initialize(onStatus: _status, onError: _error);
    } catch (e) {
      debugPrint('voice: $e');
      _ready = false;
    }
    return _ready!;
  }

  @override
  Future<void> listen({required String localeId, required void Function(String words) onText, required void Function(String words) onDone}) async {
    _words = '';
    _onDone = onDone;
    await _speech.listen(
      localeId: localeId,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation, cancelOnError: true),
      onResult: (SpeechRecognitionResult r) {
        _words = r.recognizedWords;
        onText(_words);
        if (r.finalResult) _finish();
      },
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() async {
    _onDone = null;
    await _speech.cancel();
  }

  void _status(String status) {
    // A pause or the time limit ends listening without a final result on some phones.
    if (status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) {
      // The final result can arrive just after "notListening"; give it a moment.
      Future<void>.delayed(const Duration(milliseconds: 400), _finish);
    }
  }

  void _error(SpeechRecognitionError e) {
    debugPrint('voice: ${e.errorMsg}');
    _finish();
  }

  void _finish() {
    final done = _onDone;
    _onDone = null;
    done?.call(_words.trim());
  }
}
