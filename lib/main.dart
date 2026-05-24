import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'services/language_preference_service.dart';
import 'screens/home_screen.dart';
import 'screens/video_call_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'services/fcm_service.dart';
import 'theme/app_theme.dart';


void main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Register background message handler (must be top-level function)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Initialise FCM (permissions, token, foreground listener) without blocking the UI
  FcmService().init().catchError((e) {
    debugPrint('FCM Init error: $e');
  });

  // Immersive system UI for premium feel
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Determine home title
  String homeTitle = 'Tisra Netra';
  final user = FirebaseAuth.instance.currentUser;
  if (user != null) {
    await LanguagePreferenceService().loadForCurrentUser();
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final userType = doc.data()?['userType'] as String?;
      final name = doc.data()?['name'] as String?;
      if (userType != null && userType.toLowerCase() == 'volunteer') {
        homeTitle = ' $userType';
      } else {
        homeTitle = ' $name';
      }
    } catch (e) {
      // Fallback to default
    }
  }

  runApp(MyApp(homeTitle: homeTitle));
}

class MyApp extends StatefulWidget {
  final String homeTitle;
  const MyApp({super.key, required this.homeTitle});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    FlutterNativeSplash.remove();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: FcmService.navigatorKey,
      title: 'Tisra Netra',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: HomeScreen(title: widget.homeTitle),
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
