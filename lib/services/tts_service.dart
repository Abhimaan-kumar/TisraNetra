// lib/services/tts_service.dart
//
// Text-to-Speech service with urgency-aware speech control.
// Adjusts speech rate, pitch, and repetition based on proximity urgency.
// Respects the user's preferred language (English / Hindi) stored in
// LanguagePreferenceService.

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'language_preference_service.dart';
import 'path_analyzer_service.dart' show VoiceUrgency;
import 'read_anything_service.dart' show TextScript, TextSegment;

class TtsService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;

  final FlutterTts _tts = FlutterTts();

  // ── Default speech parameters ─────────────────────────────────────────────
  static const double _defaultRate   = 0.45;
  static const double _defaultPitch  = 1.0;
  static const double _defaultVolume = 1.0;

  /// Returns the TTS language code based on the user's stored preference.
  String get _preferredLang => LanguagePreferenceService().preferredLanguage;

  TtsService._internal() {
    _tts.setLanguage(_preferredLang);
    _tts.setSpeechRate(_defaultRate);
    _tts.setVolume(_defaultVolume);
    _tts.setPitch(_defaultPitch);
  }

  /// Whether the user prefers Hindi.
  bool get isHindi => LanguagePreferenceService().isHindi;

  /// Speak a plain UI string using the user's preferred language.
  Future<void> speak(String text, {bool awaitCompletion = false}) async {
    await _tts.stop();
    await _resetToDefaults();
    if (awaitCompletion) {
      await _tts.awaitSpeakCompletion(true);
    }
    await _tts.speak(text);
  }

  /// Speak the appropriate text based on user's preferred language.
  /// Pass both English and Hindi text; the correct one is auto-selected.
  Future<void> speakLocalized(String english, String hindi) async {
    await _tts.stop();
    await _resetToDefaults();
    await _tts.speak(isHindi ? hindi : english);
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
        await _tts.setLanguage(_preferredLang);
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
        await _tts.setLanguage(_preferredLang);
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
        await _tts.setLanguage(_preferredLang);
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
          ? LanguagePreferenceService.hindi
          : LanguagePreferenceService.english;

      await _tts.setLanguage(lang);
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak(segment.text.trim());
    }

    // Reset back to the user's preferred language for subsequent UI prompts
    await _tts.setLanguage(_preferredLang);
  }

  /// Register a callback invoked when the current utterance finishes.
  /// Useful for auto-resuming voice input after AI responses.
  void setCompletionHandler(VoidCallback handler) {
    _tts.setCompletionHandler(handler);
  }

  /// Remove any previously registered completion handler.
  void clearCompletionHandler() {
    _tts.setCompletionHandler(() {});
  }

  Future<void> stop() async => await _tts.stop();

  /// Singleton — do NOT dispose the shared engine from individual screens.
  /// Use [stop] instead to cancel current speech.
  void dispose() {
    // No-op: singleton lifecycle is managed by the app, not individual screens.
    // Screens should call stop() in their own dispose() methods.
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _resetToDefaults() async {
    await _tts.setLanguage(_preferredLang);
    await _tts.setSpeechRate(_defaultRate);
    await _tts.setPitch(_defaultPitch);
    await _tts.setVolume(_defaultVolume);
  }
}
