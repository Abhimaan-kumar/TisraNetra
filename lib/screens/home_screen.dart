import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
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

// Command mapping for screens
final Map<String, (String label, Widget Function() builder)> commandScreenMap = {
  'read': ('Read Anything', () => const ReadAnythingScreen()),
  'currency': ('Currency', () => const CurrencyScreen()),
  'navigate': ('Navigate', () => const NavigateScreen()),
  'object': ('Object Recognition', () => const ObjectRecognitionScreen()),
  'scene': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'caption': ('Scene Captioning', () => const SceneCaptioningScreen()),
  'person': ('Person Identification', () => const PersonIdentificationScreen()),
  'identify': ('Person Identification', () => const PersonIdentificationScreen()),
  'color': ('Color', () => const ColorScreen()),
  'talk': ('Talk with Voluntary', () => const TalkWithVoluntaryScreen()),
  'voluntary': ('Talk with Voluntary', () => const TalkWithVoluntaryScreen()),
  'ai': ('AI Buddy', () => const AIBuddyScreen()),
  'buddy': ('AI Buddy', () => const AIBuddyScreen()),
  'emergency': ('Emergency', () => const EmergencyScreen()),
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.title});

  final String title;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  String _lastWords = '';
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _setupVolumeButtonListener();
    _welcome();
  }

  void _setupVolumeButtonListener() {
    // Listen to hardware buttons using method channel
    const platform = MethodChannel('com.lifelens.app/volumebutton');
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onVolumeUp') {
        _speak('Listening...');
        _startListeningFor5Seconds();
      } else if (call.method == 'onVolumeDown') {
        _stopListening();
        _speak('Listening stopped.');
      }
    });
  }

  void _handleRawKey(RawKeyEvent event) {
    // Fallback for web/desktop
    if (event is RawKeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
        _speak('Listening...');
        _startListeningFor5Seconds();
      } else if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
        _stopListening();
        _speak('Listening stopped.');
      }
    }
  }

  Future<void> _welcome() async {
    await _speak('Welcome to LifeLens. Press volume up to give a command.');
  }

  void _startListeningFor5Seconds() async {
    try {
      bool available = await _speech.initialize(
        onStatus: (val) {},
        onError: (val) {
          debugPrint('STT Error: $val');
        },
      );
      if (available) {
        setState(() => _listening = true);
        _speech.listen(onResult: (val) {
          if (val.finalResult) {
            setState(() {
              _lastWords = val.recognizedWords;
            });
          }
        });

        // Stop listening after 5 seconds
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _listening) {
            _stopListening();
            _handleCommand(_lastWords.toLowerCase());
          }
        });
      }
    } catch (e) {
      debugPrint('Speech Recognition Error: $e');
      await _speak('Error accessing microphone. Please check permissions.');
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _listening = false);
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.setSpeechRate(1.0);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS Error: $e');
    }
  }

  void _handleCommand(String command) async {
    // Find matching command
    String? matchedKey;
    for (final key in commandScreenMap.keys) {
      if (command.contains(key)) {
        matchedKey = key;
        break;
      }
    }

    if (matchedKey != null) {
      final (label, builder) = commandScreenMap[matchedKey]!;
      await _speak('Opening $label');
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => builder()),
        ).then((_) => _speak('Back to home. Press volume up to give a command.'));
      }
    } else {
      await _speak('Sorry, I did not catch that. Press volume up again to give a command.');
    }
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<MenuOption> options = [
      MenuOption('Read Anything', Icons.book, const Color.fromARGB(255, 3, 153, 138), const ReadAnythingScreen()),
      MenuOption('Currency', Icons.attach_money, Colors.deepPurple, const CurrencyScreen()),
      MenuOption('Navigate', Icons.navigation, Colors.indigo, const NavigateScreen()),
      MenuOption('Object Recognition', Icons.search, Colors.green, const ObjectRecognitionScreen()),
      MenuOption('Scene Captioning', Icons.camera_alt, const Color.fromARGB(255, 1, 142, 85), const SceneCaptioningScreen()),
      MenuOption('Person Identification', Icons.tag_faces_outlined, const Color.fromARGB(255, 207, 176, 103), const PersonIdentificationScreen()),
      MenuOption('Color', Icons.color_lens, const Color.fromARGB(255, 30, 121, 233), const ColorScreen()),
      MenuOption('Talk with Voluntary', Icons.phone_in_talk_rounded, const Color.fromARGB(255, 142, 73, 37), const TalkWithVoluntaryScreen()),
      MenuOption('Time pass with AI buddy', Icons.chat_outlined, const Color.fromARGB(255, 105, 118, 30), const AIBuddyScreen()),
      MenuOption('Emergency', Icons.emoji_people_rounded, const Color.fromARGB(255, 255, 0, 0), const EmergencyScreen())
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'images/logo.png',
              width: 80,
              height: 80,
              errorBuilder: (ctx, obj, stack) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            Text(widget.title),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RegistrationScreen()),
              ).then((_) => _speak('Back to home. Press volume up to give a command.'));
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(30.0),
        child: Column(
          children: [
            const Text(
              'Welcome User!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _listening ? 'Listening...' : 'Press Volume Up to start',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 20,
                mainAxisSpacing: 20,
                children: options.map((opt) => MenuCard(option: opt)).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
