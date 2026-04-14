import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tts_service.dart';
import '../services/volume_button_service.dart';
import 'profile_screen.dart';
import 'registration.dart';
import 'video_call_screens.dart';

/// Screen used by a **client** (blind user) to request help from volunteers.
///
/// Flow:
/// - User taps "Call a Volunteer" → new document in `help_requests` collection
///   with status `pending`.
/// - All online volunteers listen for `pending` requests.
/// - First volunteer who accepts atomically updates the document to
///   `status: accepted, acceptedBy: <volunteerUid>`.
/// - This screen listens to that document; once it becomes `accepted`, the
///   client is taken to a one-way video call screen where their camera is shared.
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

  Future<void> _ensureLoggedIn() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) return;

    // Redirect to registration if not logged in
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegistrationScreen()),
    );
  }

  Future<void> _createHelpRequest() async {
    await _ensureLoggedIn();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _creatingRequest = true);
    try {
      final doc = await _helpRequests.add({
        'clientId': user.uid,
        'status': 'pending', // pending → accepted / cancelled / ended
        'createdAt': FieldValue.serverTimestamp(),
      });
      setState(() => _currentRequestId = doc.id);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create help request: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _creatingRequest = false);
      }
    }
  }

  Future<void> _cancelRequest() async {
    if (_currentRequestId == null) return;
    try {
      await _helpRequests.doc(_currentRequestId).update({
        'status': 'cancelled',
      });
    } catch (_) {}
    if (mounted) {
      setState(() => _currentRequestId = null);
    }
  }

  void _openProfileOrRegistration() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RegistrationScreen()),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talk with Volunteer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: _openProfileOrRegistration,
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
                  label: Text(
                    _creatingRequest
                        ? 'Requesting help...'
                        : 'Call a Volunteer',
                  ),
                  onPressed: _creatingRequest ? null : _createHelpRequest,
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

                    if (status == 'accepted') {
                      // Navigate once to the video call screen
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        final requestId = _currentRequestId;
                        if (requestId == null || !mounted) return;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ClientVideoCallScreen(helpRequestId: requestId),
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
