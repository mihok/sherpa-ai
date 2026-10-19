import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController, TextEditingValue, TextSelection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// The platform's speech recognizer behind one fakeable seam.
abstract interface class ChatDictation {
  /// Sets the recognizer up (the first call asks for microphone and speech
  /// permission). False when this phone can't dictate.
  Future<bool> prepare();

  /// Starts listening. [onWords] gets the words so far (replacing earlier
  /// partial results); [onDone] is called once when listening ends, with
  /// a message for the user when it ended because of a problem.
  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
    required void Function(String? problem) onDone,
  });

  /// Stops and keeps what was recognized.
  Future<void> stop();

  /// What happens to the user's voice, in one sentence.
  String get privacyNote;
}

/// [ChatDictation] over `speech_to_text`, asking for on-device
/// recognition: iOS `requiresOnDeviceRecognition` (audio never leaves the
/// phone; if the language has no on-device model, dictation says so
/// rather than quietly using Apple's servers), Android
/// `EXTRA_PREFER_OFFLINE` (a preference the system recognizer may not
/// honour on every phone, which [privacyNote] says).
final class SpeechToTextDictation implements ChatDictation {
  SpeechToTextDictation();

  final SpeechToText _stt = SpeechToText();
  void Function(String? problem)? _onDone;
  bool _ready = false;

  @override
  String get privacyNote => Platform.isIOS
      ? 'Your voice is recognized on this iPhone and is not sent anywhere.'
      : "Sherpa asks your phone's speech service to work offline; some phones may still use their maker's servers.";

  @override
  Future<bool> prepare() async {
    if (_ready) return true;
    try {
      // Listeners are fixed by the first initialize; they forward to the
      // current session.
      _ready = await _stt.initialize(onError: _error, onStatus: _status);
    } on Object catch (e) {
      debugPrint('dictation: $e');
      _ready = false;
    }
    return _ready;
  }

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
    required void Function(String? problem) onDone,
  }) async {
    _onDone = onDone;
    try {
      await _stt.listen(
        onResult: (r) => onWords(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          onDevice: true,
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
          autoPunctuation: true,
          pauseFor: const Duration(seconds: 5),
          listenFor: const Duration(minutes: 2),
        ),
      );
    } on Object catch (e) {
      debugPrint('dictation listen: $e');
      _finish("Dictation couldn't start.");
    }
  }

  @override
  Future<void> stop() => _stt.stop();

  void _status(String status) {
    if (status == SpeechToText.doneStatus || status == 'doneNoResult') _finish(null);
  }

  void _error(SpeechRecognitionError e) => _finish(dictationProblem(e.errorMsg));

  void _finish(String? problem) {
    final done = _onDone;
    _onDone = null;
    done?.call(problem);
  }
}

/// User-facing words for a recognizer error code (null: nothing worth
/// saying, e.g. silence).
String? dictationProblem(String code) => switch (code) {
      'error_permission' || 'error_insufficient_permissions' =>
        'Dictation needs microphone and speech recognition access. Allow it for Sherpa in Settings.',
      'error_no_match' || 'error_speech_timeout' => null,
      'error_network' || 'error_network_timeout' || 'error_server' || 'error_server_disconnected' =>
        "This phone's speech service needs the internet, and Sherpa only asks for offline dictation. "
            'Use your keyboard\'s dictation instead.',
      'error_language_not_supported' || 'error_language_unavailable' =>
        "On-device dictation isn't available for your language on this phone.",
      'error_busy' || 'error_recognizer_busy' => 'The speech service is busy. Try again in a moment.',
      _ => 'Dictation stopped ($code).',
    };

final chatDictationProvider = Provider<ChatDictation?>((ref) => SpeechToTextDictation());

/// Dictation into one composer: recognized words are added after what was
/// already typed, and the partial result is replaced as it improves.
/// Nothing is sent by dictating; the user still taps Send.
final class ComposerDictation extends ChangeNotifier {
  ComposerDictation(this._service, this._text);

  final ChatDictation _service;
  final TextEditingController _text;
  bool _listening = false;
  bool _starting = false;
  String? _problem;
  String _base = '';
  bool _disposed = false;

  bool get listening => _listening;
  String? get problem => _problem;
  String get privacyNote => _service.privacyNote;

  Future<void> toggle() => _listening ? stop() : start();

  Future<void> start() async {
    if (_listening || _starting) return;
    _starting = true;
    _problem = null;
    _notify();
    final ok = await _service.prepare();
    _starting = false;
    if (_disposed) return;
    if (!ok) {
      _problem = "Dictation isn't available. Check that Sherpa may use the microphone and speech recognition.";
      _notify();
      return;
    }
    _base = _text.text;
    _listening = true;
    _notify();
    await _service.listen(onWords: _words, onDone: _done);
  }

  Future<void> stop() async {
    if (!_listening) return;
    await _service.stop();
  }

  void dismissProblem() {
    if (_problem == null) return;
    _problem = null;
    _notify();
  }

  void _words(String words, bool isFinal) {
    if (_disposed || !_listening) return;
    final w = words.trim();
    final sep = _base.isEmpty || _base.endsWith(' ') || _base.endsWith('\n') || w.isEmpty ? '' : ' ';
    final text = '$_base$sep$w';
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _done(String? problem) {
    if (_disposed) return;
    _listening = false;
    _problem = problem;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_listening) unawaited(_service.stop());
    _disposed = true;
    super.dispose();
  }
}
