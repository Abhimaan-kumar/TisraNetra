import 'package:flutter/material.dart';
import 'registration.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_screen.dart';

class PersonIdentificationScreen extends StatelessWidget {
  const PersonIdentificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Person Identification'),
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
            Icon(Icons.tag_faces_outlined, size: 64, color: const Color.fromARGB(255, 207, 176, 103)),
            const SizedBox(height: 16),
            const Text('Person Identification', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Add your content here'),
          ],
        ),
      ),
    );
  }
}
