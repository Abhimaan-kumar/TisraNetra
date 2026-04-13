import 'package:flutter/material.dart';
import 'screens/splash_screen.dart';
import 'screens/video_call_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'services/fcm_service.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Register background message handler (must be top-level function)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Initialise FCM (permissions, token, foreground listener) without blocking the UI
  FcmService().init().catchError((e) {
    debugPrint('FCM Init error: $e');
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: FcmService.navigatorKey,
      title: 'Life Lens',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(255, 3, 251, 40)),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
      // Named route used by FcmService to navigate volunteers to video call
      onGenerateRoute: (settings) {
        if (settings.name == '/video_call') {
          final args = settings.arguments as Map<String, dynamic>? ?? {};
          return MaterialPageRoute(
            builder: (_) => VideoCallScreen(
              role: args['role'] ?? 'volunteer',
              requestId: args['requestId'] ?? '',
            ),
          );
        }
        return null;
      },
    );
  }
}
