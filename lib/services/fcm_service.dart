import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

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
    // Request permission on Android 13+ programmatically
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

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

  // ─── Pending message for cold-start ─────────────────────
  RemoteMessage? _pendingMessage;

  /// Call from SplashScreen / HomeScreen after navigation is settled.
  void checkPendingNotification() {
    if (_pendingMessage != null) {
      final msg = _pendingMessage!;
      _pendingMessage = null;
      _showIncomingCallDialog(msg);
    }
  }

  // ─────────────── show dialog helper ─────────────────────
  Future<void> _showIncomingCallDialog(RemoteMessage message) async {
    final data = message.data;
    final type = data['type'];
    if (type != 'help_request') return;

    final requestId = data['requestId'] ?? '';
    final clientName = data['clientName'] ?? 'A client';

    // Wait for navigator to be available (up to 10 seconds)
    int retries = 0;
    while (navigatorKey.currentState == null && retries < 20) {
      await Future.delayed(const Duration(milliseconds: 500));
      retries++;
    }

    if (navigatorKey.currentState == null) {
      debugPrint('[FCM] Navigator not ready — storing as pending');
      _pendingMessage = message;
      return;
    }

    // Use addPostFrameCallback to ensure we're not in a build phase
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = navigatorKey.currentState;
      if (nav == null) return;

      try {
        showDialog(
          context: nav.context,
          barrierDismissible: false,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('Help Request'),
            content: Text('$clientName needs your help. Accept the call?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(), // reject
                child: const Text('Reject'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(dialogCtx).pop();
                  _acceptHelpRequest(requestId);
                },
                child: const Text('Accept'),
              ),
            ],
          ),
        );
      } catch (e) {
        debugPrint('[FCM] Error showing dialog: $e');
      }
    });
  }

  // ─────────────── foreground handler ────────────────────
  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[FCM] Foreground message: ${message.data}');
    _showIncomingCallDialog(message);
  }

  // ────────────── notification tap handler ────────────────
  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('[FCM] Notification tapped: ${message.data}');
    _showIncomingCallDialog(message);
  }

  // ──────────────── accept a help_request ─────────────────
  Future<void> _acceptHelpRequest(String requestId) async {
    if (requestId.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final ctx = navigatorKey.currentContext;

    final docRef =
        FirebaseFirestore.instance.collection('help_requests').doc(requestId);

    try {
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Accepting request...')),
        );
      }

      await FirebaseFirestore.instance.runTransaction((txn) async {
        final snap = await txn.get(docRef);
        if (!snap.exists) {
          throw Exception('Request no longer exists.');
        }
        final status = snap.data()?['status'] as String?;
        if (status != 'pending') {
          throw Exception('Request was already taken or cancelled.');
        }

        txn.update(docRef, {
          'status': 'accepted',
          'volunteerId': user.uid,
          'acceptedAt': FieldValue.serverTimestamp(),
        });
      });

      debugPrint('[FCM] Accepted help request $requestId');

      final nav = navigatorKey.currentState;
      if (nav != null) {
        nav.pushNamed(
          '/video_call',
          arguments: {'role': 'volunteer', 'requestId': requestId},
        );
      } else {
        debugPrint('[FCM] CRITICAL: Navigator state is null');
        if (ctx != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text('Error: App navigator is missing')),
          );
        }
      }
    } catch (e) {
      debugPrint('[FCM] Error accepting request: $e');
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Failed to accept: $e')),
        );
      }
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
