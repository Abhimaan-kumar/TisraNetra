import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../services/volume_button_service.dart';
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
  Future<void> _requestHelp() async {
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
      appBar: AppBar(
        title: const Text('Talk with Volunteer'),
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
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 24),
            Icon(
              Icons.phone_in_talk_rounded,
              size: 80,
              color: const Color.fromARGB(255, 142, 73, 37),
            ),
            const SizedBox(height: 16),
            const Text(
              'Talk with a Human Volunteer',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap the button below to request live help.\n'
              'The first available volunteer will connect and see your camera feed.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (_currentRequestId == null)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.phone),
                  label: Text(_creatingRequest ? 'Requesting help...' : 'Call a Volunteer'),
                  onPressed: _creatingRequest ? null : _requestHelp,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color.fromARGB(255, 142, 73, 37),
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _helpRequests.doc(_currentRequestId).snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (!snapshot.data!.exists) {
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Request ended'),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: () =>
                                setState(() => _currentRequestId = null),
                            child: const Text('Back'),
                          ),
                        ],
                      );
                    }

                    final data = snapshot.data!.data() ?? {};
                    final status = (data['status'] ?? 'pending') as String;

                    // ── Navigate to video call when accepted ──
                    if (status == 'accepted') {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        final requestId = _currentRequestId;
                        if (requestId == null || !mounted) return;
                        // Clear so we don't double-navigate
                        _currentRequestId = null;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VideoCallScreen(
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
                      statusText = 'Connecting to volunteer...';
                    } else if (status == 'cancelled') {
                      statusText = 'Request cancelled.';
                    } else {
                      statusText = 'Request ended.';
                    }

                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 24),
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(statusText, textAlign: TextAlign.center),
                        const SizedBox(height: 24),
                        TextButton.icon(
                          icon: const Icon(Icons.cancel),
                          label: const Text('Cancel request'),
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
    );
  }
}
