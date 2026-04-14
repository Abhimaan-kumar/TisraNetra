import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import '../widgets/volume_button_mixin.dart';

class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({Key? key}) : super(key: key);

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen>
    with SingleTickerProviderStateMixin, VolumeButtonMixin<EmergencyScreen> {
  final FlutterTts _flutterTts = FlutterTts();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  bool _isProcessing = false;
  String _statusText = 'Press Volume Up & speak a command';

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initTts();
    initVolumeButtonListener();
    _requestPermissions();
  }

  void _initAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.location,
      Permission.phone,
    ].request();
  }

  @override
  Future<void> onVolumeUp() async {
    // Direct button press, default behavior handled by mixin.
  }

  @override
  Future<void> handleFeatureVoiceCommand(String command, String language) async {
    if (command.contains('location') || command.contains('know') || command.contains('tell location')) {
      await _knowYourLocation();
    } else if (command.contains('guardian') ||
        command.contains('call') ||
        command.contains('guard')) {
      await _callGuardian();
    } else {
      setState(() => _statusText = 'Command not recognized: "$command"');
      await _flutterTts.speak('Command not recognized. Please try again.');
    }
  }

  // ─── KNOW YOUR LOCATION ────────────────────────────────────────────────────

  Future<void> _knowYourLocation() async {
    setState(() {
      _isProcessing = true;
      _statusText = 'Fetching your location...';
    });

    await _flutterTts.speak('Fetching your current location. Please wait.');

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await _flutterTts.speak('Location services are disabled. Please enable GPS.');
        setState(() {
          _statusText = 'Location services disabled.';
          _isProcessing = false;
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        await _flutterTts.speak('Location permission denied.');
        setState(() {
          _statusText = 'Location permission denied.';
          _isProcessing = false;
        });
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      String locationMessage = '';
      String addressText = '';
      try {
        final placemarks = await placemarkFromCoordinates(position.latitude, position.longitude);
        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          final addressParts = [
            place.name,
            place.street,
            place.subLocality,
            place.locality,
            place.administrativeArea
          ]..removeWhere((e) => e == null || e.isEmpty);
          
          final uniqueAddressParts = addressParts.toSet().toList();
          addressText = uniqueAddressParts.join(', ');
          
          locationMessage = 'Your current location is: $addressText.';
        } else {
          addressText = 'Lat: ${position.latitude.toStringAsFixed(4)}, Lng: ${position.longitude.toStringAsFixed(4)}';
          locationMessage = 'Your current location is at latitude ${position.latitude.toStringAsFixed(4)}, longitude ${position.longitude.toStringAsFixed(4)}.';
        }
      } catch (e) {
        addressText = 'Lat: ${position.latitude.toStringAsFixed(4)}, Lng: ${position.longitude.toStringAsFixed(4)}';
        locationMessage = 'Your current location is at latitude ${position.latitude.toStringAsFixed(4)}, longitude ${position.longitude.toStringAsFixed(4)}.';
      }

      setState(() {
        _statusText = addressText;
        _isProcessing = false;
      });

      await _flutterTts.speak(locationMessage);
    } catch (e) {
      setState(() {
        _statusText = 'Could not get location.';
        _isProcessing = false;
      });
      await _flutterTts.speak('Unable to get your location. Please try again.');
    }
  }

  // ─── CALL GUARDIAN ─────────────────────────────────────────────────────────

  Future<void> _callGuardian() async {
    setState(() {
      _isProcessing = true;
      _statusText = 'Fetching guardian number...';
    });

    await _flutterTts.speak('Calling your guardian. Please wait.');

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        await _flutterTts.speak('User not logged in. Cannot fetch guardian number.');
        setState(() {
          _statusText = 'User not logged in.';
          _isProcessing = false;
        });
        return;
      }

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      if (!doc.exists || doc.data() == null) {
        await _flutterTts.speak('User data not found in database.');
        setState(() {
          _statusText = 'User data not found.';
          _isProcessing = false;
        });
        return;
      }

      final phone = doc.data()!['emergencyPhone'] as String?;

      if (phone == null || phone.isEmpty) {
        await _flutterTts.speak('No emergency phone number saved.');
        setState(() {
          _statusText = 'No emergency number saved.';
          _isProcessing = false;
        });
        return;
      }

      await _flutterTts.speak('Calling $phone now.');
      
      bool? res = await FlutterPhoneDirectCaller.callNumber(phone);
      
      if (res == true) {
        setState(() {
          _statusText = 'Calling: $phone';
          _isProcessing = false;
        });
      } else {
        await _flutterTts.speak('Unable to make a call on this device.');
        setState(() {
          _statusText = 'Cannot make call.';
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        _statusText = 'Error fetching guardian number.';
        _isProcessing = false;
      });
      await _flutterTts.speak('An error occurred. Please try again.');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  // ─── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_ios_new,
                  color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'EMERGENCY',
                style: TextStyle(
                  color: Color(0xFFFF3B3B),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
              Text(
                'Tap or use voice command',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const Spacer(),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isMixinListening
                  ? const Color(0xFFFF3B3B).withOpacity(0.2)
                  : Colors.white10,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isMixinListening
                    ? const Color(0xFFFF3B3B)
                    : Colors.transparent,
                width: 1.2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isMixinListening ? Icons.mic : Icons.mic_none,
                  color: isMixinListening
                      ? const Color(0xFFFF3B3B)
                      : Colors.white54,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  isMixinListening ? 'Listening' : 'Vol↑',
                  style: TextStyle(
                    color: isMixinListening
                        ? const Color(0xFFFF3B3B)
                        : Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Pulse SOS indicator
          ScaleTransition(
            scale: _pulseAnimation,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF3B3B).withOpacity(0.12),
                border: Border.all(
                    color: const Color(0xFFFF3B3B).withOpacity(0.5), width: 2),
              ),
              child: Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFFF3B3B),
                  ),
                  child: const Center(
                    child: Text(
                      'SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 48),

          // Know Your Location Button
          _EmergencyButton(
            icon: Icons.location_on_rounded,
            label: 'Know Your Location',
            subtitle: 'Announces your GPS coordinates aloud',
            color: const Color(0xFF00C2FF),
            onTap: _isProcessing ? null : _knowYourLocation,
          ),
          const SizedBox(height: 20),

          // Call Guardian Button
          _EmergencyButton(
            icon: Icons.phone_in_talk_rounded,
            label: 'Call Your Guardian',
            subtitle: 'Calls saved emergency contact',
            color: const Color(0xFF00E676),
            onTap: _isProcessing ? null : _callGuardian,
          ),
          const SizedBox(height: 32),

          // Voice command hint
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    color: Colors.white38, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Press Volume Up button and say\n"Know your location"  or  "Call your guardian"',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (_isProcessing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                color: Color(0xFFFF3B3B),
                strokeWidth: 2,
              ),
            )
          else
            const Icon(Icons.info_outline,
                color: Colors.white38, size: 15),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusText,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── REUSABLE BUTTON WIDGET ────────────────────────────────────────────────

class _EmergencyButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _EmergencyButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  @override
  State<_EmergencyButton> createState() => _EmergencyButtonState();
}

class _EmergencyButtonState extends State<_EmergencyButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          opacity: widget.onTap == null ? 0.5 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
              color: widget.color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: widget.color.withOpacity(0.35),
                width: 1.4,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: widget.color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(widget.icon, color: widget.color, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: widget.color.withOpacity(0.6),
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}