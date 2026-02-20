import 'package:flutter/material.dart';
import 'menu_option.dart';

class MenuCard extends StatelessWidget {
  final MenuOption option;

  const MenuCard({super.key, required this.option});

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
