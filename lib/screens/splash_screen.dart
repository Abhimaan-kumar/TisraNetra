import 'dart:async';

import 'package:flutter/material.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    // Continuous zoom: scale from 1.0 -> 1.6 repeatedly
    _scaleAnim = Tween<double>(begin: 0, end: 1.6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    // Keep constant opacity during zoom (optional: can be removed)
    _fadeAnim = AlwaysStoppedAnimation<double>(1.0);

    // Repeat without reversing to create a continuous zoom effect
    _controller.repeat();

    Timer(const Duration(seconds: 3), _goToHome);
  }

  void _goToHome() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const HomeScreen(title: 'Life Lens'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: _fadeAnim,
              child: ScaleTransition(
                scale: _scaleAnim,
                child: Image.asset(
                  'images/logo.png',
                  width: 250,
                  height: 250,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.image_not_supported, size: 96, color: Colors.grey),
                        SizedBox(height: 8),
                        Text('Logo not found', style: TextStyle(color: Colors.grey)),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
