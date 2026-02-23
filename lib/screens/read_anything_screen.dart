import 'package:flutter/material.dart';
import 'registration.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_screen.dart';

class ReadAnythingScreen extends StatelessWidget {
  const ReadAnythingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Read Anything'),
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
            Icon(Icons.book, size: 64, color: Colors.teal),
            const SizedBox(height: 16),
            const Text('Read Anything', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Add your content here'),
          ],
        ),
      ),
    );
  }
}
