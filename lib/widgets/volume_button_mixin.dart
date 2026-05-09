// lib/widgets/volume_button_mixin.dart
//
// Drop this mixin onto any feature screen.
// The screen must implement:
//   • onVolumeUp()               – what volume-up does on this screen
//   • handleFeatureVoiceCommand(command, language) – handle the spoken text
//
// Volume-up behaviour:
//   First press  → start listening for a voice command
//   While already listening → cancel listening
//   Volume-down → always navigates back to home (pops the route)

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/tts_service.dart';
import '../services/volume_button_service.dart';

mixin VolumeButtonMixin<T extends StatefulWidget> on State<T> {
  // ── Internal state ──────────────────────────────────────────────────────────
  final VolumeButtonService _volService = VolumeButtonService();
  final stt.SpeechToText    _mixinStt   = stt.SpeechToText();
  final TtsService          _mixinTts   = TtsService();

  bool _mixinListening  = false;
  bool _mixinSttReady   = false;

  // ── Abstract methods screens must implement ─────────────────────────────────

  /// Called when volume-up is pressed AND no voice command was detected,
  /// or when the screen wants a direct "scan again / repeat" action.
  /// Most screens override this to do "scan again".
  Future<void> onVolumeUp() async {}

  /// Called with the recognised voice command text and detected language.
  /// Language is 'hi' for Hindi, 'en' for English.
  Future<void> handleFeatureVoiceCommand(
      String command, String language) async {}

  // ── Init / dispose ───────────────────────────────────────────────────────────

  /// Call from initState() of any screen that uses this mixin.
  void initVolumeButtonListener() {
    _initStt();
    _volService.initialize(
      onVolumeUp: _handleVolumeUp,
      onVolumeDown: _handleVolumeDown,
    );
  }

  Future<void> _initStt() async {
    _mixinSttReady = await _mixinStt.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) {
          setState(() => _mixinListening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _mixinListening = false);
      },
    );
  }

  @override
  void dispose() {
    _volService.dispose();
    _mixinStt.cancel();
    super.dispose();
  }

  // ── Volume handlers ──────────────────────────────────────────────────────────

  Future<void> _handleVolumeUp() async {
    if (_mixinListening) {
      // Second press while listening → cancel and just do direct action
      await _mixinStt.stop();
      if (mounted) setState(() => _mixinListening = false);
      await onVolumeUp();
      return;
    }

    if (!_mixinSttReady) {
      // STT not available → fall back to direct action
      await onVolumeUp();
      return;
    }

    // Start listening
    await _mixinTts.stop();
    if (mounted) setState(() => _mixinListening = true);
    await _mixinTts.speakLocalized('Listening', 'सुन रहा हूँ');
    await Future.delayed(const Duration(milliseconds: 600)); // wait for TTS to start/finish

    await _mixinStt.listen(
      onResult: (result) async {
        if (!mounted) return;
        final words = result.recognizedWords.toLowerCase().trim();
        if (result.finalResult) {
          setState(() => _mixinListening = false);
          if (words.isEmpty) {
            await onVolumeUp(); // no words → default action
          } else {
            final lang = _detectLang(words);
            await handleFeatureVoiceCommand(words, lang);
          }
        }
      },
      listenFor: const Duration(seconds: 7),
      pauseFor: const Duration(seconds: 2),
      listenOptions: stt.SpeechListenOptions(
        partialResults: false,
        cancelOnError: true,
        listenMode: stt.ListenMode.confirmation,
      ),
    );
  }

  Future<void> _handleVolumeDown() async {
    await _mixinTts.speakLocalized('Going back', 'वापस जा रहे हैं');
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  // ── Language detection ───────────────────────────────────────────────────────

  /// Returns 'hi' if Devanagari characters found, else 'en'.
  String _detectLang(String text) {
    return RegExp(r'[\u0900-\u097F]').hasMatch(text) ? 'hi' : 'en';
  }

  // ── Expose listening state to the screen ────────────────────────────────────

  bool get isMixinListening => _mixinListening;
}