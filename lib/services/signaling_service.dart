import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC signaling layer backed by Firestore.
///
/// Firestore document layout:
///   help_requests/{requestId}/signaling/offer   → { sdp, type }
///   help_requests/{requestId}/signaling/answer  → { sdp, type }
///   help_requests/{requestId}/signaling/candidates/{auto}  → { candidate, sdpMid, sdpMLineIndex, from }
class SignalingService {
  final String requestId;
  final String role; // 'client' or 'volunteer'

  SignalingService({required this.requestId, required this.role});

  // ─── Firestore refs ────────────────────────────────────
  DocumentReference get _offerDoc => FirebaseFirestore.instance
      .collection('help_requests')
      .doc(requestId)
      .collection('signaling')
      .doc('offer');

  DocumentReference get _answerDoc => FirebaseFirestore.instance
      .collection('help_requests')
      .doc(requestId)
      .collection('signaling')
      .doc('answer');

  CollectionReference get _candidatesCol => FirebaseFirestore.instance
      .collection('help_requests')
      .doc(requestId)
      .collection('signaling')
      .doc('candidates_data')
      .collection('items');

  // ─── WebRTC objects ────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final List<StreamSubscription> _subs = [];

  // State for queuing candidates
  bool _isRemoteSet = false;
  final List<RTCIceCandidate> _remoteCandidatesQueue = [];

  // Public renderers
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  // Callbacks
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  // ICE servers (STUN & TURN)
  static const Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:global.stun.twilio.com:3478'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      }
    ],
  };

  // ──────────────────── init ─────────────────────────────
  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  void _addIceCandidate(RTCIceCandidate candidate) {
    if (_isRemoteSet && _pc != null) {
      _pc!.addCandidate(candidate);
    } else {
      _remoteCandidatesQueue.add(candidate);
    }
  }

  void _onRemoteDescriptionSet() {
    _isRemoteSet = true;
    for (final candidate in _remoteCandidatesQueue) {
      _pc?.addCandidate(candidate);
    }
    _remoteCandidatesQueue.clear();
  }

  // ──────────────────── start call (client) ──────────────
  /// Client creates the offer and sends their video/audio.
  Future<void> startAsClient() async {
    // 1. Get local media (video + audio)
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'environment', // rear camera for showing surroundings
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      },
    });
    localRenderer.srcObject = _localStream;

    // 2. Create peer connection
    _pc = await createPeerConnection(_config);

    // 3. Add local tracks
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Listen for remote tracks (volunteer's audio)
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
      }
    };

    // 4. ICE candidate handler
    _pc!.onIceCandidate = (candidate) {
      _candidatesCol.add({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'from': 'client',
      });
    };

    // 5. Connection state
    _pc!.onConnectionState = (state) {
      debugPrint('[WebRTC] connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected?.call();
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onDisconnected?.call();
      }
    };

    // 6. Create offer
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    // 7. Store offer in Firestore
    await _offerDoc.set({
      'sdp': offer.sdp,
      'type': offer.type,
    });

    // 8. Listen for the answer
    _subs.add(_answerDoc.snapshots().listen((snap) async {
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
      final answer = RTCSessionDescription(data['sdp'], data['type']);
      final currentRemote = await _pc!.getRemoteDescription();
      if (currentRemote == null) {
        await _pc!.setRemoteDescription(answer);
        _onRemoteDescriptionSet();
      }
    }));

    // 9. Listen for remote ICE candidates (from volunteer)
    _subs.add(_candidatesCol
        .where('from', isEqualTo: 'volunteer')
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final d = change.doc.data() as Map<String, dynamic>;
          _addIceCandidate(RTCIceCandidate(
            d['candidate'],
            d['sdpMid'],
            d['sdpMLineIndex'],
          ));
        }
      }
    }));
  }

  // ──────────────────── join call (volunteer) ─────────────
  /// Volunteer receives the client's video/audio stream and sends their local audio.
  Future<void> startAsVolunteer() async {
    // 1. Get local media (audio only)
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    // 2. Create peer connection
    _pc = await createPeerConnection(_config);

    // 3. Add local tracks (audio)
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // 4. Receive remote stream
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
      }
    };

    // 5. ICE candidate handler
    _pc!.onIceCandidate = (candidate) {
      _candidatesCol.add({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'from': 'volunteer',
      });
    };

    // 6. Connection state
    _pc!.onConnectionState = (state) {
      debugPrint('[WebRTC] connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected?.call();
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onDisconnected?.call();
      }
    };

    // 7. Wait for the offer to appear
    _subs.add(_offerDoc.snapshots().listen((snap) async {
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;

      final currentRemote = await _pc!.getRemoteDescription();
      if (currentRemote != null) return; // already set

      final offer = RTCSessionDescription(data['sdp'], data['type']);
      await _pc!.setRemoteDescription(offer);
      _onRemoteDescriptionSet();

      // Create answer
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _answerDoc.set({
        'sdp': answer.sdp,
        'type': answer.type,
      });
    }));

    // 8. Listen for remote ICE candidates (from client)
    _subs.add(_candidatesCol
        .where('from', isEqualTo: 'client')
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final d = change.doc.data() as Map<String, dynamic>;
          _addIceCandidate(RTCIceCandidate(
            d['candidate'],
            d['sdpMid'],
            d['sdpMLineIndex'],
          ));
        }
      }
    }));
  }

  // ──────────────────── cleanup ──────────────────────────
  Future<void> dispose() async {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    await _pc?.close();
    _pc = null;

    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }

  /// End the call and update Firestore status.
  Future<void> endCall() async {
    await FirebaseFirestore.instance
        .collection('help_requests')
        .doc(requestId)
        .update({'status': 'ended'});
    await dispose();
  }
}
