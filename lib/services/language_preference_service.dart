// lib/services/language_preference_service.dart
//
// Singleton service that holds the user's preferred TTS language
// (English or Hindi). Loaded from Firestore at login/startup and
// consulted by TtsService for every utterance.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class LanguagePreferenceService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final LanguagePreferenceService _instance =
      LanguagePreferenceService._internal();
  factory LanguagePreferenceService() => _instance;
  LanguagePreferenceService._internal();

  // ── Supported language codes ───────────────────────────────────────────────
  static const String english = 'en-IN';
  static const String hindi   = 'hi-IN';

  // ── Current preference (defaults to English) ───────────────────────────────
  String _preferredLanguage = english;
  String get preferredLanguage => _preferredLanguage;

  /// Human-readable label for the current preference.
  String get preferredLanguageLabel =>
      _preferredLanguage == hindi ? 'Hindi' : 'English';

  /// Whether the user prefers Hindi.
  bool get isHindi => _preferredLanguage == hindi;

  // ── Load from Firestore ────────────────────────────────────────────────────

  /// Loads the language preference for the currently signed-in user.
  /// Falls back to English if not set or if no user is signed in.
  Future<void> loadForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _preferredLanguage = english;
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final lang = doc.data()?['preferredLanguage'] as String?;
      _preferredLanguage = (lang == 'Hindi' || lang == hindi) ? hindi : english;
      debugPrint('LanguagePreferenceService: loaded "$_preferredLanguage"');
    } catch (e) {
      debugPrint('LanguagePreferenceService: load failed – $e');
      _preferredLanguage = english;
    }
  }

  /// Manually set the preference (used when saving during registration).
  void setPreference(String language) {
    _preferredLanguage =
        (language == 'Hindi' || language == hindi) ? hindi : english;
  }
}
