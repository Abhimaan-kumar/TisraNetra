import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Shared Firestore collection for volunteer help requests.
CollectionReference<Map<String, dynamic>> helpRequestsCollection() =>
    FirebaseFirestore.instance.collection('help_requests');

/// Basic WebRTC configuration (STUN only – add TURN for production).
const Map<String, dynamic> _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};

Future<RTCPeerConnection> _createPeerConnection() async {
  final pc = await createPeerConnection(_iceServers);
  await pc.setConfiguration({'sdpSemantics': 'unified-plan'});
  return pc;
}

/// One-way video call screen for the **client** (caller).
///
/// Uses flutter_webrtc to send the client's camera/mic to the volunteer.
class ClientVideoCallScreen extends StatefulWidget {
  final String helpRequestId;

  const ClientVideoCallScreen({super.key, required this.helpRequestId});

  @override
  State<ClientVideoCallScreen> createState() => _ClientVideoCallScreenState();
}

class _ClientVideoCallScreenState extends State<ClientVideoCallScreen> {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _statusSub;

  bool _initializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _startWebRTCCall();
    _listenToRequestEnd();
  }

  Future<void> _startWebRTCCall() async {
    try {
      // 1) Get local media (back camera + mic)
      final mediaConstraints = {
        'audio': true,
        'video': {
          'facingMode': 'environment',
        },
      };
      final stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);

      // 2) Create peer connection
      final pc = await _createPeerConnection();

      // 3) Add local tracks
      for (var track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }

      // 4) Show local preview
      _localRenderer.srcObject = stream;

      // 5) Handle ICE candidates → /callerCandidates
      final callerCandidates = helpRequestsCollection()
          .doc(widget.helpRequestId)
          .collection('callerCandidates');

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate == null) return;
        callerCandidates.add({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      // 6) Create offer & setLocalDescription
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      // 7) Store offer on help_requests/{id}
      await helpRequestsCollection().doc(widget.helpRequestId).set(
        {
          'offer': {
            'type': offer.type,
            'sdp': offer.sdp,
          },
        },
        SetOptions(merge: true),
      );

      bool remoteSet = false; // <— add this flag before setting up the listener

      // 8) Listen for answer
      helpRequestsCollection()
          .doc(widget.helpRequestId)
          .snapshots()
          .listen((doc) async {
        final data = doc.data();
        if (data == null) return;
        final answer = data['answer'];
        if (answer != null &&  !remoteSet) {
          final desc = RTCSessionDescription(
            answer['sdp'] as String,
            answer['type'] as String,
          );
          await pc.setRemoteDescription(desc);
          remoteSet = true; // <— set flag to true
        }
      });

      // 9) Listen for callee ICE candidates
      helpRequestsCollection()
          .doc(widget.helpRequestId)
          .collection('calleeCandidates')
          .snapshots()
          .listen((snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data();
            if (data == null) continue;
            final candidate = RTCIceCandidate(
              data['candidate'] as String,
              data['sdpMid'] as String?,
              data['sdpMLineIndex'] as int?,
            );
            pc.addCandidate(candidate);
          }
        }
      });

      if (!mounted) return;
      setState(() {
        _peerConnection = pc;
        _localStream = stream;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Unable to start call: $e';
        _initializing = false;
      });
    }
  }

  void _listenToRequestEnd() {
    _statusSub = helpRequestsCollection()
        .doc(widget.helpRequestId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists) {
        _endCall(pop: true);
        return;
      }
      final data = doc.data() ?? {};
      final status = data['status'] as String? ?? 'pending';
      if (status == 'ended' || status == 'cancelled') {
        _endCall(pop: true);
      }
    });
  }

  Future<void> _endCall({bool pop = false}) async {
    try {
      await helpRequestsCollection().doc(widget.helpRequestId).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    await _peerConnection?.close();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localRenderer.srcObject = null;

    if (pop && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _peerConnection?.close();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Help (Your Camera)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_end),
            color: Colors.red,
            onPressed: () => _endCall(pop: true),
          ),
        ],
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : (_error != null
              ? Center(child: Text(_error!))
              : Column(
                  children: [
                    Expanded(
                      child: _localRenderer.srcObject != null
                          ? RTCVideoView(_localRenderer, mirror: false)
                          : const Center(child: Text('Camera not available')),
                    ),
                    Container(
                      color: Colors.black87,
                      padding: const EdgeInsets.all(16),
                      width: double.infinity,
                      child: const Text(
                        'A volunteer can see this video feed and talk to you.\n'
                        'You will not see their video. Move your phone slowly '
                        'so they can describe your surroundings.',
                        style: TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                )),
    );
  }
}

/// Volunteer-side screen that is opened once a volunteer has accepted
/// a help request. Subscribes to the client's WebRTC stream.
class VolunteerVideoCallScreen extends StatefulWidget {
  final String helpRequestId;

  const VolunteerVideoCallScreen({super.key, required this.helpRequestId});

  @override
  State<VolunteerVideoCallScreen> createState() => _VolunteerVideoCallScreenState();
}

class _VolunteerVideoCallScreenState extends State<VolunteerVideoCallScreen> {
  RTCPeerConnection? _peerConnection;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _statusSub;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
    _joinWebRTCCall();
    _listenToRequestEnd();
  }

  Future<void> _joinWebRTCCall() async {
    try {
      final pc = await _createPeerConnection();

      // Collect incoming tracks into a remote stream
      final remoteStream = await createLocalMediaStream('remote');
      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams[0];
        } else {
          remoteStream.addTrack(event.track);
          _remoteRenderer.srcObject = remoteStream;
        }
      };

      // Handle ICE candidates → /calleeCandidates
      final calleeCandidates = helpRequestsCollection()
          .doc(widget.helpRequestId)
          .collection('calleeCandidates');

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate == null) return;
        calleeCandidates.add({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      // Read offer
      final doc = await helpRequestsCollection().doc(widget.helpRequestId).get();
      final data = doc.data();
      if (data == null || data['offer'] == null) {
        setState(() {
          _peerConnection = pc;
          _remoteStream = remoteStream;
        });
        return;
      }

      final offer = data['offer'];
      await pc.setRemoteDescription(RTCSessionDescription(
        offer['sdp'] as String,
        offer['type'] as String,
      ));

      // Create and send answer
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      await helpRequestsCollection().doc(widget.helpRequestId).set(
        {
          'answer': {
            'type': answer.type,
            'sdp': answer.sdp,
          },
        },
        SetOptions(merge: true),
      );

      // Listen for caller ICE candidates
      helpRequestsCollection()
          .doc(widget.helpRequestId)
          .collection('callerCandidates')
          .snapshots()
          .listen((snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data();
            if (data == null) continue;
            final candidate = RTCIceCandidate(
              data['candidate'] as String,
              data['sdpMid'] as String?,
              data['sdpMLineIndex'] as int?,
            );
            pc.addCandidate(candidate);
          }
        }
      });

      if (!mounted) return;
      setState(() {
        _peerConnection = pc;
        _remoteStream = remoteStream;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to join call: $e')),
      );
    }
  }

  void _listenToRequestEnd() {
    _statusSub = helpRequestsCollection()
        .doc(widget.helpRequestId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists) {
        _endCall();
        return;
      }
      final status = (doc.data()?['status'] as String?) ?? 'pending';
      if (status == 'ended' || status == 'cancelled') {
        _endCall();
      }
    });
  }

  Future<void> _endCall() async {
    try {
      await helpRequestsCollection().doc(widget.helpRequestId).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    await _peerConnection?.close();
    _remoteStream?.getTracks().forEach((t) => t.stop());
    _remoteRenderer.srcObject = null;

    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _peerConnection?.close();
    _remoteStream?.getTracks().forEach((t) => t.stop());
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Helping Client'),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_end),
            color: Colors.red,
            onPressed: _endCall,
          ),
        ],
      ),
      body: Center(
        child: _remoteRenderer.srcObject == null
            ? const Text('Waiting for client video...')
            : RTCVideoView(_remoteRenderer),
      ),
    );
  }
}

/// Utility method that volunteers can call to attempt to accept a help request.
///
/// This uses a Firestore transaction so that only the **first** volunteer to
/// accept a given `pending` request will succeed. Others will receive `false`.
Future<bool> tryAcceptHelpRequest(String requestId) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return false;

  final docRef = helpRequestsCollection().doc(requestId);
  return FirebaseFirestore.instance.runTransaction<bool>((tx) async {
    final snap = await tx.get(docRef);
    if (!snap.exists) return false;
    final data = snap.data() ?? {};
    final status = data['status'] as String? ?? 'pending';
    if (status != 'pending') return false;

    tx.update(docRef, {
      'status': 'accepted',
      'acceptedBy': user.uid,
      'acceptedAt': FieldValue.serverTimestamp(),
    });
    return true;
  });
}

