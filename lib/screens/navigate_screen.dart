// lib/screens/navigate_screen.dart
//
// Smart Navigation Screen with two modes:
//   ┌─────────────────────────────────────────────────┐
//   │ Walk Mode     — Real-time obstacle detection +  │
//   │                 directional guidance +          │
//   │                 depth estimation +              │
//   │                 path boundary lines +           │
//   │                 face recognition                │
//   │ Destination   — Voice-activated turn-by-turn    │
//   │   Mode          navigation with safety overlay  │
//   └─────────────────────────────────────────────────┘
//
// Voice-first: all interactions via volume buttons + STT/TTS.
// Bilingual: English + Hindi.

import 'dart:async';
import 'dart:math' show sin, cos;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../services/nav_object_detection_service.dart';
import '../services/depth_estimation_service.dart';
import '../services/path_analyzer_service.dart';
import '../services/navigation_service.dart';
import '../services/face_embedding_service.dart';
import '../services/face_db_service.dart';
import '../utils/image_utils.dart';
import '../services/tts_service.dart';
import '../services/scene_labeling_service.dart';
import '../services/language_preference_service.dart';
import '../widgets/volume_button_mixin.dart';
import '../theme/app_theme.dart';
import 'registration.dart';
import 'profile_screen.dart';

// ─── Constants ───────────────────────────────────────────────────────────────

const _kProcessEveryN = 3;
const _kFaceThreshold = 0.6;

// Colours
const _kIndigo = Color(0xFF2980BA);
const _kIndigoLight = Color(0xFF5D9BCA);
const _kGreen = Color(0xFF00E676);
const _kYellow = Color(0xFFFFD600);
const _kRed = Color(0xFFFF3D71);
const _kSurface = Color(0xFF263238);
const _kCard = Color(0xFF37474F);
const _kCardBorder = Color(0xFF455A64);
const _kCyan = Color(0xFF00E5FF);
const _kOrange = Color(0xFFFF9100);

enum _NavMode { modeSelect, walkMode, destinationMode }

// ─── Screen ──────────────────────────────────────────────────────────────────

class NavigateScreen extends StatefulWidget {
  const NavigateScreen({super.key});
  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {
  // ── Services ──────────────────────────────────────────────────────────────
  final TtsService _tts = TtsService();
  final NavObjectDetectionService _detectionService =
      NavObjectDetectionService();
  final PathAnalyzerService _pathAnalyzer = PathAnalyzerService();
  final NavigationService _navService = NavigationService();
  final FaceEmbeddingService _faceService = FaceEmbeddingService();
  final FaceDBService _faceDB = FaceDBService();
  final SceneLabelingService _sceneLabeler = SceneLabelingService();
  late FaceDetector _faceDetector;

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _camReady = false;
  int _sensorOrientation = 0;
  int _frameCount = 0;
  bool _isProcessing = false;

  // ── Mode state ────────────────────────────────────────────────────────────
  _NavMode _mode = _NavMode.modeSelect;

  // ── Walk mode state (ValueNotifiers — micro-rebuilds) ─────────────────────
  final ValueNotifier<List<NavDetectedObject>> _detectionsN = ValueNotifier([]);
  final ValueNotifier<PathAnalysis?> _pathAnalysisN = ValueNotifier(null);
  final ValueNotifier<String> _walkStatusN = ValueNotifier('Initializing...');
  bool _walkActive = false;

  // ── Face recognition state ────────────────────────────────────────────────
  List<PersonRecord> _persons = [];
  final ValueNotifier<String> _faceNameN = ValueNotifier('');
  DateTime _lastFaceAnnounce = DateTime(2000);

  // ── Destination mode state (ValueNotifiers — micro-rebuilds) ──────────────
  final ValueNotifier<String> _destStatusN = ValueNotifier('Say your destination');
  final ValueNotifier<String> _currentInstructionN = ValueNotifier('');
  bool _navActive = false;
  final ValueNotifier<NavigationSnapshot?> _navSnapshotN = ValueNotifier(null);
  final ValueNotifier<bool> _isReroutingN = ValueNotifier(false);
  final ValueNotifier<bool> _isApproachingTurnN = ValueNotifier(false);

  // ── Safety vs Route priority ──────────────────────────────────────────────
  DateTime _lastSafetySpeak = DateTime(2000);

  // ── Safe direction for arrow overlay ─────────────────────────────────────
  final ValueNotifier<double> _safeDirectionAngleN = ValueNotifier(0.0);

  // ── Init state ────────────────────────────────────────────────────────────
  bool _initialized = false;
  String _initError = '';

  // ═══════════════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _initAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed && _initialized) {
      if (_mode == _NavMode.walkMode || _mode == _NavMode.destinationMode) {
        _initCamera();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _detectionService.dispose();
    _faceService.dispose();
    _faceDetector.close();
    _sceneLabeler.dispose();
    _navService.dispose();
    _tts.stop();
    // Dispose ValueNotifiers
    _detectionsN.dispose();
    _pathAnalysisN.dispose();
    _walkStatusN.dispose();
    _faceNameN.dispose();
    _destStatusN.dispose();
    _currentInstructionN.dispose();
    _navSnapshotN.dispose();
    _isReroutingN.dispose();
    _isApproachingTurnN.dispose();
    _safeDirectionAngleN.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Initialisation
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initAll() async {
    try {
      // Init object detection model
      await _detectionService.init();

      // Init face recognition
      await _faceService.init();
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableTracking: true,
          minFaceSize: 0.15,
        ),
      );
      _persons = await _faceDB.getAllPersons();

      // Navigation service callbacks
      _navService.onInstruction = (en, hi) {
        if (!mounted) return;
        final isHindi = LanguagePreferenceService().isHindi;
        _currentInstructionN.value = isHindi ? hi : en;
        // Only speak route instructions if no critical safety alert active
        final safetyRecent = DateTime.now().difference(_lastSafetySpeak).inSeconds < 3;
        if (!safetyRecent) {
          _tts.speak(isHindi ? hi : en);
        }
      };
      _navService.onArrived = () {
        if (!mounted) return;
        final isHindi = LanguagePreferenceService().isHindi;
        _destStatusN.value = isHindi ? 'आप पहुँच गए हैं!' : 'You have arrived!';
        _navSnapshotN.value = null;
        setState(() {
          _navActive = false;
          _walkActive = false;
        });
        _tts.speakLocalized('You have arrived at your destination. Well done!', 'आप अपनी मंजिल पर पहुंच गए हैं। बहुत बढ़िया!');
      };
      _navService.onStateChange = (state) {
        if (!mounted) return;
        final isHindi = LanguagePreferenceService().isHindi;
        if (state == NavigationState.error) {
          _destStatusN.value = isHindi ? 'नेविगेशन त्रुटि। पुनः प्रयास करें।' : 'Navigation error. Try again.';
        } else if (state == NavigationState.rerouting) {
          _isReroutingN.value = true;
          _destStatusN.value = isHindi ? 'रास्ता फिर से खोज रहे हैं...' : 'Recalculating route...';
        } else if (state == NavigationState.navigating && _isReroutingN.value) {
          _isReroutingN.value = false;
          _destStatusN.value = isHindi ? 'रास्ता अपडेट हो गया।' : 'Route updated.';
        }
      };
      _navService.onNavigationUpdate = (snapshot) {
        if (!mounted) return;
        _navSnapshotN.value = snapshot;
        _isApproachingTurnN.value = snapshot.isApproachingTurn;
        if (_navActive) {
          final isHindi = LanguagePreferenceService().isHindi;
          _destStatusN.value = '${_navService.remainingDistanceText} · ${isHindi ? 'अनुमानित समय' : 'ETA'} ${snapshot.eta}';
        }
      };
      _navService.onReroute = (en, hi) {
        if (!mounted) return;
        final isHindi = LanguagePreferenceService().isHindi;
        _tts.speak(isHindi ? hi : en);
      };

      if (!mounted) return;
      setState(() {
        _initialized = true;
      });

      await _tts.speakLocalized(
        'Navigation ready. Say walk mode for obstacle detection, '
        'or destination mode to navigate somewhere. '
        'Press volume up to speak.',
        'नेविगेशन तैयार है। बाधाओं का पता लगाने के लिए वॉक मोड बोलें, या कहीं नेविगेट करने के लिए डेस्टिनेशन मोड बोलें। बोलने के लिए वॉल्यूम अप दबाएं।',
      );
    } catch (e) {
      debugPrint('[Navigate] Init error: $e');
      if (mounted) {
        setState(() {
          _initError = e.toString();
        });
      }
      _tts.speakLocalized('Failed to initialize navigation. Please restart.', 'नेविगेशन आरंभ करने में विफल। कृपया फिर से चालू करें।');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Camera
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final camera = cameras.first;
    _sensorOrientation = camera.sensorOrientation;

    final ctrl = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await ctrl.initialize();
    if (!mounted) return;

    setState(() {
      _cam = ctrl;
      _camReady = true;
    });

    ctrl.startImageStream(_onCameraFrame);
  }

  void _stopCamera() {
    try {
      _cam?.stopImageStream();
    } catch (_) {}
    _cam?.dispose();
    _cam = null;
    _camReady = false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Frame processing
  // ═══════════════════════════════════════════════════════════════════════════

  void _onCameraFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % _kProcessEveryN != 0) return;
    if (_isProcessing) return;
    _isProcessing = true;
    _processFrame(image);
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      // 1. Object detection (with integrated depth estimation)
      final detections =
          await _detectionService.detect(image, _sensorOrientation);

      // 1b. Run MiDaS depth map estimation (for safe direction + enhanced depth)
      final depthService = _detectionService.depthService;
      if (depthService.isMidasReady) {
        await depthService.estimateDepthMap(image, _sensorOrientation);
      }
      final safeDir = depthService.lastSafeDirection;

      // 2. Structural blockage detection (walls, doors)
      String? structuralBlocker;
      if (detections.isEmpty || detections.every((d) => d.dangerLevel == DangerLevel.info)) {
         final inputImage = await _buildInputImage(image);
         structuralBlocker = await _sceneLabeler.detectStructuralBlockage(inputImage);
      }

      // 3. Path analysis (with boundary lines + urgency + clock directions)
      final analysis = _pathAnalyzer.analyze(
        detections,
        structuralBlocker: structuralBlocker,
        safeDirection: safeDir,
      );

      // 4. Face recognition (if person detected)
      String? faceName;
      if (detections.any((d) => d.label == 'person')) {
        faceName = await _tryFaceRecognition(image);
      }

      if (!mounted) return;

      final isHindi = LanguagePreferenceService().isHindi;

      _detectionsN.value = detections;
      _pathAnalysisN.value = analysis;
      _safeDirectionAngleN.value = analysis.safeDirection.angleRadians;
      if (_mode == _NavMode.walkMode) {
        _walkStatusN.value = isHindi ? analysis.guidanceHi : analysis.guidance;
      }

      // 5. Speak guidance — safety alerts take priority over route instructions
      if (_walkActive || _navActive) {
        final isHindi = LanguagePreferenceService().isHindi;
        final guidanceText = isHindi ? analysis.guidanceHi : analysis.guidance;
        if (_pathAnalyzer.shouldSpeak(analysis)) {
          // In destination mode: safety alerts override route guidance
          if (_mode == _NavMode.destinationMode && _navActive) {
            // Only speak safety if critical/high urgency
            if (analysis.urgency == VoiceUrgency.critical ||
                analysis.urgency == VoiceUrgency.high) {
              _lastSafetySpeak = DateTime.now();
              await _tts.speakWithUrgency(guidanceText, analysis.urgency);
            }
            // Medium/low urgency: don't interrupt route instructions
          } else {
            // Walk mode: always speak
            await _tts.speakWithUrgency(guidanceText, analysis.urgency);
          }
        }
        // Announce identified face
        if (faceName != null) {
          _announceFace(faceName);
        }
      }
    } catch (e) {
      debugPrint('[Navigate] Frame error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Face recognition
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String?> _tryFaceRecognition(CameraImage image) async {
    if (!_faceService.isInitialized || _persons.isEmpty) return null;

    try {
      // Build InputImage for ML Kit face detection
      final inputImage = await _buildInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);
      if (faces.isEmpty) return null;

      // Convert to RGB and process using background isolate
      final faceImage = await processCameraImageIsolate(
        image: image,
        sensorOrientation: _sensorOrientation,
        cropRect: faces.first.boundingBox,
      );
      final embedding = _faceService.getEmbedding(faceImage);

      // Match against database
      String bestName = 'Unknown person';
      double bestSim = 0.0;
      for (final person in _persons) {
        for (final stored in person.embeddings) {
          final sim = _faceService.cosineSimilarity(embedding, stored);
          if (sim > bestSim) {
            bestSim = sim;
            bestName = person.name;
          }
        }
      }

      if (bestSim < _kFaceThreshold) return 'Unknown person';
      return bestName;
    } catch (e) {
      debugPrint('[Navigate] Face recognition error: $e');
      return null;
    }
  }

  Future<InputImage> _buildInputImage(CameraImage image) async {
    final nv21 = await convertToNV21(image);

    final rotation = switch (_sensorOrientation) {
      0 => InputImageRotation.rotation0deg,
      90 => InputImageRotation.rotation90deg,
      180 => InputImageRotation.rotation180deg,
      270 => InputImageRotation.rotation270deg,
      _ => InputImageRotation.rotation0deg,
    };

    return InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      ),
    );
  }

  void _announceFace(String name) {
    final now = DateTime.now();
    if (name == _faceNameN.value &&
        now.difference(_lastFaceAnnounce).inSeconds < 8) {
      return;
    }
    _faceNameN.value = name;
    _lastFaceAnnounce = now;

    if (name == 'Unknown person') {
      _tts.speakLocalized('Unknown person ahead.', 'सामने एक अनजान व्यक्ति है।');
    } else {
      _tts.speakLocalized('$name ahead.', 'सामने $name है।');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Mode switching
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _enterWalkMode() async {
    _walkStatusN.value = 'Starting walk mode...';
    setState(() {
      _mode = _NavMode.walkMode;
      _walkActive = true;
    });
    await _initCamera();
    _pathAnalyzer.resetCooldowns();
    await _tts.speakLocalized(
      'Walk mode active. I will guide you through obstacles. '
      'Walk straight ahead. Say stop to pause, or back to return.',
      'वॉक मोड सक्रिय है। मैं आपको बाधाओं से बचाऊंगा। सीधे आगे बढ़ें। रोकने के लिए "स्टॉप" बोलें, या वापस जाने के लिए "बैक" बोलें।',
    );
  }

  Future<void> _enterDestinationMode() async {
    _destStatusN.value = 'Say your destination...';
    _currentInstructionN.value = '';
    setState(() {
      _mode = _NavMode.destinationMode;
    });
    await _initCamera();
    _pathAnalyzer.resetCooldowns();
    await _tts.speakLocalized(
      'Destination mode. Press volume up and say where you want to go.',
      'डेस्टिनेशन मोड। वॉल्यूम अप दबाएं और बताएं कि आप कहाँ जाना चाहते हैं।',
    );
  }

  void _exitToModeSelect() {
    _walkActive = false;
    _navActive = false;
    _isReroutingN.value = false;
    _navSnapshotN.value = null;
    _navService.stopNavigation();
    _stopCamera();
    _detectionsN.value = [];
    _pathAnalysisN.value = null;
    setState(() {
      _mode = _NavMode.modeSelect;
    });
    _tts.speakLocalized(
      'Back to mode selection. Say walk mode or destination mode.',
      'मोड चयन पर वापस। "वॉक मोड" या "डेस्टिनेशन मोड" बोलें।',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Volume button / voice commands
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> onVolumeUp() async {
    switch (_mode) {
      case _NavMode.modeSelect:
        await _tts.speakLocalized(
          'Say walk mode for obstacle detection, '
          'or destination mode to navigate somewhere.',
          'बाधाओं का पता लगाने के लिए "वॉक मोड" बोलें, या कहीं नेविगेट करने के लिए "डेस्टिनेशन मोड" बोलें।',
        );
        break;
      case _NavMode.walkMode:
        // Repeat current guidance
        if (_pathAnalysisN.value != null) {
          _pathAnalyzer.resetCooldowns();
          await _tts.speak(_pathAnalysisN.value!.guidance);
        } else {
          await _tts.speakLocalized('Walk mode active. Point the camera ahead.', 'वॉक मोड सक्रिय है। कैमरा आगे की ओर रखें।');
        }
        break;
      case _NavMode.destinationMode:
        if (_navActive) {
          // Repeat current instruction + remaining info
          if (_currentInstructionN.value.isNotEmpty) {
            await _tts.speak(_currentInstructionN.value);
          }
          final remaining = _navService.getRemainingInfo();
          await _tts.speak(remaining);
          // Also announce obstacles if any
          if (_detectionsN.value.isNotEmpty) {
            final names = _detectionsN.value.take(3).map((d) => d.label).toSet().join(', ');
            await _tts.speakLocalized('Nearby obstacles: $names.', 'आसपास की बाधाएं: $names.');
          }
        } else {
          await _tts.speakLocalized('Say where you want to go.', 'बताएं कि आप कहाँ जाना चाहते हैं।');
        }
        break;
    }
  }

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final c = cmd.toLowerCase();

    // ── Global commands ──────────────────────────────────────────────────
    if (c.contains('walk') || c.contains('chalna') || c.contains('chalein')) {
      if (_mode != _NavMode.walkMode) {
        _enterWalkMode();
        return;
      }
    }
    if (c.contains('destination') ||
        c.contains('navigate to') ||
        c.contains('mujhe jana hai') ||
        c.contains('direction') ||
        c.contains('rasta')) {
      if (_mode != _NavMode.destinationMode) {
        _enterDestinationMode();
        return;
      }
    }
    if (c.contains('back') || c.contains('menu') || c.contains('wapas')) {
      _exitToModeSelect();
      return;
    }

    // ── Mode-specific commands ──────────────────────────────────────────
    switch (_mode) {
      case _NavMode.modeSelect:
        await _tts.speak(hi
            ? 'कृपया "walk mode" या "destination mode" बोलें।'
            : 'Please say walk mode or destination mode.');
        break;

      case _NavMode.walkMode:
        if (c.contains('stop') || c.contains('ruko') || c.contains('band')) {
          setState(() => _walkActive = false);
          await _tts.speak(hi ? 'रुक गया।' : 'Walk mode paused.');
        } else if (c.contains('start') ||
            c.contains('resume') ||
            c.contains('chalu')) {
          setState(() => _walkActive = true);
          _pathAnalyzer.resetCooldowns();
          await _tts.speak(hi ? 'चालू।' : 'Walk mode resumed.');
        } else if (c.contains('what') ||
            c.contains('kya') ||
            c.contains('ahead') ||
            c.contains('samne')) {
          _pathAnalyzer.resetCooldowns();
          if (_detectionsN.value.isEmpty) {
            await _tts
                .speak(hi ? 'कुछ नहीं दिख रहा।' : 'Nothing detected ahead.');
          } else {
            final names =
                _detectionsN.value.take(5).map((d) => '${d.label} ${d.distanceLabel}').toSet().join(', ');
            await _tts.speak(hi ? 'सामने: $names।' : 'Ahead: $names.');
          }
        } else if (c.contains('how far') || c.contains('distance') || c.contains('kitna door')) {
          if (_pathAnalysisN.value?.closestDistanceLabel != null) {
            await _tts.speak(hi
                ? 'सबसे करीब ${_pathAnalysisN.value!.closestDistanceLabel}।'
                : 'Closest obstacle at ${_pathAnalysisN.value!.closestDistanceLabel}.');
          } else {
            await _tts.speak(hi ? 'कोई बाधा नहीं।' : 'No obstacles detected.');
          }
        } else if (c.contains('who') || c.contains('kaun')) {
          if (_faceNameN.value.isNotEmpty) {
            await _tts.speak(hi
                ? 'यह ${_faceNameN.value} है।'
                : 'That is ${_faceNameN.value}.');
          } else {
            await _tts.speak(
                hi ? 'कोई चेहरा नहीं मिला।' : 'No person identified.');
          }
        } else {
          await _tts.speak(hi
              ? 'बोलें: "stop", "what is ahead", "how far", या "back"।'
              : 'Say stop, what is ahead, how far, who is that, or back.');
        }
        break;

      case _NavMode.destinationMode:
        if (c.contains('stop') ||
            c.contains('cancel') ||
            c.contains('ruko') ||
            c.contains('band')) {
          _navService.stopNavigation();
          _navSnapshotN.value = null;
          _destStatusN.value = 'Navigation cancelled.';
          _currentInstructionN.value = '';
          setState(() {
            _navActive = false;
            _walkActive = false;
          });
          await _tts
              .speak(hi ? 'नेविगेशन रद्द।' : 'Navigation cancelled.');
        } else if (c.contains('how far') ||
            c.contains('kitna door') ||
            c.contains('remaining') ||
            c.contains('eta') ||
            c.contains('time')) {
          await _tts.speak(_navService.getRemainingInfo());
        } else if (c.contains('repeat') ||
            c.contains('again') ||
            c.contains('dobara')) {
          if (_currentInstructionN.value.isNotEmpty) {
            await _tts.speak(_currentInstructionN.value);
          }
        } else if (c.contains('what') ||
            c.contains('ahead') ||
            c.contains('obstacle') ||
            c.contains('samne')) {
          // Report obstacles while navigating
          if (_detectionsN.value.isEmpty) {
            await _tts.speak(hi ? 'रास्ता साफ है।' : 'Path is clear.');
          } else {
            final names = _detectionsN.value.take(5).map((d) => '${d.label} ${d.distanceLabel}').toSet().join(', ');
            await _tts.speak(hi ? 'सामने: $names।' : 'Ahead: $names.');
          }
        } else if (!_navActive) {
          // Treat the entire command as a destination name
          await _startDestinationNavigation(cmd);
        } else {
          await _tts.speak(hi
              ? 'बोलें: "stop", "how far", "what is ahead", या "repeat"।'
              : 'Say stop, how far, what is ahead, or repeat instruction.');
        }
        break;
    }
  }

  Future<void> _startDestinationNavigation(String command) async {
    // Clean up destination by removing common STT conversational prefixes
    String destination = command.toLowerCase()
        .replaceAll(RegExp(r'^(take me to|navigate to|go to|directions to|i want to go to|mujhe jana hai|rasta batao)\s+', caseSensitive: false), '')
        .trim();

    _destStatusN.value = 'Finding route to: $destination...';
    _navSnapshotN.value = null;
    await _tts.speakLocalized('Finding route to $destination. Please wait.', '$destination के लिए रास्ता खोज रहे हैं। कृपया प्रतीक्षा करें।');

    final route = await _navService.getDirections(destination);
    if (!mounted) return;

    if (route == null) {
      if (_navService.lastPosition == null) {
        _destStatusN.value = 'Could not get location.';
        await _tts.speakLocalized('Sorry, I could not get your current location. Make sure location services are enabled.', 'क्षमा करें, मैं आपकी वर्तमान लोकेशन नहीं पा सका। सुनिश्चित करें कि लोकेशन सेवा चालू है।');
      } else {
        _destStatusN.value = 'Could not find route. Try again.';
        await _tts.speakLocalized(
          'Sorry, I could not find a walking route to $destination. '
          'Press volume up and say the destination again.',
          'क्षमा करें, मुझे $destination तक पैदल जाने का कोई रास्ता नहीं मिला। वॉल्यूम अप दबाएं और गंतव्य का नाम दोबारा बोलें।',
        );
      }
      return;
    }

    _destStatusN.value =
        '${route.totalDistance} · ETA ${route.totalDuration}';
    setState(() {
      _navActive = true;
    });

    await _tts.speakLocalized(
      'Route found to ${route.destinationAddress}. '
      '${route.totalDistance}, estimated ${route.totalDuration}. '
      '${route.steps.length} steps. '
      'Starting navigation. I will also watch for obstacles.',
      '${route.destinationAddress} के लिए रास्ता मिल गया है। कुल दूरी ${route.totalDistance}, अनुमानित समय ${route.totalDuration}। नेविगेशन शुरू हो रहा है, मैं बाधाओं पर भी नज़र रखूँगा।',
    );

    _walkActive = true; // Enable obstacle detection during navigation
    _pathAnalyzer.resetCooldowns();
    _navService.startNavigation();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kSurface,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    final String title;
    final String subtitle;
    switch (_mode) {
      case _NavMode.modeSelect:
        title = 'Navigate';
        subtitle = isMixinListening ? '🎤 Listening…' : 'Select a mode';
        break;
      case _NavMode.walkMode:
        title = 'Walk Mode';
        subtitle = isMixinListening
            ? '🎤 Listening…'
            : _walkActive
                ? '🟢 Active'
                : '⏸ Paused';
        break;
      case _NavMode.destinationMode:
        title = 'Destination Mode';
        subtitle = isMixinListening
            ? '🎤 Listening…'
            : _navActive
                ? '🧭 Navigating'
                : 'Say destination';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kSurface,
        border: Border(
          bottom: BorderSide(color: _kIndigo.withOpacity(0.3)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              if (_mode == _NavMode.modeSelect) {
                _tts.speakLocalized('Going back', 'वापस जा रहे हैं');
                Navigator.pop(context);
              } else {
                _exitToModeSelect();
              }
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    )),
                Text(subtitle,
                    style: GoogleFonts.inter(
                      color: _kIndigoLight,
                      fontSize: 11,
                    )),
              ],
            ),
          ),
          if (_mode != _NavMode.modeSelect)
            IconButton(
              icon: const Icon(Icons.home_outlined, color: Colors.white70),
              tooltip: 'Mode Select',
              onPressed: _exitToModeSelect,
            ),
          GestureDetector(
            onTap: () {
              final user = FirebaseAuth.instance.currentUser;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => user == null
                      ? const RegistrationScreen()
                      : const ProfileScreen(),
                ),
              );
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _kSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kCardBorder),
              ),
              child: const Icon(Icons.person_outline_rounded,
                  color: Colors.white70, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ── Content ───────────────────────────────────────────────────────────────

  Widget _buildContent() {
    if (!_initialized) {
      return _buildLoadingView();
    }
    switch (_mode) {
      case _NavMode.modeSelect:
        return _buildModeSelectView();
      case _NavMode.walkMode:
        return _buildWalkModeView();
      case _NavMode.destinationMode:
        return _buildDestinationModeView();
    }
  }

  // ── Loading view ──────────────────────────────────────────────────────────

  Widget _buildLoadingView() {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: _kIndigo,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _initError.isNotEmpty
                  ? 'Initialization failed'
                  : 'Loading AI models...',
              style: GoogleFonts.inter(
                color: Colors.white70,
                fontSize: 15,
              ),
            ),
            if (_initError.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _initError,
                  style: GoogleFonts.inter(
                    color: _kRed,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Mode select view ──────────────────────────────────────────────────────

  Widget _buildModeSelectView() {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            // Walk Mode card
            Expanded(
              child: _buildModeCard(
                icon: Icons.directions_walk_rounded,
                title: 'Walk Mode',
                titleHi: 'वॉक मोड',
                description:
                    'Obstacle detection with directional guidance.',
                color: _kGreen,
                gradientColors: const [Color(0xFF00E676), Color(0xFF00B248)],
                onTap: _enterWalkMode,
              ),
            ),
            const SizedBox(height: 16),
            // Destination Mode card
            Expanded(
              child: _buildModeCard(
                icon: Icons.navigation_rounded,
                title: 'Destination Mode',
                titleHi: 'मंज़िल मोड',
                description:
                    'Voice-activated turn-by-turn navigation. '
                    'Say where you want to go and I\'ll guide you there safely.',
                color: _kIndigo,
                gradientColors: const [Color(0xFF2980BA), Color(0xFF1A5276)],
                onTap: _enterDestinationMode,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _kSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kCardBorder),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.volume_up_rounded,
                      color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Press Volume Up and say a mode name',
                    style: GoogleFonts.inter(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeCard({
    required IconData icon,
    required String title,
    required String titleHi,
    required String description,
    required Color color,
    required List<Color> gradientColors,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              gradientColors[0].withOpacity(0.15),
              gradientColors[1].withOpacity(0.08),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: gradientColors),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(0.4),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 36),
              ),
              const SizedBox(height: 16),
              Text(title,
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  )),
              Text(titleHi,
                  style: GoogleFonts.inter(
                    color: color.withOpacity(0.7),
                    fontSize: 13,
                  )),
              const SizedBox(height: 10),
              Text(description,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: Colors.white60,
                    fontSize: 13,
                    height: 1.4,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Walk Mode View
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildWalkModeView() {
    return Column(
      children: [
        // Camera + detection overlay + path boundary lines
        Expanded(flex: 5, child: _buildCameraPreview()),
        // Zone indicator
        _buildZoneIndicator(),
        // Status / guidance with distance info
        _buildGuidancePanel(),
        // Detected objects chips with distance
        _buildDetectionChips(),
        // Controls
        _buildWalkControls(),
      ],
    );
  }

  Widget _buildCameraPreview() {
    if (!_camReady || _cam == null) {
      return Container(
        color: _kSurface,
        child: const Center(
          child: CircularProgressIndicator(color: _kIndigo),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        CameraPreview(_cam!),

        // Path boundary lines + bounding boxes + distance labels overlay
        Positioned.fill(
          child: ListenableBuilder(
            listenable: Listenable.merge([_detectionsN, _faceNameN, _pathAnalysisN]),
            builder: (context, _) {
              return CustomPaint(
                painter: _NavOverlayPainter(
                  objects: _detectionsN.value,
                  faceName: _faceNameN.value,
                  pathBoundary: _pathAnalysisN.value?.pathBoundary,
                  urgency: _pathAnalysisN.value?.urgency ?? VoiceUrgency.low,
                ),
              );
            },
          ),
        ),

        // Walk active indicator
        if (_walkActive)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _kGreen.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kGreen.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: _kGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('LIVE',
                      style: GoogleFonts.inter(
                        color: _kGreen,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      )),
                ],
              ),
            ),
          ),

        // Closest distance badge
        ValueListenableBuilder<PathAnalysis?>(
          valueListenable: _pathAnalysisN,
          builder: (context, analysis, _) {
            if (analysis?.closestDistanceLabel == null) return const SizedBox.shrink();
            return Positioned(
              top: 8,
              left: 60,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _kSurface.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _urgencyColor(analysis!.urgency).withOpacity(0.6),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.straighten,
                        color: _urgencyColor(analysis.urgency),
                        size: 12),
                    const SizedBox(width: 4),
                    Text(
                      analysis.closestDistanceLabel!,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        // Listening indicator
        if (isMixinListening)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _kSurface.withOpacity(0.8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mic, color: _kIndigo, size: 14),
                  const SizedBox(width: 4),
                  Text('Listening…',
                      style: GoogleFonts.inter(
                          color: Colors.white, fontSize: 11)),
                ],
              ),
            ),
          ),

        // ── Safe direction arrow overlay ──────────────────────────────────
        Positioned.fill(
          child: ValueListenableBuilder<double>(
            valueListenable: _safeDirectionAngleN,
            builder: (context, angle, _) {
              return CustomPaint(
                painter: _SafeDirectionArrowPainter(
                  angleRadians: angle,
                  urgency: _pathAnalysisN.value?.urgency ?? VoiceUrgency.low,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Color _urgencyColor(VoiceUrgency urgency) {
    switch (urgency) {
      case VoiceUrgency.critical:
        return _kRed;
      case VoiceUrgency.high:
        return _kOrange;
      case VoiceUrgency.medium:
        return _kYellow;
      case VoiceUrgency.low:
        return _kGreen;
    }
  }

  Widget _buildZoneIndicator() {
    return ValueListenableBuilder<PathAnalysis?>(
      valueListenable: _pathAnalysisN,
      builder: (context, analysis, _) {
        final left = analysis?.leftBlocked ?? false;
        final center = analysis?.centerBlocked ?? false;
        final right = analysis?.rightBlocked ?? false;

        return SizedBox(
          height: 8,
          child: Row(
            children: [
              Expanded(
                child: Container(color: left ? _kRed : _kGreen),
              ),
              Container(width: 2, color: Colors.black),
              Expanded(
                child: Container(color: center ? _kRed : _kGreen),
              ),
              Container(width: 2, color: Colors.black),
              Expanded(
                child: Container(color: right ? _kRed : _kGreen),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGuidancePanel() {
    return ListenableBuilder(
      listenable: Listenable.merge([_pathAnalysisN, _walkStatusN, _detectionsN]),
      builder: (context, _) {
        final analysis = _pathAnalysisN.value;
        final status = _walkStatusN.value;
        final detections = _detectionsN.value;
        
        final Color guidanceColor;
        final IconData guidanceIcon;

        if (analysis == null || analysis.alertPriority == 0) {
          guidanceColor = _kGreen;
          guidanceIcon = Icons.check_circle_outline;
        } else if (analysis.alertPriority == 1) {
          guidanceColor = _kRed;
          guidanceIcon = Icons.warning_amber_rounded;
        } else if (analysis.alertPriority == 2) {
          guidanceColor = _kYellow;
          guidanceIcon = Icons.info_outline;
        } else {
          guidanceColor = _kIndigoLight;
          guidanceIcon = Icons.explore_outlined;
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: guidanceColor.withOpacity(0.1),
            border: Border(
              top: BorderSide(color: guidanceColor.withOpacity(0.3)),
              bottom: BorderSide(color: guidanceColor.withOpacity(0.3)),
            ),
          ),
          child: Row(
            children: [
              Icon(guidanceIcon, color: guidanceColor, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (analysis?.closestDistanceLabel != null)
                      Text(
                        'Nearest: ${analysis!.closestDistanceLabel}',
                        style: GoogleFonts.inter(
                          color: guidanceColor.withOpacity(0.8),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (detections.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: guidanceColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${detections.length}',
                    style: GoogleFonts.inter(
                      color: guidanceColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetectionChips() {
    return ValueListenableBuilder<List<NavDetectedObject>>(
      valueListenable: _detectionsN,
      builder: (context, detections, _) {
        if (detections.isEmpty) return const SizedBox.shrink();
        
        return Container(
          height: 44,
          color: _kSurface,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: detections.length.clamp(0, 8),
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final det = detections[i];
              final Color chipColor;
              switch (det.dangerLevel) {
                case DangerLevel.critical:
                  chipColor = _kRed;
                  break;
                case DangerLevel.warning:
                  chipColor = _kYellow;
                  break;
                case DangerLevel.info:
                  chipColor = _kIndigoLight;
                  break;
              }
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: chipColor.withOpacity(0.4)),
                ),
                child: Center(
                  child: Text(
                    '${det.label} ${det.distanceLabel}',
                    style: GoogleFonts.inter(
                      color: chipColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildWalkControls() {
    return Container(
      color: _kSurface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: () {
                setState(() => _walkActive = !_walkActive);
                if (_walkActive) {
                  _pathAnalyzer.resetCooldowns();
                  _tts.speakLocalized('Walk mode resumed.', 'वॉक मोड चालू।');
                } else {
                  _tts.speakLocalized('Walk mode paused.', 'वॉक मोड रुका।');
                }
              },
              icon: Icon(
                _walkActive
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                size: 24,
              ),
              label: Text(
                _walkActive ? 'Pause' : 'Resume',
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _walkActive ? Colors.orange : _kGreen,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () {
                _pathAnalyzer.resetCooldowns();
                if (_pathAnalysisN.value != null) {
                  _tts.speak(_pathAnalysisN.value!.guidance);
                }
              },
              icon: const Icon(Icons.replay, size: 20),
              label: Text('Repeat',
                  style: GoogleFonts.inter(fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kCard,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Destination Mode View
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDestinationModeView() {
    return Column(
      children: [
        // Camera + safety overlay (same as walk mode)
        Expanded(flex: 4, child: _buildCameraPreview()),
        // Zone indicator with approach highlight
        if (_navActive) _buildDestZoneIndicator(),
        // Navigation instruction panel
        _buildNavigationPanel(),
        // ETA / Distance / Progress bar
        if (_navActive) _buildNavProgressBar(),
        // Destination status
        _buildDestStatusBar(),
        // Detected objects chips with distance (when navigating)
        if (_navActive && _detectionsN.value.isNotEmpty) _buildDetectionChips(),
        // Controls
        _buildDestControls(),
      ],
    );
  }

  Widget _buildDestZoneIndicator() {
    return ListenableBuilder(
      listenable: Listenable.merge([_pathAnalysisN, _isApproachingTurnN]),
      builder: (context, _) {
        final analysis = _pathAnalysisN.value;
        final approaching = _isApproachingTurnN.value;

        final left = analysis?.leftBlocked ?? false;
        final center = analysis?.centerBlocked ?? false;
        final right = analysis?.rightBlocked ?? false;

        return SizedBox(
          height: 8,
          child: Row(
            children: [
              Expanded(
                child: Container(color: left ? _kRed : _kGreen),
              ),
              Container(width: 2, color: Colors.black),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: center ? _kRed : _kGreen,
                    border: approaching
                        ? Border.all(color: _kOrange, width: 2)
                        : null,
                  ),
                ),
              ),
              Container(width: 2, color: Colors.black),
              Expanded(
                child: Container(color: right ? _kRed : _kGreen),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNavigationPanel() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _currentInstructionN,
        _isReroutingN,
        _navSnapshotN,
        _isApproachingTurnN
      ]),
      builder: (context, _) {
        final currentInstruction = _currentInstructionN.value;
        final isRerouting = _isReroutingN.value;
        final navSnapshot = _navSnapshotN.value;
        final approaching = _isApproachingTurnN.value;

        if (!_navActive || currentInstruction.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
              color: _kIndigo.withOpacity(0.1),
              border: Border(
                top: BorderSide(color: _kIndigo.withOpacity(0.3)),
              ),
            ),
            child: Column(
              children: [
                Icon(Icons.navigation_rounded,
                    color: _kIndigo.withOpacity(0.5), size: 36),
                const SizedBox(height: 8),
                Text(
                  'Press Volume Up and say your destination',
                  style: GoogleFonts.inter(
                    color: Colors.white60,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        IconData maneuverIcon = Icons.navigation_rounded;
        Color panelAccent = _kIndigo;
        if (isRerouting) {
          maneuverIcon = Icons.refresh_rounded;
          panelAccent = _kOrange;
        } else if (_navService.nextStep?.maneuver != null) {
          final m = _navService.nextStep!.maneuver!;
          if (m.contains('left')) {
            maneuverIcon = Icons.turn_left_rounded;
          } else if (m.contains('right')) {
            maneuverIcon = Icons.turn_right_rounded;
          } else if (m.contains('uturn')) {
            maneuverIcon = Icons.u_turn_left_rounded;
          } else if (m.contains('straight')) {
            maneuverIcon = Icons.straight_rounded;
          } else if (m.contains('roundabout')) {
            maneuverIcon = Icons.roundabout_left_rounded;
          }
        }

        if (approaching) {
          panelAccent = _kOrange;
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: panelAccent.withOpacity(0.12),
            border: Border(
              top: BorderSide(color: panelAccent.withOpacity(0.4)),
              bottom: BorderSide(color: panelAccent.withOpacity(0.4)),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: panelAccent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(maneuverIcon, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRerouting ? 'Recalculating route...' : currentInstruction,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          _navService.progressText,
                          style: GoogleFonts.inter(
                            color: _kIndigoLight,
                            fontSize: 11,
                          ),
                        ),
                        if (navSnapshot != null) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.straighten, color: _kIndigoLight, size: 11),
                          const SizedBox(width: 3),
                          Text(
                            _navService.remainingDistanceText,
                            style: GoogleFonts.inter(
                              color: _kIndigoLight,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (navSnapshot != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _kGreen.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _kGreen.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        navSnapshot.eta,
                        style: GoogleFonts.inter(
                          color: _kGreen,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'ETA',
                        style: GoogleFonts.inter(
                          color: _kGreen.withOpacity(0.7),
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNavProgressBar() {
    return ListenableBuilder(
      listenable: Listenable.merge([_navSnapshotN, _isApproachingTurnN]),
      builder: (context, _) {
        final snapshot = _navSnapshotN.value;
        final approaching = _isApproachingTurnN.value;

        if (snapshot == null) return const SizedBox.shrink();

        final totalSteps = snapshot.totalSteps;
        final currentIdx = snapshot.currentStepIndex;
        final progress = totalSteps > 0 ? (currentIdx / totalSteps) : 0.0;

        final nextTurnDist = snapshot.distanceToNextTurn;
        final nextTurnSteps = (nextTurnDist / 0.6).round();
        String nextTurnText;
        if (nextTurnSteps < 3) {
          nextTurnText = 'Now';
        } else if (nextTurnSteps < 150) {
          nextTurnText = '$nextTurnSteps steps';
        } else {
          nextTurnText = '${(nextTurnSteps / 100).round() * 100} steps';
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          color: _kCard,
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: _kCardBorder,
                  valueColor: AlwaysStoppedAnimation(
                    approaching ? _kOrange : _kIndigo,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        approaching
                            ? Icons.warning_amber_rounded
                            : Icons.swap_calls_rounded,
                        color: approaching ? _kOrange : Colors.white54,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Next turn: $nextTurnText',
                        style: GoogleFonts.inter(
                          color: approaching ? _kOrange : Colors.white54,
                          fontSize: 11,
                          fontWeight: approaching
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${currentIdx + 1} / $totalSteps',
                    style: GoogleFonts.inter(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.flag_outlined,
                          color: Colors.white54, size: 13),
                      const SizedBox(width: 3),
                      Text(
                        _navService.remainingDistanceText,
                        style: GoogleFonts.inter(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDestStatusBar() {
    return ListenableBuilder(
      listenable: Listenable.merge([_isReroutingN, _destStatusN]),
      builder: (context, _) {
        final isRerouting = _isReroutingN.value;
        final status = _destStatusN.value;

        return Container(
          width: double.infinity,
          color: _kSurface,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
          child: Row(
            children: [
              if (isRerouting)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _kOrange,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  status,
                  style: GoogleFonts.inter(
                    color: isRerouting
                        ? _kOrange
                        : _navActive
                            ? _kGreen
                            : Colors.white60,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_navActive && _navService.currentRoute != null)
                Text(
                  _navService.currentRoute!.destinationAddress.length > 25
                      ? '${_navService.currentRoute!.destinationAddress.substring(0, 25)}…'
                      : _navService.currentRoute!.destinationAddress,
                  style: GoogleFonts.inter(
                    color: Colors.white30,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDestControls() {
    return Container(
      color: _kSurface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          if (_navActive) ...[
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: () {
                  _navService.stopNavigation();
                  setState(() {
                    _navActive = false;
                    _walkActive = false;
                    _navSnapshotN.value = null;
                    _destStatusN.value = 'Navigation stopped.';
                    _currentInstructionN.value = '';
                  });
                  _tts.speakLocalized('Navigation stopped.', 'नेविगेशन रुक गया।');
                },
                icon: const Icon(Icons.stop_circle_outlined, size: 24),
                label: Text('Stop',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kRed,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  if (_currentInstructionN.value.isNotEmpty) {
                    _tts.speak(_currentInstructionN.value);
                  }
                },
                icon: const Icon(Icons.replay, size: 18),
                label: Text('Repeat',
                    style: GoogleFonts.inter(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kCard,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // ETA / info button
            SizedBox(
              width: 48,
              height: 48,
              child: ElevatedButton(
                onPressed: () {
                  _tts.speak(_navService.getRemainingInfo());
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kCard,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Icon(Icons.schedule_rounded, size: 22),
              ),
            ),
          ] else ...[
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _exitToModeSelect,
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
                label: Text('Change Mode',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kCard,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Enhanced Overlay Painter — Bounding Boxes + Path Boundary Lines + Distance
// ═════════════════════════════════════════════════════════════════════════════

class _NavOverlayPainter extends CustomPainter {
  final List<NavDetectedObject> objects;
  final String? faceName;
  final PathBoundary? pathBoundary;
  final VoiceUrgency urgency;

  const _NavOverlayPainter({
    required this.objects,
    this.faceName,
    this.pathBoundary,
    required this.urgency,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── 1. Draw path boundary lines ─────────────────────────────────────────
    _drawPathBoundaryLines(canvas, size);

    // ── 2. Draw zone dividers (faint) ───────────────────────────────────────
    _drawZoneDividers(canvas, size);

    // ── 3. Draw bounding boxes with distance labels ─────────────────────────
    for (int i = 0; i < objects.length; i++) {
      final obj = objects[i];

      // Colour by danger level
      final Color color;
      switch (obj.dangerLevel) {
        case DangerLevel.critical:
          color = _kRed;
          break;
        case DangerLevel.warning:
          color = _kYellow;
          break;
        case DangerLevel.info:
          color = _kIndigoLight;
          break;
      }

      final rect = Rect.fromLTRB(
        obj.boundingBox.left * size.width,
        obj.boundingBox.top * size.height,
        obj.boundingBox.right * size.width,
        obj.boundingBox.bottom * size.height,
      );

      // Draw semi-transparent fill for close objects
      if (obj.proximityZone == ProximityZone.veryClose ||
          obj.proximityZone == ProximityZone.close) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = color.withOpacity(0.08)
            ..style = PaintingStyle.fill,
        );
      }

      // Draw box
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = obj.proximityZone == ProximityZone.veryClose ? 3.5 : 2.5,
      );

      // Draw corners
      _drawCorners(canvas, rect, color);

      // Label with distance
      String label = obj.label;
      if (obj.label == 'person' && faceName != null && faceName!.isNotEmpty) {
        label = faceName!;
      }
      label = '  $label ${obj.distanceLabel} (${(obj.confidence * 100).toStringAsFixed(0)}%)  ';

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.black,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            background: Paint()..color = color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(
        canvas,
        Offset(
          rect.left,
          rect.top > tp.height + 4 ? rect.top - tp.height - 4 : rect.top + 4,
        ),
      );

      // Draw distance indicator bar at bottom of bbox
      _drawDistanceBar(canvas, rect, obj, color);
    }
  }

  void _drawPathBoundaryLines(Canvas canvas, Size size) {
    if (pathBoundary == null) return;

    final leftX = pathBoundary!.leftLineX * size.width;
    final rightX = pathBoundary!.rightLineX * size.width;

    // Determine colour based on corridor width
    final corridorFraction = pathBoundary!.corridorWidth;
    final Color lineColor;
    if (corridorFraction > 0.40) {
      lineColor = _kCyan; // Wide safe corridor
    } else if (corridorFraction > 0.20) {
      lineColor = _kYellow; // Narrowing
    } else {
      lineColor = _kRed; // Very narrow / blocked
    }

    // Left boundary line
    final leftPaint = Paint()
      ..color = lineColor.withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    // Draw dashed lines for path boundaries
    _drawDashedLine(
      canvas,
      Offset(leftX, size.height * 0.15),
      Offset(leftX, size.height * 0.95),
      leftPaint,
    );

    // Right boundary line
    _drawDashedLine(
      canvas,
      Offset(rightX, size.height * 0.15),
      Offset(rightX, size.height * 0.95),
      leftPaint,
    );

    // Draw semi-transparent corridor fill
    canvas.drawRect(
      Rect.fromLTRB(leftX, size.height * 0.15, rightX, size.height * 0.95),
      Paint()
        ..color = lineColor.withOpacity(0.04)
        ..style = PaintingStyle.fill,
    );

    // Draw "SAFE PATH" label at top of corridor
    if (corridorFraction > 0.15) {
      final safePaint = TextPainter(
        text: TextSpan(
          text: ' SAFE PATH ',
          style: TextStyle(
            color: lineColor,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            background: Paint()..color = const Color(0xFF263238).withOpacity(0.5),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      safePaint.paint(
        canvas,
        Offset(
          (leftX + rightX) / 2 - safePaint.width / 2,
          size.height * 0.12,
        ),
      );
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashLength = 10.0;
    const gapLength = 6.0;
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final totalLength = (dx * dx + dy * dy);
    if (totalLength == 0) return;
    final sqrtLen = _sqrt(totalLength);
    final unitDx = dx / sqrtLen;
    final unitDy = dy / sqrtLen;

    double drawn = 0.0;
    bool isDash = true;
    while (drawn < sqrtLen) {
      final segLength = isDash
          ? dashLength.clamp(0, sqrtLen - drawn)
          : gapLength.clamp(0, sqrtLen - drawn);
      if (isDash) {
        canvas.drawLine(
          Offset(p1.dx + unitDx * drawn, p1.dy + unitDy * drawn),
          Offset(
            p1.dx + unitDx * (drawn + segLength),
            p1.dy + unitDy * (drawn + segLength),
          ),
          paint,
        );
      }
      drawn += segLength;
      isDash = !isDash;
    }
  }

  double _sqrt(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }

  void _drawZoneDividers(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Left/centre boundary (33%)
    canvas.drawLine(
      Offset(size.width * 0.33, 0),
      Offset(size.width * 0.33, size.height),
      paint,
    );
    // Centre/right boundary (66%)
    canvas.drawLine(
      Offset(size.width * 0.66, 0),
      Offset(size.width * 0.66, size.height),
      paint,
    );
  }

  void _drawDistanceBar(
      Canvas canvas, Rect rect, NavDetectedObject obj, Color color) {
    // Small coloured bar at bottom of bbox showing proximity
    final barHeight = 3.0;
    final barWidth = rect.width;

    // Fill fraction based on proximity (closer = more filled)
    double fillFraction;
    switch (obj.proximityZone) {
      case ProximityZone.veryClose:
        fillFraction = 1.0;
        break;
      case ProximityZone.close:
        fillFraction = 0.7;
        break;
      case ProximityZone.near:
        fillFraction = 0.4;
        break;
      case ProximityZone.far:
        fillFraction = 0.15;
        break;
    }

    // Background
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.bottom + 2, barWidth, barHeight),
      Paint()
        ..color = Colors.white.withOpacity(0.15)
        ..style = PaintingStyle.fill,
    );
    // Fill
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.bottom + 2, barWidth * fillFraction, barHeight),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  void _drawCorners(Canvas canvas, Rect r, Color c) {
    final p = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;
    const l = 16.0;
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(l, 0), p);
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(0, l), p);
    canvas.drawLine(r.topRight, r.topRight + const Offset(-l, 0), p);
    canvas.drawLine(r.topRight, r.topRight + const Offset(0, l), p);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(l, 0), p);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(0, -l), p);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(-l, 0), p);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(0, -l), p);
  }

  @override
  bool shouldRepaint(_NavOverlayPainter old) =>
      old.objects != objects ||
      old.faceName != faceName ||
      old.pathBoundary != pathBoundary ||
      old.urgency != urgency;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Safe Direction Arrow Painter
//  — Fixed base at bottom-centre, tip rotates toward safest walking direction
// ═══════════════════════════════════════════════════════════════════════════════

class _SafeDirectionArrowPainter extends CustomPainter {
  /// Angle in radians: 0 = 12 o’clock (up), π/2 = 3 o’clock (right), etc.
  final double angleRadians;

  /// Current urgency level — drives the arrow colour.
  final VoiceUrgency urgency;

  const _SafeDirectionArrowPainter({
    required this.angleRadians,
    required this.urgency,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Layout constants ─────────────────────────────────────────────────────
    final baseX = size.width / 2;
    final baseY = size.height - 40; // fixed at bottom-centre
    final arrowLength = size.height * 0.22; // shaft length
    final arrowHeadSize = 14.0;
    final baseRadius = 16.0;

    // ── Compute tip position ─────────────────────────────────────────────────
    // angleRadians: 0 = up, π/2 = right, π = down, 3π/2 = left
    // Convert to canvas coords: dx = sin(angle), dy = -cos(angle)
    final tipX = baseX + arrowLength * sin(angleRadians);
    final tipY = baseY - arrowLength * cos(angleRadians);

    // ── Choose colour based on urgency ───────────────────────────────────────
    final Color arrowColor;
    switch (urgency) {
      case VoiceUrgency.critical:
        arrowColor = _kRed;
        break;
      case VoiceUrgency.high:
        arrowColor = _kOrange;
        break;
      case VoiceUrgency.medium:
        arrowColor = _kYellow;
        break;
      case VoiceUrgency.low:
        arrowColor = _kCyan;
        break;
    }

    // ── 1. Draw outer glow ring at base ─────────────────────────────────────
    canvas.drawCircle(
      Offset(baseX, baseY),
      baseRadius + 6,
      Paint()
        ..color = arrowColor.withOpacity(0.15)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── 2. Draw base circle (compass dot) ──────────────────────────────────
    canvas.drawCircle(
      Offset(baseX, baseY),
      baseRadius,
      Paint()
        ..color = const Color(0xFF1A2530).withOpacity(0.85)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(baseX, baseY),
      baseRadius,
      Paint()
        ..color = arrowColor.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // ── 3. Draw arrow shaft with glow ───────────────────────────────────────
    // Glow
    canvas.drawLine(
      Offset(baseX, baseY),
      Offset(tipX, tipY),
      Paint()
        ..color = arrowColor.withOpacity(0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Main shaft
    canvas.drawLine(
      Offset(baseX, baseY),
      Offset(tipX, tipY),
      Paint()
        ..color = arrowColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );

    // ── 4. Draw arrowhead (triangle) ────────────────────────────────────────
    final headAngle = 0.45; // half-angle of arrowhead
    final headLen = arrowHeadSize;

    final leftWingX = tipX - headLen * sin(angleRadians - headAngle);
    final leftWingY = tipY + headLen * cos(angleRadians - headAngle);
    final rightWingX = tipX - headLen * sin(angleRadians + headAngle);
    final rightWingY = tipY + headLen * cos(angleRadians + headAngle);

    final headPath = Path()
      ..moveTo(tipX, tipY)
      ..lineTo(leftWingX, leftWingY)
      ..lineTo(rightWingX, rightWingY)
      ..close();

    // Glow
    canvas.drawPath(
      headPath,
      Paint()
        ..color = arrowColor.withOpacity(0.3)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Solid
    canvas.drawPath(
      headPath,
      Paint()
        ..color = arrowColor
        ..style = PaintingStyle.fill,
    );

    // ── 5. Draw inner dot at base ───────────────────────────────────────────
    canvas.drawCircle(
      Offset(baseX, baseY),
      5,
      Paint()
        ..color = arrowColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_SafeDirectionArrowPainter old) =>
      old.angleRadians != angleRadians || old.urgency != urgency;
}