// lib/screens/navigate_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';
import '../theme/app_theme.dart';
import 'registration.dart';
import 'profile_screen.dart';

class NavigateScreen extends StatefulWidget {
  const NavigateScreen({super.key});
  @override State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {

  final TtsService _tts = TtsService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _tts.speak('Navigation screen. This feature is coming soon. Press volume down to go back.');
  }

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tts.dispose();
    super.dispose();
  }

  @override Future<void> onVolumeUp() async {
    await _tts.speak('Navigation feature coming soon. You can request help from a volunteer.');
  }

  @override Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    await _tts.speak(hi
        ? 'नेविगेशन फीचर जल्द आएगा।'
        : 'Navigation feature coming soon.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: const Icon(Icons.arrow_back_ios_new,
                            color: AppTheme.textSecondary, size: 18),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Navigate',
                              style: GoogleFonts.inter(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              )),
                          Text(
                            isMixinListening
                                ? '🎤 Listening…'
                                : 'Vol↑ = info  Vol↓ = home',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        final user = FirebaseAuth.instance.currentUser;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => user == null
                                ? const RegistrationScreen()
                                : const ProfileScreen(),
                          ),
                        );
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: const Icon(Icons.person_outline_rounded,
                            color: AppTheme.textSecondary, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
              // Body
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: AppTheme.accent.withOpacity(0.3),
                          ),
                        ),
                        child: const Icon(Icons.navigation_rounded,
                            size: 48, color: AppTheme.accent),
                      ),
                      const SizedBox(height: 24),
                      Text('Navigate',
                          style: GoogleFonts.inter(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          )),
                      const SizedBox(height: 10),
                      Text('Press volume up for navigation help',
                          style: GoogleFonts.inter(
                            color: AppTheme.textSecondary,
                          )),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.orange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppTheme.orange.withOpacity(0.3),
                          ),
                        ),
                        child: Text('Feature coming soon…',
                            style: GoogleFonts.inter(
                              color: AppTheme.orange,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            )),
                      ),
                      const SizedBox(height: 32),
                      Text('Press volume down to go back to home',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppTheme.textSecondary.withOpacity(0.6),
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}