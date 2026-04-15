import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/tts_service.dart';
import '../services/volume_button_service.dart';
import '../theme/app_theme.dart';
import 'profile_screen.dart';
import 'registration.dart';
import 'video_call_screen.dart';

class TalkWithVoluntaryScreen extends StatefulWidget {
  const TalkWithVoluntaryScreen({super.key});

  @override
  State<TalkWithVoluntaryScreen> createState() =>
      _TalkWithVoluntaryScreenState();
}

class _TalkWithVoluntaryScreenState extends State<TalkWithVoluntaryScreen>
    with WidgetsBindingObserver {
  String? _currentRequestId;
  bool _creatingRequest = false;
  final VolumeButtonService _volumeService = VolumeButtonService();
  final TtsService _ttsService = TtsService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupVolumeListener();
  }

  void _setupVolumeListener() {
    _volumeService.initialize(
      onVolumeUp: () async {
        if (_currentRequestId == null) {
          await _createHelpRequest();
        }
      },
      onVolumeDown: () async {
        if (_currentRequestId != null) {
          await _cancelRequest();
        } else {
          await _ttsService.speak('Going back to home');
          if (mounted) Navigator.pop(context);
        }
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _volumeService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> get _helpRequests =>
      FirebaseFirestore.instance.collection('help_requests');

  // ──────── create a help request in Firestore ───────────
  Future<void> _createHelpRequest() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Must be logged in
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RegistrationScreen()),
      );
      return;
    }

    setState(() => _creatingRequest = true);

    try {
      // Fetch the client's name for the notification
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final clientName = userDoc.data()?['name'] ?? 'A client';

      // Create the help request document.
      // The Cloud Function listens for onCreate on this collection
      // and sends FCM to all volunteers.
      final docRef = await _helpRequests.add({
        'clientId': user.uid,
        'clientName': clientName,
        'status': 'pending', // pending → accepted → ended / cancelled
        'createdAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _currentRequestId = docRef.id;
        _creatingRequest = false;
      });
    } catch (e) {
      setState(() => _creatingRequest = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  // ──────── cancel the pending request ───────────────────
  Future<void> _cancelRequest() async {
    if (_currentRequestId == null) return;
    try {
      await _helpRequests.doc(_currentRequestId).update({
        'status': 'cancelled',
      });
    } catch (_) {}
    setState(() => _currentRequestId = null);
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
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
                    const SizedBox(width: 14),
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFCA6F1E), Color(0xFF935116)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.phone_in_talk_rounded,
                          color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Talk with Volunteer',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          )),
                    ),
                    GestureDetector(
                      onTap: () async {
                        final user = FirebaseAuth.instance.currentUser;
                        if (user == null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const RegistrationScreen()),
                          );
                          return;
                        }
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ProfileScreen()),
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 32),
                      // Icon
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFCA6F1E), Color(0xFF935116)],
                          ),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  const Color(0xFFCA6F1E).withOpacity(0.3),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.phone_in_talk_rounded,
                            size: 48, color: Colors.white),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Talk with a Human Volunteer',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Tap the button below to request live help.\n'
                        'The first available volunteer will connect and see your camera feed.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          color: AppTheme.textSecondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 36),
                      if (_currentRequestId == null)
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.phone, size: 22),
                            label: Text(
                              _creatingRequest
                                  ? 'Requesting help...'
                                  : 'Call a Volunteer',
                              style: GoogleFonts.inter(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed:
                                _creatingRequest ? null : _createHelpRequest,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFCA6F1E),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                    AppTheme.radiusMd),
                              ),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: StreamBuilder<
                              DocumentSnapshot<Map<String, dynamic>>>(
                            stream: _helpRequests
                                .doc(_currentRequestId)
                                .snapshots(),
                            builder: (context, snapshot) {
                              if (!snapshot.hasData) {
                                return const Center(
                                    child: CircularProgressIndicator(
                                        color: AppTheme.accent));
                              }
                              if (!snapshot.data!.exists) {
                                return Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Text('Request ended',
                                        style: GoogleFonts.inter(
                                            color:
                                                AppTheme.textSecondary)),
                                    const SizedBox(height: 12),
                                    ElevatedButton(
                                      onPressed: () => setState(
                                          () => _currentRequestId = null),
                                      child: const Text('Back'),
                                    ),
                                  ],
                                );
                              }

                              final data =
                                  snapshot.data!.data() ?? {};
                              final status =
                                  (data['status'] ?? 'pending')
                                      as String;

                              // ── Navigate to video call when accepted ──
                              if (status == 'accepted') {
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  final requestId =
                                      _currentRequestId;
                                  if (requestId == null ||
                                      !mounted) return;
                                  // Clear so we don't double-navigate
                                  _currentRequestId = null;
                                  Navigator.pushReplacement(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          VideoCallScreen(
                                        role: 'client',
                                        requestId: requestId,
                                      ),
                                    ),
                                  );
                                });
                              }

                              String statusText;
                              if (status == 'pending') {
                                statusText =
                                    'Waiting for a volunteer to accept your request...';
                              } else if (status == 'accepted') {
                                statusText =
                                    'Connecting to volunteer...';
                              } else if (status == 'cancelled') {
                                statusText =
                                    'Request cancelled.';
                              } else {
                                statusText = 'Request ended.';
                              }

                              return Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  const SizedBox(height: 24),
                                  SizedBox(
                                    width: 40,
                                    height: 40,
                                    child:
                                        CircularProgressIndicator(
                                      color: AppTheme.accent,
                                      strokeWidth: 3,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  Text(statusText,
                                      textAlign:
                                          TextAlign.center,
                                      style: GoogleFonts.inter(
                                        color: AppTheme
                                            .textSecondary,
                                        height: 1.4,
                                      )),
                                  const SizedBox(height: 24),
                                  TextButton.icon(
                                    icon: Icon(Icons.cancel,
                                        color: AppTheme.red,
                                        size: 20),
                                    label: Text(
                                      'Cancel request',
                                      style: GoogleFonts.inter(
                                        color: AppTheme.red,
                                        fontWeight:
                                            FontWeight.w600,
                                      ),
                                    ),
                                    onPressed: _cancelRequest,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
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
