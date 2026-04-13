import 'package:flutter_tts/flutter_tts.dart';

import 'read_anything_service.dart' show TextScript, TextSegment;

class TtsService {
  final FlutterTts _tts = FlutterTts();

  // Default language for UI prompts (English, Indian accent)
  static const String _langEnglish = 'en-IN';
  // Hindi
  static const String _langHindi   = 'hi-IN';

  TtsService() {
    _tts.setLanguage(_langEnglish);
    _tts.setSpeechRate(0.45);
    _tts.setVolume(1.0);
    _tts.setPitch(1.0);
  }

  /// Speak a plain English UI string.
  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.setLanguage(_langEnglish);
    await _tts.speak(text);
  }

  /// Speak mixed-language segments (English + Hindi).
  /// Switches the TTS language per segment so each part is pronounced correctly.
  Future<void> speakSegments(List<TextSegment> segments) async {
    await _tts.stop();

    for (final segment in segments) {
      if (segment.text.trim().isEmpty) continue;

      final lang = segment.script == TextScript.devanagiri
          ? _langHindi
          : _langEnglish;

      await _tts.setLanguage(lang);
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak(segment.text.trim());
    }

    // Reset back to English for subsequent UI prompts
    await _tts.setLanguage(_langEnglish);
  }

  Future<void> stop() async => await _tts.stop();

  void dispose() => _tts.stop();
}
