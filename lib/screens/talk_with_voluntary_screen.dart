import 'package:flutter/material.dart';
import 'registration.dart';

class TalkWithVoluntaryScreen extends StatelessWidget {
  const TalkWithVoluntaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talk with Voluntary'),
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
            Icon(Icons.phone_in_talk_rounded, size: 64, color: const Color.fromARGB(255, 142, 73, 37)),
            const SizedBox(height: 16),
            const Text('Talk with Voluntary', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Add your content here'),
          ],
        ),
      ),
    );
  }
}
