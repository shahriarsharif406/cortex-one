import 'package:speech_to_text/speech_to_text.dart';

/// Voice typing. Recognised words go into the command box for editing; they
/// are never sent automatically.
abstract class VoiceInput {
  /// False when the device has no speech service or permission was refused.
  Future<bool> init();

  /// [localeId] is `bn_BD` or `en_US`. [onWords] receives the text so far.
  Future<void> listen(
    String localeId,
    void Function(String words, bool finished) onWords,
  );
  Future<void> stop();
  bool get isListening;
}

class SpeechVoiceInput implements VoiceInput {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;

  @override
  Future<bool> init() async {
    if (_ready) return true;
    try {
      _ready = await _stt.initialize();
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  @override
  Future<void> listen(
    String localeId,
    void Function(String words, bool finished) onWords,
  ) async {
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        cancelOnError: true,
      ),
      onResult: (r) => onWords(r.recognizedWords, r.finalResult),
    );
  }

  @override
  Future<void> stop() => _stt.stop();

  @override
  bool get isListening => _stt.isListening;
}
