import 'package:flutter/material.dart';
import 'registration.dart';

class SceneCaptioningScreen extends StatelessWidget {
  const SceneCaptioningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scene Captioning'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RegistrationScreen()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt, size: 64, color: const Color.fromARGB(255, 1, 142, 85)),
            const SizedBox(height: 16),
            const Text('Scene Captioning', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Add your content here'),
          ],
        ),
      ),
    );
  }
}
