// lib/screens/home_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/volume_button_service.dart';
import '../services/tts_service.dart';
import 'profile_screen.dart';
import 'volunteer.dart';
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
  'read'         : ('Read Anything',          () => const ReadAnythingScreen()),
  'padho'        : ('Read Anything',          () => const ReadAnythingScreen()),
  'padhna'       : ('Read Anything',          () => const ReadAnythingScreen()),
  'text'         : ('Read Anything',          () => const ReadAnythingScreen()),
  'likha'        : ('Read Anything',          () => const ReadAnythingScreen()),
  'kya likha'    : ('Read Anything',          () => const ReadAnythingScreen()),

  // Currency
  'currency'     : ('Currency',               () => const CurrencyScreen()),
  'rupee'        : ('Currency',               () => const CurrencyScreen()),
  'paisa'        : ('Currency',               () => const CurrencyScreen()),
  'note'         : ('Currency',               () => const CurrencyScreen()),
  'money'        : ('Currency',               () => const CurrencyScreen()),
  'paise'        : ('Currency',               () => const CurrencyScreen()),

  // Navigate
  'navigate'     : ('Navigate',               () => const NavigateScreen()),
  'navigation'   : ('Navigate',               () => const NavigateScreen()),
  'direction'    : ('Navigate',               () => const NavigateScreen()),
  'rasta'        : ('Navigate',               () => const NavigateScreen()),
  'raasta'       : ('Navigate',               () => const NavigateScreen()),

  // Object Recognition
  'object'       : ('Object Recognition',     () => const ObjectRecognitionScreen()),
  'recognize'    : ('Object Recognition',     () => const ObjectRecognitionScreen()),
  'objects'      : ('Object Recognition',     () => const ObjectRecognitionScreen()),
  'cheez'        : ('Object Recognition',     () => const ObjectRecognitionScreen()),
  'kya hai'      : ('Object Recognition',     () => const ObjectRecognitionScreen()),

  // Scene Captioning
  'scene'        : ('Scene Captioning',       () => const SceneCaptioningScreen()),
  'caption'      : ('Scene Captioning',       () => const SceneCaptioningScreen()),
  'describe'     : ('Scene Captioning',       () => const SceneCaptioningScreen()),
  'description'  : ('Scene Captioning',       () => const SceneCaptioningScreen()),
  'batao'        : ('Scene Captioning',       () => const SceneCaptioningScreen()),
  'samne'        : ('Scene Captioning',       () => const SceneCaptioningScreen()),

  // Person Identification
  'person'       : ('Person Identification',  () => const PersonIdentificationScreen()),
  'identify'     : ('Person Identification',  () => const PersonIdentificationScreen()),
  'face'         : ('Person Identification',  () => const PersonIdentificationScreen()),
  'kaun'         : ('Person Identification',  () => const PersonIdentificationScreen()),
  'kon hai'      : ('Person Identification',  () => const PersonIdentificationScreen()),
  'pehchano'     : ('Person Identification',  () => const PersonIdentificationScreen()),
  'aadmi kaun hai': ('Person Identification',  () => const PersonIdentificationScreen()),
  'aurat kaun hai': ('Person Identification',  () => const PersonIdentificationScreen()),
  // Color
  'color'        : ('Color',                  () => const ColorScreen()),
  'colour'       : ('Color',                  () => const ColorScreen()),
  'rang'         : ('Color',                  () => const ColorScreen()),
  'kaunsa rang'  : ('Color',                  () => const ColorScreen()),

  // Talk with Voluntary
  'talk'         : ('Talk with Volunteer',    () => const TalkWithVoluntaryScreen()),
  'voluntary'    : ('Talk with Volunteer',    () => const TalkWithVoluntaryScreen()),
  'volunteer'    : ('Talk with Volunteer',    () => const TalkWithVoluntaryScreen()),
  'help'         : ('Talk with Volunteer',    () => const TalkWithVoluntaryScreen()),
  'madad'        : ('Talk with Volunteer',    () => const TalkWithVoluntaryScreen()),
  'sahayata'     : ('Talk with Volunteer',    () => const TalkWithVoluntaryScreen()),

  // AI Buddy
  'ai'           : ('AI Buddy',               () => const AIBuddyScreen()),
  'buddy'        : ('AI Buddy',               () => const AIBuddyScreen()),
  'chat'         : ('AI Buddy',               () => const AIBuddyScreen()),
  'baat'         : ('AI Buddy',               () => const AIBuddyScreen()),
  'timepass'     : ('AI Buddy',               () => const AIBuddyScreen()),

  // Emergency
  'emergency'    : ('Emergency',              () => const EmergencyScreen()),
  'bachao'       : ('Emergency',              () => const EmergencyScreen()),
  'help me'      : ('Emergency',              () => const EmergencyScreen()),
};

// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.title});
  final String title;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final VolumeButtonService _volService  = VolumeButtonService();
  final TtsService          _tts         = TtsService();
  final stt.SpeechToText    _speech      = stt.SpeechToText();

  bool _sttReady    = false;
  bool _listening   = false;

  @override
  void initState() {
    super.initState();
    _initStt();
    _setupVolume();
    _welcome();
    _redirectIfVolunteer();
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
        await _tts.speak('You are already on the home screen.');
      },
    );
  }

  Future<void> _welcome() async {
    await Future.delayed(const Duration(milliseconds: 800));
    await _tts.speak(
      'Welcome to LifeLens. Press volume up and say a feature name to open it.',
    );
  }

  Future<void> _redirectIfVolunteer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(user.uid).get();
      if ((doc.data()?['userType'] as String? ?? '').toLowerCase() ==
          'volunteer') {
        if (mounted) {
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => const VolunteerScreen()));
        }
      }
    } catch (_) {}
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
      await _tts.speak('Microphone not available.');
      return;
    }

    await _tts.stop();
    if (mounted) setState(() => _listening = true);
    await _tts.speak('Listening…');

    await _speech.listen(
      onResult: (result) async {
        if (!mounted) return;
        final words = result.recognizedWords.toLowerCase().trim();
        if (result.finalResult) {
          setState(() => _listening = false);
          if (words.isEmpty) {
            await _tts.speak(
                'I did not hear anything. Press volume up again.');
          } else {
            await _handleCommand(words);
          }
        }
      },
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      partialResults: false,
      cancelOnError: true,
      listenMode: stt.ListenMode.confirmation,
    );
  }

  // ── Command dispatch ──────────────────────────────────────────────────────────

  Future<void> _handleCommand(String words) async {
    final isHindi = RegExp(r'[\u0900-\u097F]').hasMatch(words);

    String? matchedKey;
    for (final key in _cmdMap.keys) {
      if (words.contains(key)) { matchedKey = key; break; }
    }

    if (matchedKey == null) {
      if (isHindi) {
        await _tts.speak(
            'माफ कीजिए, मुझे समझ नहीं आया। '
            'वॉल्यूम अप दबाकर फिर से बोलें।');
      } else {
        await _tts.speak(
            'Sorry, I did not understand. '
            'Press volume up again and say a feature name.');
      }
      return;
    }

    final (label, builder) = _cmdMap[matchedKey]!;

    if (isHindi) {
      await _tts.speak('$label खोल रहे हैं।');
    } else {
      await _tts.speak('Opening $label.');
    }

    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => builder()));

    if (mounted) {
      if (isHindi) {
        await _tts.speak(
            'होम पर वापस। वॉल्यूम अप दबाएं कोई फीचर खोलने के लिए।');
      } else {
        await _tts.speak(
            'Back to home. Press volume up to open a feature.');
      }
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _volService.dispose();
    _speech.cancel();
    _tts.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final options = [
      MenuOption('Read Anything',         Icons.book,                  const Color(0xFF03998A), const ReadAnythingScreen()),
      MenuOption('Currency',              Icons.attach_money,           Colors.deepPurple,        const CurrencyScreen()),
      MenuOption('Navigate',              Icons.navigation,             Colors.indigo,            const NavigateScreen()),
      MenuOption('Object Recognition',    Icons.search,                 Colors.green,             const ObjectRecognitionScreen()),
      MenuOption('Scene Captioning',      Icons.camera_alt,             const Color(0xFF018E55),  const SceneCaptioningScreen()),
      MenuOption('Person Identification', Icons.tag_faces_outlined,     const Color(0xFFCFB067),  const PersonIdentificationScreen()),
      MenuOption('Color',                 Icons.color_lens,             const Color(0xFF1E79E9),  const ColorScreen()),
      MenuOption('Talk with Volunteer',   Icons.phone_in_talk_rounded,  const Color(0xFF8E4925),  const TalkWithVoluntaryScreen()),
      MenuOption('AI Buddy',              Icons.chat_outlined,          const Color(0xFF69761E),  const AIBuddyScreen()),
      MenuOption('Emergency',             Icons.emoji_people_rounded,   Colors.red,               const EmergencyScreen()),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('images/logo.png', width: 80, height: 80,
              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          const SizedBox(width: 8),
          Text('Life Lens', style: Theme.of(context).textTheme.headlineSmall),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => user == null
                      ? const RegistrationScreen()
                      : const ProfileScreen(),
                ),
              );
              await _tts.speak(
                  'Back to home. Press volume up to open a feature.');
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(children: [
          Text('Welcome ${widget.title}'),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _listening
                  ? '🎤 Listening… say a feature name'
                  : 'Press Volume Up to open a feature',
              key: ValueKey(_listening),
              style: TextStyle(
                fontSize: 15,
                color: _listening ? Colors.deepPurple : Colors.black87,
                fontWeight: _listening ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 20,
              mainAxisSpacing: 20,
              children: options.map((o) => MenuCard(option: o)).toList(),
            ),
          ),
        ]),
      ),
    );
  }
}