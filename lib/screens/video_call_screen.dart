import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';

/// Full-screen video call screen.
///
/// • **Client role** – shows local camera preview (the video being sent to the
///   volunteer) with a small "Waiting for volunteer…" overlay until the peer
///   connects.
/// • **Volunteer role** – shows the remote video feed from the client's camera.
///   No local camera is used.
class VideoCallScreen extends StatefulWidget {
  final String role;      // 'client' or 'volunteer'
  final String requestId; // Firestore help_requests doc ID

  const VideoCallScreen({
    super.key,
    required this.role,
    required this.requestId,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  late SignalingService _signaling;
  bool _connected = false;
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _signaling = SignalingService(
      requestId: widget.requestId,
      role: widget.role,
    );
    _setup();
  }

  Future<void> _setup() async {
    await _signaling.init();

    _signaling.onConnected = () {
      if (mounted) setState(() => _connected = true);
    };
    _signaling.onDisconnected = () {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Call disconnected')),
        );
        Navigator.of(context).pop();
      }
    };

    if (widget.role == 'client') {
      await _signaling.startAsClient();
    } else {
      await _signaling.startAsVolunteer();
    }

    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _hangUp() async {
    await _signaling.endCall();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ─── Main video feed ───────────────────────────────
          if (widget.role == 'client')
            // Client sees their own camera
            Positioned.fill(
              child: RTCVideoView(
                _signaling.localRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: false,
              ),
            )
          else
            // Volunteer sees the remote (client's) camera
            Positioned.fill(
              child: _connected
                  ? RTCVideoView(
                      _signaling.remoteRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 16),
                          Text(
                            'Connecting to client...',
                            style: TextStyle(color: Colors.white, fontSize: 18),
                          ),
                        ],
                      ),
                    ),
            ),

          // ─── Connection overlay for client ─────────────────
          if (widget.role == 'client' && !_connected)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Waiting for volunteer…',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ─── Connected badge ──────────────────────────────
          if (_connected)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        widget.role == 'client'
                            ? 'Volunteer connected'
                            : 'Connected to client',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ─── Initializing spinner ─────────────────────────
          if (_initializing)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 12),
                      Text(
                        'Setting up camera…',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ─── Bottom bar with hang-up button ───────────────
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _hangUp,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}