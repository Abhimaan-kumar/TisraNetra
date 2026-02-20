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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF03FB5E)),
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
      _MenuOption('Read Anything', Icons.book, Colors.teal, const SimplePage(title: 'Read Anything')),
      _MenuOption('Currency', Icons.attach_money, Colors.deepPurple, const SimplePage(title: 'Currency')),
      _MenuOption('Navigate', Icons.navigation, Colors.indigo, const SimplePage(title: 'Navigate')),
      _MenuOption('Scene Captioning', Icons.camera_alt, Colors.orange, const SimplePage(title: 'Scene Captioning')),
      _MenuOption('Color', Icons.color_lens, Colors.pink, const SimplePage(title: 'Color')),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        title: Text(title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
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
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
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
