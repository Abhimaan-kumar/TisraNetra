import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../services/volume_button_service.dart';
import 'registration.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_screen.dart';

class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen>
    with WidgetsBindingObserver {
  final VolumeButtonService _volumeService = VolumeButtonService();
  final TtsService _ttsService = TtsService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupVolumeListener();
    _ttsService.speak('Emergency screen. Press volume up for emergency help.');
  }

  void _setupVolumeListener() {
    _volumeService.initialize(
      onVolumeUp: () async {
        await _ttsService.speak(
          'Emergency alert sent. A volunteer will contact you shortly.',
        );
        // Here you can add logic to send emergency alert
      },
      onVolumeDown: () async {
        await _ttsService.speak('Going back to home');
        if (mounted) Navigator.pop(context);
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _volumeService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency'),
        backgroundColor: Colors.red,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RegistrationScreen()),
                );
                return;
              }
              // If logged in, open Profile screen
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.emoji_people_rounded, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            const Text(
              'Emergency',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Press volume up to send emergency alert'),
            const SizedBox(height: 24),
            const Text(
              'Press volume down to go back to home',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
