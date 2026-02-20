import 'package:flutter/material.dart';

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
    final List<_MenuOption> options = [
      _MenuOption('Read Anything', Icons.book, const Color.fromARGB(255, 3, 153, 138), const SimplePage(title: 'Read Anything')),
      _MenuOption('Currency', Icons.attach_money, Colors.deepPurple, const SimplePage(title: 'Currency')),
      _MenuOption('Navigate', Icons.navigation, Colors.indigo, const SimplePage(title: 'Navigate')),
      _MenuOption('Object Recognition', Icons.search, Colors.green, const SimplePage(title: 'Object Recognition')),
      _MenuOption('Scene Captioning', Icons.camera_alt, const Color.fromARGB(255, 1, 142, 85), const SimplePage(title: 'Scene Captioning')),
      _MenuOption('Person Identification', Icons.tag_faces_outlined, const Color.fromARGB(255, 207, 176, 103), const SimplePage(title: 'Person Identification')),
      _MenuOption('Color', Icons.color_lens, const Color.fromARGB(255, 30, 121, 233), const SimplePage(title: 'Color')),
      _MenuOption('Talk with Voluntary', Icons.phone_in_talk_rounded, const Color.fromARGB(255, 142, 73, 37), const SimplePage(title: 'Talk with Voluntary')),
      _MenuOption('Time pass with AI buddy', Icons.chat_outlined, const Color.fromARGB(255, 105, 118, 30), const SimplePage(title: 'Time pass with AI buddy')),
      _MenuOption('Emergency', Icons.emoji_people_rounded, const Color.fromARGB(255, 255, 0, 0), const SimplePage(title: 'Emergency'))
      
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(30.0),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 20,
          mainAxisSpacing: 20,
          children: options.map((opt) => _MenuCard(option: opt)).toList(),
        ),
      ),
    );
  }
}

class _MenuOption {
  final String title;
  final IconData icon;
  final Color color;
  final Widget page;

  _MenuOption(this.title, this.icon, this.color, this.page);
}

class _MenuCard extends StatelessWidget {
  final _MenuOption option;

  const _MenuCard({required this.option});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: option.color,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => option.page));
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(option.icon, size: 48, color: Colors.white),
              const SizedBox(height: 12),
              Text(
                option.title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SimplePage extends StatelessWidget {
  final String title;

  const SimplePage({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
    );
  }
}
