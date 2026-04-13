import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Handles FCM token management and incoming notification routing.
class FcmService {
  static final FcmService _instance = FcmService._();
  factory FcmService() => _instance;
  FcmService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// Global navigator key so we can push screens from notification handlers.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // ───────────────────── initialise ──────────────────────
  Future<void> init() async {
    // Request permission (iOS / Android 13+)
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Save the token to Firestore whenever it refreshes
    _messaging.onTokenRefresh.listen(_saveToken);

    // Get the current token
    final token = await _messaging.getToken();
    if (token != null) await _saveToken(token);

    // Foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // When user taps notification while app is in background
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // Check if app was opened from a terminated state via notification
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleNotificationTap(initialMessage);
    }
  }

  // ───────────────── token persistence ───────────────────
  Future<void> _saveToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
      'fcmToken': token,
    });
    debugPrint('[FCM] Token saved for ${user.uid}');
  }

  /// Call this after login / registration so the token is recorded.
  Future<void> saveTokenForCurrentUser() async {
    final token = await _messaging.getToken();
    if (token != null) await _saveToken(token);
  }

  // ─────────────── foreground handler ────────────────────
  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[FCM] Foreground message: ${message.data}');

    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    final data = message.data;
    final type = data['type'];

    if (type == 'help_request') {
      final requestId = data['requestId'] ?? '';
      final clientName = data['clientName'] ?? 'A client';

      // Show an in-app dialog for volunteer to accept / reject
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Help Request'),
          content: Text('$clientName needs your help. Accept the call?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(), // reject
              child: const Text('Reject'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _acceptHelpRequest(requestId);
              },
              child: const Text('Accept'),
            ),
          ],
        ),
      );
    }
  }

  // ────────────── notification tap handler ────────────────
  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('[FCM] Notification tapped: ${message.data}');
    final data = message.data;
    final type = data['type'];

    if (type == 'help_request') {
      final requestId = data['requestId'] ?? '';
      _acceptHelpRequest(requestId);
    }
  }

  // ──────────────── accept a help_request ─────────────────
  Future<void> _acceptHelpRequest(String requestId) async {
    if (requestId.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final docRef =
        FirebaseFirestore.instance.collection('help_requests').doc(requestId);

    // Use a transaction so only the first volunteer wins
    try {
      await FirebaseFirestore.instance.runTransaction((txn) async {
        final snap = await txn.get(docRef);
        if (!snap.exists) return;
        final status = snap.data()?['status'] as String?;
        if (status != 'pending') return; // already taken

        txn.update(docRef, {
          'status': 'accepted',
          'volunteerId': user.uid,
          'acceptedAt': FieldValue.serverTimestamp(),
        });
      });

      debugPrint('[FCM] Accepted help request $requestId');

      // Navigate to the video call screen as a volunteer
      // We import lazily via the navigator key to avoid circular deps.
      final nav = navigatorKey.currentState;
      if (nav != null) {
        // Dynamically push the video call screen.
        // We pass role = 'volunteer' and the requestId.
        nav.pushNamed(
          '/video_call',
          arguments: {'role': 'volunteer', 'requestId': requestId},
        );
      }
    } catch (e) {
      debugPrint('[FCM] Error accepting request: $e');
    }
  }
}

/// Top-level handler required by firebase_messaging for background messages.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM] Background message: ${message.data}');
  // We don't need to do complex work here; the notification itself will
  // contain action buttons handled by the OS notification tray.
}
