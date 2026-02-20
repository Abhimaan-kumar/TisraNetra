import 'package:flutter/material.dart';
import 'screens/read_anything_screen.dart';
import 'screens/currency_screen.dart';
import 'screens/navigate_screen.dart';
import 'screens/object_recognition_screen.dart';
import 'screens/scene_captioning_screen.dart';
import 'screens/person_identification_screen.dart';
import 'screens/color_screen.dart';
import 'screens/talk_with_voluntary_screen.dart';
import 'screens/ai_buddy_screen.dart';
import 'screens/emergency_screen.dart';
import 'widgets/menu_option.dart';
import 'widgets/menu_card.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Life Lens',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(255, 3, 251, 40)),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Life Lens'),
    );
  }
}

class MyHomePage extends StatelessWidget {
  const MyHomePage({super.key, required this.title});

  final String title;



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
        title: Text(title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(30.0),
        child: Column(
          children: [
            const Text(
              'Welcome User!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
