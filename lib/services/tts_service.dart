// lib/services/tts_service.dart
//
// Text-to-Speech service with urgency-aware speech control.
// Adjusts speech rate, pitch, and repetition based on proximity urgency.

import 'package:flutter_tts/flutter_tts.dart';

import 'path_analyzer_service.dart' show VoiceUrgency;
import 'read_anything_service.dart' show TextScript, TextSegment;

class TtsService {
  final FlutterTts _tts = FlutterTts();

  // Default language for UI prompts (English, Indian accent)
  static const String _langEnglish = 'en-IN';
  // Hindi
  static const String _langHindi   = 'hi-IN';

  // ── Default speech parameters ─────────────────────────────────────────────
  static const double _defaultRate   = 0.45;
  static const double _defaultPitch  = 1.0;
  static const double _defaultVolume = 1.0;

  TtsService() {
    _tts.setLanguage(_langEnglish);
    _tts.setSpeechRate(_defaultRate);
    _tts.setVolume(_defaultVolume);
    _tts.setPitch(_defaultPitch);
  }

  /// Speak a plain English UI string at default urgency.
  Future<void> speak(String text) async {
    await _tts.stop();
    await _resetToDefaults();
    await _tts.speak(text);
  }

  /// Speak with urgency-controlled speech parameters.
  ///
  /// - [VoiceUrgency.critical] → fast rate, high pitch, double repeat
  /// - [VoiceUrgency.high]     → faster rate, single announce
  /// - [VoiceUrgency.medium]   → normal speech
  /// - [VoiceUrgency.low]      → slightly slower (info only)
  Future<void> speakWithUrgency(String text, VoiceUrgency urgency) async {
    await _tts.stop();

    switch (urgency) {
      case VoiceUrgency.critical:
        // Fast, urgent, and repeated
        await _tts.setLanguage(_langEnglish);
        await _tts.setSpeechRate(0.60);
        await _tts.setPitch(1.2);
        await _tts.setVolume(1.0);
        await _tts.awaitSpeakCompletion(true);
        await _tts.speak(text);
        // Repeat critical warnings once more for emphasis
        await _tts.speak(text);
        break;

      case VoiceUrgency.high:
        // Moderately fast, single announcement
        await _tts.setLanguage(_langEnglish);
        await _tts.setSpeechRate(0.55);
        await _tts.setPitch(1.1);
        await _tts.setVolume(1.0);
        await _tts.speak(text);
        break;

      case VoiceUrgency.medium:
        // Normal speech
        await _resetToDefaults();
        await _tts.speak(text);
        break;

      case VoiceUrgency.low:
        // Calm, slightly slower for informational content
        await _tts.setLanguage(_langEnglish);
        await _tts.setSpeechRate(0.40);
        await _tts.setPitch(0.95);
        await _tts.setVolume(0.9);
        await _tts.speak(text);
        break;
    }
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

  // ── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _resetToDefaults() async {
    await _tts.setLanguage(_langEnglish);
    await _tts.setSpeechRate(_defaultRate);
    await _tts.setPitch(_defaultPitch);
    await _tts.setVolume(_defaultVolume);
  }
}
