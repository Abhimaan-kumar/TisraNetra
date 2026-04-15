// lib/screens/navigate_screen.dart
//
// Smart Navigation Screen with two modes:
//   ┌─────────────────────────────────────────────────┐
//   │ Walk Mode     — Real-time obstacle detection +  │
//   │                 directional guidance +           │
//   │                 face recognition                 │
//   │ Destination   — Voice-activated turn-by-turn    │
//   │   Mode          navigation with safety overlay  │
//   └─────────────────────────────────────────────────┘
//
// Voice-first: all interactions via volume buttons + STT/TTS.
// Bilingual: English + Hindi.

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../services/nav_object_detection_service.dart';
import '../services/path_analyzer_service.dart';
import '../services/navigation_service.dart';
import '../services/face_embedding_service.dart';
import '../services/face_db_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';
import '../theme/app_theme.dart';
import 'registration.dart';
import 'profile_screen.dart';

// ─── Constants ───────────────────────────────────────────────────────────────

const _kProcessEveryN = 3;
const _kFaceThreshold = 0.6;

// Colours
const _kIndigo = Color(0xFF3F51B5);
const _kIndigoLight = Color(0xFF7986CB);
const _kGreen = Color(0xFF00E676);
const _kYellow = Color(0xFFFFD600);
const _kRed = Color(0xFFFF3D71);
const _kSurface = Color(0xFF141929);
const _kCard = Color(0xFF1C2137);
const _kCardBorder = Color(0xFF2A3050);

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
  late FaceDetector _faceDetector;

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _camReady = false;
  int _sensorOrientation = 0;
  int _frameCount = 0;
  bool _isProcessing = false;

  // ── Mode state ────────────────────────────────────────────────────────────
  _NavMode _mode = _NavMode.modeSelect;

  // ── Walk mode state ───────────────────────────────────────────────────────
  List<NavDetectedObject> _detections = [];
  PathAnalysis? _pathAnalysis;
  String _walkStatus = 'Initializing...';
  bool _walkActive = false;

  // ── Face recognition state ────────────────────────────────────────────────
  List<PersonRecord> _persons = [];
  String _lastFaceName = '';
  DateTime _lastFaceAnnounce = DateTime(2000);

  // ── Destination mode state ────────────────────────────────────────────────
  String _destStatus = 'Say your destination';
  String _currentInstruction = '';
  bool _navActive = false;

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
    _navService.dispose();
    _tts.dispose();
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
        setState(() => _currentInstruction = en);
        _tts.speak(en);
      };
      _navService.onArrived = () {
        if (!mounted) return;
        setState(() {
          _destStatus = 'You have arrived!';
          _navActive = false;
        });
        _tts.speak('You have arrived at your destination.');
      };
      _navService.onStateChange = (state) {
        if (!mounted) return;
        setState(() {
          if (state == NavigationState.error) {
            _destStatus = 'Navigation error. Try again.';
          }
        });
      };

      if (!mounted) return;
      setState(() {
        _initialized = true;
      });

      await _tts.speak(
        'Navigation ready. Say walk mode for obstacle detection, '
        'or destination mode to navigate somewhere. '
        'Press volume up to speak.',
      );
    } catch (e) {
      debugPrint('[Navigate] Init error: $e');
      if (mounted) {
        setState(() {
          _initError = e.toString();
        });
      }
      _tts.speak('Failed to initialize navigation. Please restart.');
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
      // 1. Object detection
      final detections =
          _detectionService.detect(image, _sensorOrientation);

      // 2. Path analysis
      final analysis = _pathAnalyzer.analyze(detections);

      // 3. Face recognition (if person detected)
      String? faceName;
      if (detections.any((d) => d.label == 'person')) {
        faceName = await _tryFaceRecognition(image);
      }

      if (!mounted) return;

      setState(() {
        _detections = detections;
        _pathAnalysis = analysis;
        if (_mode == _NavMode.walkMode) {
          _walkStatus = analysis.guidance;
        }
      });

      // 4. Speak guidance based on priority
      if (_walkActive || _navActive) {
        if (_pathAnalyzer.shouldSpeak(analysis)) {
          await _tts.speak(analysis.guidance);
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
      final inputImage = _buildInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);
      if (faces.isEmpty) return null;

      // Convert to RGB and process
      final rgbImage = _faceService.convertCameraImage(image);
      final rotated =
          _faceService.rotateImage(rgbImage, _sensorOrientation);
      final faceImage =
          _faceService.cropFace(rotated, faces.first.boundingBox);
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

  InputImage _buildInputImage(CameraImage image) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final int width = image.width;
    final int height = image.height;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    late final Uint8List nv21;

    if (uvPixelStride == 2) {
      final int yRowBytes = width;
      final int totalYBytes = yRowBytes * height;
      final int totalUVBytes = vPlane.bytes.length;
      nv21 = Uint8List(totalYBytes + totalUVBytes);
      if (yPlane.bytesPerRow == width) {
        nv21.setRange(0, totalYBytes, yPlane.bytes);
      } else {
        int dst = 0;
        for (int row = 0; row < height; row++) {
          final int src = row * yPlane.bytesPerRow;
          nv21.setRange(dst, dst + width, yPlane.bytes, src);
          dst += width;
        }
      }
      nv21.setRange(totalYBytes, totalYBytes + totalUVBytes, vPlane.bytes);
    } else {
      final int uvWidth = width ~/ 2;
      final int uvHeight = height ~/ 2;
      final int ySize = width * height;
      nv21 = Uint8List(ySize + uvWidth * uvHeight * 2);
      int pos = 0;
      for (int row = 0; row < height; row++) {
        final int offset = row * yPlane.bytesPerRow;
        for (int col = 0; col < width; col++) {
          nv21[pos++] = yPlane.bytes[offset + col];
        }
      }
      for (int row = 0; row < uvHeight; row++) {
        for (int col = 0; col < uvWidth; col++) {
          nv21[pos++] = vPlane.bytes[row * vPlane.bytesPerRow + col];
          nv21[pos++] = uPlane.bytes[row * uPlane.bytesPerRow + col];
        }
      }
    }

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
        size: Size(width.toDouble(), height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: width,
      ),
    );
  }

  void _announceFace(String name) {
    final now = DateTime.now();
    if (name == _lastFaceName &&
        now.difference(_lastFaceAnnounce).inSeconds < 8) {
      return;
    }
    _lastFaceName = name;
    _lastFaceAnnounce = now;

    if (name == 'Unknown person') {
      _tts.speak('Unknown person ahead.');
    } else {
      _tts.speak('$name ahead.');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Mode switching
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _enterWalkMode() async {
    setState(() {
      _mode = _NavMode.walkMode;
      _walkActive = true;
      _walkStatus = 'Starting walk mode...';
    });
    await _initCamera();
    _pathAnalyzer.resetCooldowns();
    await _tts.speak(
      'Walk mode active. I will guide you through obstacles. '
      'Walk straight ahead. Say stop to pause, or back to return.',
    );
  }

  Future<void> _enterDestinationMode() async {
    setState(() {
      _mode = _NavMode.destinationMode;
      _destStatus = 'Say your destination...';
      _currentInstruction = '';
    });
    await _initCamera();
    _pathAnalyzer.resetCooldowns();
    await _tts.speak(
      'Destination mode. Press volume up and say where you want to go.',
    );
  }

  void _exitToModeSelect() {
    _walkActive = false;
    _navActive = false;
    _navService.stopNavigation();
    _stopCamera();
    setState(() {
      _mode = _NavMode.modeSelect;
      _detections = [];
      _pathAnalysis = null;
    });
    _tts.speak(
      'Back to mode selection. Say walk mode or destination mode.',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Volume button / voice commands
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> onVolumeUp() async {
    switch (_mode) {
      case _NavMode.modeSelect:
        await _tts.speak(
          'Say walk mode for obstacle detection, '
          'or destination mode to navigate somewhere.',
        );
        break;
      case _NavMode.walkMode:
        // Repeat current guidance
        if (_pathAnalysis != null) {
          _pathAnalyzer.resetCooldowns();
          await _tts.speak(_pathAnalysis!.guidance);
        } else {
          await _tts.speak('Walk mode active. Point the camera ahead.');
        }
        break;
      case _NavMode.destinationMode:
        if (_navActive) {
          // Repeat current instruction
          if (_currentInstruction.isNotEmpty) {
            await _tts.speak(_currentInstruction);
          }
          await _tts.speak(_navService.getRemainingInfo());
        } else {
          await _tts.speak('Say where you want to go.');
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
          if (_detections.isEmpty) {
            await _tts
                .speak(hi ? 'कुछ नहीं दिख रहा।' : 'Nothing detected ahead.');
          } else {
            final names =
                _detections.take(5).map((d) => d.label).toSet().join(', ');
            await _tts.speak(hi ? 'सामने: $names।' : 'Ahead: $names.');
          }
        } else if (c.contains('who') || c.contains('kaun')) {
          if (_lastFaceName.isNotEmpty) {
            await _tts.speak(hi
                ? 'यह $_lastFaceName है।'
                : 'That is $_lastFaceName.');
          } else {
            await _tts.speak(
                hi ? 'कोई चेहरा नहीं मिला।' : 'No person identified.');
          }
        } else {
          await _tts.speak(hi
              ? 'बोलें: "stop", "what is ahead", या "back"।'
              : 'Say stop, what is ahead, who is that, or back.');
        }
        break;

      case _NavMode.destinationMode:
        if (c.contains('stop') ||
            c.contains('cancel') ||
            c.contains('ruko') ||
            c.contains('band')) {
          _navService.stopNavigation();
          setState(() {
            _navActive = false;
            _destStatus = 'Navigation cancelled.';
            _currentInstruction = '';
          });
          await _tts
              .speak(hi ? 'नेविगेशन रद्द।' : 'Navigation cancelled.');
        } else if (c.contains('how far') ||
            c.contains('kitna door') ||
            c.contains('remaining')) {
          await _tts.speak(_navService.getRemainingInfo());
        } else if (c.contains('repeat') ||
            c.contains('again') ||
            c.contains('dobara')) {
          if (_currentInstruction.isNotEmpty) {
            await _tts.speak(_currentInstruction);
          }
        } else if (!_navActive) {
          // Treat the entire command as a destination name
          await _startDestinationNavigation(cmd);
        } else {
          await _tts.speak(hi
              ? 'बोलें: "stop", "how far", या "repeat"।'
              : 'Say stop, how far, or repeat instruction.');
        }
        break;
    }
  }

  Future<void> _startDestinationNavigation(String destination) async {
    setState(() {
      _destStatus = 'Finding route to: $destination...';
    });
    await _tts.speak('Finding route to $destination. Please wait.');

    final route = await _navService.getDirections(destination);
    if (!mounted) return;

    if (route == null) {
      setState(() => _destStatus = 'Could not find route. Try again.');
      await _tts.speak(
        'Sorry, I could not find a route to $destination. '
        'Press volume up and say the destination again.',
      );
      return;
    }

    setState(() {
      _destStatus =
          'Route: ${route.totalDistance}, ${route.totalDuration}';
      _navActive = true;
    });

    await _tts.speak(
      'Route found. ${route.totalDistance}, ${route.totalDuration}. '
      '${route.steps.length} steps. Starting navigation.',
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
      backgroundColor: Colors.black,
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
        color: Colors.black,
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
                _tts.speak('Going back');
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
                    'Real-time obstacle detection with directional guidance. '
                    'AI detects objects, identifies people, and guides you safely.',
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
                gradientColors: const [Color(0xFF3F51B5), Color(0xFF283593)],
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
        // Camera + detection overlay
        Expanded(flex: 5, child: _buildCameraPreview()),
        // Zone indicator
        _buildZoneIndicator(),
        // Status / guidance
        _buildGuidancePanel(),
        // Detected objects chips
        if (_detections.isNotEmpty) _buildDetectionChips(),
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

        // Bounding box overlay
        if (_detections.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _NavBBoxPainter(
                objects: _detections,
                faceName: _lastFaceName,
              ),
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

        // Listening indicator
        if (isMixinListening)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
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
      ],
    );
  }

  Widget _buildZoneIndicator() {
    final left = _pathAnalysis?.leftBlocked ?? false;
    final center = _pathAnalysis?.centerBlocked ?? false;
    final right = _pathAnalysis?.rightBlocked ?? false;

    return SizedBox(
      height: 8,
      child: Row(
        children: [
          Expanded(
            child: Container(
              color: left ? _kRed : _kGreen,
            ),
          ),
          Container(width: 2, color: Colors.black),
          Expanded(
            child: Container(
              color: center ? _kRed : _kGreen,
            ),
          ),
          Container(width: 2, color: Colors.black),
          Expanded(
            child: Container(
              color: right ? _kRed : _kGreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuidancePanel() {
    final analysis = _pathAnalysis;
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
            child: Text(
              _walkStatus,
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_detections.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: guidanceColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_detections.length}',
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
  }

  Widget _buildDetectionChips() {
    return Container(
      height: 44,
      color: _kSurface,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _detections.length.clamp(0, 8),
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final det = _detections[i];
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
                det.label,
                style: GoogleFonts.inter(
                  color: chipColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWalkControls() {
    return Container(
      color: Colors.black,
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
                  _tts.speak('Walk mode resumed.');
                } else {
                  _tts.speak('Walk mode paused.');
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
                if (_pathAnalysis != null) {
                  _tts.speak(_pathAnalysis!.guidance);
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
        // Zone indicator
        if (_navActive) _buildZoneIndicator(),
        // Navigation instruction panel
        _buildNavigationPanel(),
        // Destination status
        _buildDestStatusBar(),
        // Controls
        _buildDestControls(),
      ],
    );
  }

  Widget _buildNavigationPanel() {
    if (!_navActive || _currentInstruction.isEmpty) {
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _kIndigo.withOpacity(0.12),
        border: Border(
          top: BorderSide(color: _kIndigo.withOpacity(0.4)),
          bottom: BorderSide(color: _kIndigo.withOpacity(0.4)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _kIndigo,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.navigation_rounded,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _currentInstruction,
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _navService.progressText,
                  style: GoogleFonts.inter(
                    color: _kIndigoLight,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDestStatusBar() {
    return Container(
      width: double.infinity,
      color: _kSurface,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
      child: Text(
        _destStatus,
        style: GoogleFonts.inter(
          color: _navActive ? _kGreen : Colors.white60,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildDestControls() {
    return Container(
      color: Colors.black,
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
                    _destStatus = 'Navigation stopped.';
                    _currentInstruction = '';
                  });
                  _tts.speak('Navigation stopped.');
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
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  if (_currentInstruction.isNotEmpty) {
                    _tts.speak(_currentInstruction);
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
//  Bounding Box Painter for Navigation
// ═════════════════════════════════════════════════════════════════════════════

class _NavBBoxPainter extends CustomPainter {
  final List<NavDetectedObject> objects;
  final String? faceName;

  const _NavBBoxPainter({required this.objects, this.faceName});

  @override
  void paint(Canvas canvas, Size size) {
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

      // Draw box
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      // Draw corners
      _drawCorners(canvas, rect, color);

      // Label
      String label = obj.label;
      if (obj.label == 'person' && faceName != null && faceName!.isNotEmpty) {
        label = faceName!;
      }
      label = '  $label (${(obj.confidence * 100).toStringAsFixed(0)}%)  ';

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.black,
            fontSize: 12,
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
    }
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
  bool shouldRepaint(_NavBBoxPainter old) =>
      old.objects != objects || old.faceName != faceName;
}