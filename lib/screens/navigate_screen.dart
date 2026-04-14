// lib/screens/navigate_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';
import 'registration.dart';
import 'profile_screen.dart';

class NavigateScreen extends StatefulWidget {
  const NavigateScreen({super.key});
  @override State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {

  final TtsService _tts = TtsService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _tts.speak('Navigation screen. This feature is coming soon. Press volume down to go back.');
  }

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tts.dispose();
    super.dispose();
  }

  @override Future<void> onVolumeUp() async {
    await _tts.speak('Navigation feature coming soon. You can request help from a volunteer.');
  }

  @override Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    await _tts.speak(hi
        ? 'नेविगेशन फीचर जल्द आएगा।'
        : 'Navigation feature coming soon.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Navigate'),
          Text(isMixinListening ? '🎤 Listening…' : 'Vol↑ = info  Vol↓ = home',
              style: const TextStyle(fontSize: 11)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              final user = FirebaseAuth.instance.currentUser;
              Navigator.push(context, MaterialPageRoute(
                  builder: (_) => user == null ? const RegistrationScreen() : const ProfileScreen()));
            },
          ),
        ],
      ),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.navigation, size: 64, color: Colors.indigo),
          const SizedBox(height: 16),
          const Text('Navigate', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Press volume up for navigation help'),
          const SizedBox(height: 8),
          const Text('Feature coming soon…', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          const Text('Press volume down to go back to home', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
    );
  }
}