import 'package:flutter/material.dart';

class PersonIdentificationScreen extends StatelessWidget {
  const PersonIdentificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Person Identification')),
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
