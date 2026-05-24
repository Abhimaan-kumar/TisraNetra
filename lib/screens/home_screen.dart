// lib/screens/home_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/volume_button_service.dart';
import '../services/tts_service.dart';
import '../services/fcm_service.dart';
import '../theme/app_theme.dart';
import 'profile_screen.dart';
import '../widgets/menu_option.dart';
import '../widgets/menu_card.dart';
import 'read_anything_screen.dart';
import 'currency_screen.dart';
import 'navigate_screen.dart';
import 'object_recognition_screen.dart';
import 'scene_captioning_screen.dart';
import 'person_identification_screen.dart';
import 'color_screen.dart';
import 'talk_with_voluntary_screen.dart';
import 'ai_buddy_screen.dart';
import 'emergency_screen.dart';
import 'registration.dart';

// ─── Command → screen mapping (English + Hindi intents) ──────────────────────
final Map<String, (String label, Widget Function() builder)> _cmdMap = {
  // Read Anything
  'read': ('Read Anything', () => const ReadAnythingScreen()),
  'padho': ('Read Anything', () => const ReadAnythingScreen()),
  'padhna': ('Read Anything', () => const ReadAnythingScreen()),
  'text': ('Read Anything', () => const ReadAnythingScreen()),
  'likha': ('Read Anything', () => const ReadAnythingScreen()),
  'kya likha': ('Read Anything', () => const ReadAnythingScreen()),

  // Currency
  'currency': ('Currency', () => const CurrencyScreen()),
  'rupee': ('Currency', () => const CurrencyScreen()),
  'paisa': ('Currency', () => const CurrencyScreen()),
  'note': ('Currency', () => const CurrencyScreen()),
  'money': ('Currency', () => const CurrencyScreen()),
  'paise': ('Currency', () => const CurrencyScreen()),
  'rupeyya': ('Currency', () => const CurrencyScreen()),

  // Navigate
  'navigate': ('Navigate', () => const NavigateScreen()),
  'navigation': ('Navigate', () => const NavigateScreen()),
  'direction': ('Navigate', () => const NavigateScreen()),
  'rasta': ('Navigate', () => const NavigateScreen()),
  'raasta': ('Navigate', () => const NavigateScreen()),
  'jana hai': ('Navigate', () => const NavigateScreen()),

  // Object Recognition
  'object': ('Object Recognition', () => const ObjectRecognitionScreen()),
  'recognize': ('Object Recognition', () => const ObjectRecognitionScreen()),
  'objects': ('Object Recognition', () => const ObjectRecognitionScreen()),
  'cheez': ('Object Recognition', () => const ObjectRecognitionScreen()),
  'kya hai': ('Object Recognition', () => const ObjectRecognitionScreen()),

  // Scene Captioning
  'scene': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'caption': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'describe': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'description': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'samne': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'kya ho rha hai': ('Scene Captioning', () => const SceneCaptioningScreen()),

  // Person Identification
  'person': ('Person Identification', () => const PersonIdentificationScreen()),
  'identify': (
    'Person Identification',
    () => const PersonIdentificationScreen(),
  ),
  'face': ('Person Identification', () => const PersonIdentificationScreen()),
  'kaun': ('Person Identification', () => const PersonIdentificationScreen()),
  'kon hai': (
    'Person Identification',
    () => const PersonIdentificationScreen(),
  ),
  'pehchano': (
    'Person Identification',
    () => const PersonIdentificationScreen(),
  ),
  'aadmi kaun hai': (
    'Person Identification',
    () => const PersonIdentificationScreen(),
  ),
  'aurat kaun hai': (
    'Person Identification',
    () => const PersonIdentificationScreen(),
  ),

  // Color
  'color': ('Color', () => const ColorScreen()),
  'colour': ('Color', () => const ColorScreen()),
  'rang': ('Color', () => const ColorScreen()),
  'kaunsa rang': ('Color', () => const ColorScreen()),

  // Talk with Voluntary
  'talk': ('Talk with Volunteer', () => const TalkWithVoluntaryScreen()),
  'voluntary': ('Talk with Volunteer', () => const TalkWithVoluntaryScreen()),
  'volunteer': ('Talk with Volunteer', () => const TalkWithVoluntaryScreen()),
  'madad': ('Talk with Volunteer', () => const TalkWithVoluntaryScreen()),
  'sahayata': ('Talk with Volunteer', () => const TalkWithVoluntaryScreen()),

  // AI Buddy
  'buddy': ('AI Buddy', () => const AIBuddyScreen()),
  'chat': ('AI Buddy', () => const AIBuddyScreen()),
  'baat': ('AI Buddy', () => const AIBuddyScreen()),
  'timepass': ('AI Buddy', () => const AIBuddyScreen()),

  // Emergency
  'emergency': ('Emergency', () => const EmergencyScreen()),
  'bachao': ('Emergency', () => const EmergencyScreen()),
  'call': ('Emergency', () => const EmergencyScreen()),
};

// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.title});
  final String title;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final VolumeButtonService _volService = VolumeButtonService();
  final TtsService _tts = TtsService();
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _sttReady = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _initStt();
    _setupVolume();
    _welcome();

    // Check for any pending notification from cold-start
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FcmService().checkPendingNotification();
    });
  }

  // ── Init ─────────────────────────────────────────────────────────────────────

  Future<void> _initStt() async {
    _sttReady = await _speech.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) {
          setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
  }

  void _setupVolume() {
    _volService.initialize(
      onVolumeUp: _onVolumeUp,
      onVolumeDown: () async {
        await _tts.speakLocalized(
          'You are already on the home screen.',
          'आप पहले से होम स्क्रीन पर हैं।',
        );
      },
    );
  }

  Future<void> _welcome() async {
    await Future.delayed(const Duration(milliseconds: 800));
    await _tts.speakLocalized(
      'Welcome to Tisra Netra. Press volume up and say a feature name to open it.',
      'तीसरा नेत्र में आपका स्वागत है। वॉल्यूम बढ़ा कर आदेश दीजिये।',
    );
  }

  // ── Volume up ─────────────────────────────────────────────────────────────────

  Future<void> _onVolumeUp() async {
    if (_listening) {
      // Second press cancels listening
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_sttReady) {
      await _tts.speakLocalized(
        'Microphone not available.',
        'माइक्रोफोन उपलब्ध नहीं है।',
      );
      return;
    }

    await _tts.stop();
    if (mounted) setState(() => _listening = true);
    await _tts.speakLocalized('Listening…', 'सुन रहा हूँ…');

    await _speech.listen(
      onResult: (result) async {
        if (!mounted) return;
        final words = result.recognizedWords.toLowerCase().trim();
        if (result.finalResult) {
          setState(() => _listening = false);
          if (words.isEmpty) {
            await _tts.speakLocalized(
              'I did not hear anything. Press volume up again.',
              'मुझे कुछ सुनाई नहीं दिया। वॉल्यूम अप फिर से दबाएं।',
            );
          } else {
            await _handleCommand(words);
          }
        }
      },
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      listenOptions: stt.SpeechListenOptions(
        partialResults: false,
        cancelOnError: true,
        listenMode: stt.ListenMode.confirmation,
      ),
    );
  }

  // ── Command dispatch ──────────────────────────────────────────────────────────

  Future<void> _handleCommand(String words) async {
    final spokenHindi = RegExp(r'[\u0900-\u097F]').hasMatch(words);
    final prefersHindi = _tts.isHindi;

    String? matchedKey;
    for (final key in _cmdMap.keys) {
      if (words.contains(key)) {
        matchedKey = key;
        break;
      }
    }

    if (matchedKey == null) {
      if (spokenHindi || prefersHindi) {
        await _tts.speak(
          'माफ कीजिए, मुझे समझ नहीं आया। '
          'वॉल्यूम अप दबाकर फिर से बोलें।',
        );
      } else {
        await _tts.speak(
          'Sorry, I did not understand. '
          'Press volume up again and say a feature name.',
        );
      }
      return;
    }

    final (label, builder) = _cmdMap[matchedKey]!;

    if (spokenHindi || prefersHindi) {
      await _tts.speak('$label खोल रहे हैं।');
    } else {
      await _tts.speak('Opening $label.');
    }

    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => builder()));

    if (mounted) {
      await _tts.speakLocalized(
        'Back to home. Press volume up to open a feature.',
        'होम पर वापस। वॉल्यूम अप दबाएं कोई फीचर खोलने के लिए।',
      );
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _volService.dispose();
    _speech.cancel();
    _tts.stop();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final options = [
      MenuOption(
        'Read Anything',
        Icons.book,
        const Color(0xFF03998A),
        (_) => const ReadAnythingScreen(),
      ),
      MenuOption(
        'Currency',
        Icons.attach_money,
        Colors.deepPurple,
        (_) => const CurrencyScreen(),
      ),
      MenuOption(
        'Navigate',
        Icons.navigation,
        Colors.indigo,
        (_) => const NavigateScreen(),
      ),
      MenuOption(
        'Object Recognition',
        Icons.search,
        Colors.green,
        (_) => const ObjectRecognitionScreen(),
      ),
      MenuOption(
        'Scene Captioning',
        Icons.camera_alt,
        const Color(0xFF018E55),
        (_) => const SceneCaptioningScreen(),
      ),
      MenuOption(
        'Person Identification',
        Icons.tag_faces_outlined,
        const Color(0xFFCFB067),
        (_) => const PersonIdentificationScreen(),
      ),
      MenuOption(
        'Color',
        Icons.color_lens,
        const Color(0xFF1E79E9),
        (_) => const ColorScreen(),
      ),
      MenuOption(
        'Talk with Volunteer',
        Icons.phone_in_talk_rounded,
        const Color(0xFF8E4925),
        (_) => const TalkWithVoluntaryScreen(),
      ),
      MenuOption(
        'AI Buddy',
        Icons.chat_outlined,
        const Color(0xFF69761E),
        (_) => const AIBuddyScreen(),
      ),
      MenuOption(
        'Emergency',
        Icons.emoji_people_rounded,
        Colors.red,
        (_) => const EmergencyScreen(),
      ),
    ];

    return Scaffold(
      backgroundColor: AppTheme.splashbg,
      body: SafeArea(
          child: Column(
            children: [
              // ── Premium Header ─────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Row(
                  children: [
                    // Logo
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: AppTheme.glowShadow(
                          AppTheme.accent,
                          blur: 12,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset(
                          'images/logo.png',
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            decoration: BoxDecoration(
                              gradient: AppTheme.accentGradient,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.visibility,
                                color: Colors.white, size: 24),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Tisra Netra',
                            style: GoogleFonts.inter(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Colors.black87,
                              letterSpacing: -0.5,
                            ),
                          ),
                          Text(
                            'Welcome${widget.title}',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: Colors.black54,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Profile button
                    GestureDetector(
                      onTap: () async {
                        final user = FirebaseAuth.instance.currentUser;
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => user == null
                                ? const RegistrationScreen()
                                : const ProfileScreen(),
                          ),
                        );
                        await _tts.speakLocalized(
                          'Back to home. Press volume up to open a feature.',
                          'होम पर वापस। वॉल्यूम अप दबाएं कोई फीचर खोलने के लिए।',
                        );
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.grey.shade300,
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.person_outline_rounded,
                            color: Colors.black87, size: 24),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Listening indicator ─────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Container(
                  key: ValueKey(_listening),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _listening
                        ? AppTheme.accent.withOpacity(0.12)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    border: Border.all(
                      color: _listening
                          ? AppTheme.accent.withOpacity(0.4)
                          : Colors.grey.shade300,
                    ),
                    boxShadow: [
                      if (!_listening)
                        BoxShadow(
                          color: Colors.black.withOpacity(0.03),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _listening ? Icons.mic : Icons.volume_up_rounded,
                        size: 16,
                        color: _listening
                            ? AppTheme.accent
                            : Colors.black54,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _listening
                            ? '🎤 Listening… say a feature name'
                            : 'Press Volume Up to open a feature',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: _listening
                              ? AppTheme.accent
                              : Colors.black87,
                          fontWeight:
                              _listening ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Menu Grid ─────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.05,
                    children: List.generate(
                      options.length,
                      (i) => MenuCard(option: options[i], index: i),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    
  }
}
