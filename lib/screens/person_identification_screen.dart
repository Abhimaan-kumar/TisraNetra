// lib/screens/person_identification_screen.dart
//
// REAL-TIME FACE RECOGNITION SCREEN
// ─────────────────────────────────────────────────────────────────────────────
// • Processes camera frames continuously via image stream (no polling delay)
// • Only speaks when identity CHANGES (avoids repetitive TTS)
// • Liveness detection: asks user to blink before confirming identity
// • Enrollment: capture 5 frames at different angles → averaged embedding
// • Works like phone face-unlock: one authorized person, all others = unknown

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/person_identification_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';
import 'profile_screen.dart';
import 'registration.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Screen state enum
// ─────────────────────────────────────────────────────────────────────────────

enum _Mode {
  initializing, // loading model + camera
  idle, // paused
  scanning, // live recognition active
  enrolling, // capturing samples for registration
  saving, // writing to DB
}

// ─────────────────────────────────────────────────────────────────────────────
// Main widget
// ─────────────────────────────────────────────────────────────────────────────

class PersonIdentificationScreen extends StatefulWidget {
  const PersonIdentificationScreen({super.key});

  @override
  State<PersonIdentificationScreen> createState() =>
      _PersonIdentificationScreenState();
}

class _PersonIdentificationScreenState extends State<PersonIdentificationScreen>
    with WidgetsBindingObserver, VolumeButtonMixin, TickerProviderStateMixin {
  // ── Services ──────────────────────────────────────────────────────────────
  final PersonIdentificationService _svc = PersonIdentificationService();
  final TtsService _tts = TtsService();
  final stt.SpeechToText _stt = stt.SpeechToText();
  final TextEditingController _nameCtrl = TextEditingController();

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _camReady = false;

  // ── Recognition loop ──────────────────────────────────────────────────────
  bool _isProcessingFrame = false;
  int _frameSkip = 0; // process every 3rd frame
  static const int _frameSkipTarget = 3;

  // ── Screen state ──────────────────────────────────────────────────────────
  _Mode _mode = _Mode.initializing;
  String _status = 'Loading model…';

  // ── Recognition results ───────────────────────────────────────────────────
  String? _currentName; // currently displayed name (null = unknown/no face)
  bool _hasFace = false;
  double? _lastDistance;
  bool _livenessOk = false;

  // ── TTS deduplication ─────────────────────────────────────────────────────
  String? _lastSpoken;
  DateTime? _lastSpokenAt;
  static const _speakCooldown = Duration(seconds: 8);

  // ── Enrollment ────────────────────────────────────────────────────────────
  static const int _enrollTarget = 5; // 5 samples → robust average
  final List<List<double>> _enrollSamples = [];
  bool _enrollCapturing = false;

  // ── Persons ───────────────────────────────────────────────────────────────
  List<SavedPerson> _persons = [];

  // ── Liveness UI ───────────────────────────────────────────────────────────
  bool _requireLiveness = true;
  bool _livenessPrompted = false;
  late final AnimationController _blinkAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );

  // ── STT ───────────────────────────────────────────────────────────────────
  bool _sttReady = false;

  // ── Counters ──────────────────────────────────────────────────────────────
  int _scanCount = 0;

  static const _accent = Color(0xFFBB86FC);
  static const _green = Color(0xFF00E676);
  static const _orange = Color(0xFFFF9800);

  // ══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Run initializations concurrently where possible
    _sttReady = await _stt.initialize();
    await _svc.initialize(); // TFLite + SQLite
    await _initCamera();
    await _reloadPersons();

    if (!mounted) return;

    if (!_svc.modelLoaded) {
      _setStatus(
        '⚠️ TFLite model missing. Place mobile_face_net.tflite in assets/models/',
      );
      await _tts.speak(
        'Face recognition model not found. Please add the model file.',
      );
      return;
    }

    _setMode(_Mode.scanning);
    _setStatus('Scanning — point camera at a person');
    _svc.resetLiveness();
    await _tts.speak(
      'Person identification ready. '
      '${_requireLiveness ? "Blink to verify liveness. " : ""}'
      'Point camera at someone to identify them.',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _stopStream();
        break;
      case AppLifecycleState.resumed:
        _initCamera();
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _cam?.dispose();
    _svc.dispose();
    _tts.dispose();
    _nameCtrl.dispose();
    _stt.cancel();
    _blinkAnim.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // VolumeButtonMixin
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> onVolumeUp() async {
    if (_mode == _Mode.scanning) {
      _pauseScan();
    } else if (_mode == _Mode.idle) {
      _resumeScan();
    }
  }

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';

    // Detect intents
    final isScan = _matches(cmd, ['scan', 'start', 'shuru', 'chalu', 'resume']);
    final isPause = _matches(cmd, ['pause', 'stop', 'ruko', 'band']);
    final isRepeat = _matches(cmd, [
      'repeat',
      'phir',
      'kaun',
      'batao',
      'dobara',
      'again',
    ]);
    final isSave = _matches(cmd, [
      'save',
      'add',
      'register',
      'jodo',
      'save kro',
    ]);
    final isDelete = _matches(cmd, ['delete', 'remove', 'hatao', 'mitao']);
    final isToggle = _matches(cmd, ['liveness', 'blink', 'toggle']);

    if (isPause) {
      _pauseScan();
      await _tts.speak(hi ? 'रुक गया।' : 'Paused.');
    } else if (isScan) {
      _resumeScan();
      await _tts.speak(hi ? 'स्कैन शुरू।' : 'Scanning.');
    } else if (isSave) {
      _openEnrollSheet();
    } else if (isDelete) {
      _confirmDeleteAll(hi);
    } else if (isToggle) {
      setState(() => _requireLiveness = !_requireLiveness);
      await _tts.speak(
        hi
            ? 'लाइवनेस ${_requireLiveness ? "चालू" : "बंद"}।'
            : 'Liveness check ${_requireLiveness ? "enabled" : "disabled"}.',
      );
    } else if (isRepeat) {
      await _speakCurrentResult(force: true, hi: hi);
    } else {
      await _tts.speak(
        hi
            ? '"स्कैन", "रुको", "सेव", या "दोहराओ" बोलें।'
            : 'Say "scan", "pause", "save", or "repeat".',
      );
    }
  }

  bool _matches(String cmd, List<String> keywords) =>
      keywords.any(cmd.contains);

  // ══════════════════════════════════════════════════════════════════════════
  // Camera
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus('No camera found');
        return;
      }

      // Prefer front camera for face recognition
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );

      final ctrl = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFlashMode(FlashMode.off);

      if (!mounted) return;
      setState(() {
        _cam = ctrl;
        _camReady = true;
      });

      if (_mode == _Mode.scanning) _startStream();
    } catch (e) {
      _setStatus('Camera error: $e');
    }
  }

  void _startStream() {
    if (!_camReady || _cam == null) return;
    if (_cam!.value.isStreamingImages) return;
    _cam!.startImageStream(_onFrame);
  }

  void _stopStream() {
    try {
      if (_cam?.value.isStreamingImages == true) {
        _cam!.stopImageStream();
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Frame processing (called ~30fps, we sample every N frames)
  // ══════════════════════════════════════════════════════════════════════════

  void _onFrame(CameraImage image) {
    if (_mode != _Mode.scanning) return;
    if (_isProcessingFrame) return;

    _frameSkip++;
    if (_frameSkip < _frameSkipTarget) return;
    _frameSkip = 0;

    _isProcessingFrame = true;
    _processFrame(image)
        .then((_) {
          _isProcessingFrame = false;
        })
        .catchError((e) {
          _isProcessingFrame = false;
          print('Frame error: $e');
        });
  }

  Future<void> _processFrame(CameraImage image) async {
    // Convert CameraImage → XFile via takePicture for ML Kit compatibility
    // (CameraImage YUV → InputImage directly would be faster but more complex)
    if (_cam == null) return;

    try {
      // Stop stream temporarily, take picture, restart
      await _cam!.stopImageStream();
      final photo = await _cam!.takePicture();
      if (_mode == _Mode.scanning) _cam!.startImageStream(_onFrame);

      _scanCount++;
      final result = await _svc.identifyPerson(
        photo,
        requireLiveness: _requireLiveness,
      );

      if (!mounted) return;
      _handleResult(result);
    } catch (e) {
      if (_mode == _Mode.scanning && _cam != null) {
        try {
          _cam!.startImageStream(_onFrame);
        } catch (_) {}
      }
    }
  }

  void _handleResult(IdentifyResult result) {
    if (!mounted) return;

    // ── No face ──────────────────────────────────────────────────────────
    if (!result.hasFace) {
      if (_hasFace) {
        setState(() {
          _hasFace = false;
          _currentName = null;
          _lastDistance = null;
          _status = 'No face — point camera at a person';
        });
      }
      return;
    }

    // ── Face detected ────────────────────────────────────────────────────
    setState(() {
      _hasFace = true;
      _lastDistance = result.distance;
      _livenessOk = result.livenessVerified;
    });

    // Liveness gate: prompt to blink if not yet verified
    if (_requireLiveness && !result.livenessVerified) {
      if (!_livenessPrompted) {
        _livenessPrompted = true;
        _setStatus('Please blink to verify you are real');
        _speakOnce('Please blink once to verify.', 'blink_prompt');
      }
      return;
    }

    _livenessPrompted = false;

    final newName = result.matchedName;

    // ── Known person ──────────────────────────────────────────────────────
    if (newName != null) {
      if (_currentName != newName) {
        setState(() {
          _currentName = newName;
          _status =
              '✓ Identified: $newName  (dist=${result.distance?.toStringAsFixed(2)})';
        });
        _speakOnce('$newName is in front of you.', newName);
      }
    } else {
      // ── Unknown person ────────────────────────────────────────────────
      if (_currentName != null || !_hasFace) {
        setState(() {
          _currentName = null;
          _status = 'Unknown person detected';
        });
      }
      // Show save UI after unknown face is stable
      if (!_showSaveUI) {
        setState(() {
          _currentName = null; // This will make _showSaveUI = true
          _hasFace = true; // Ensure face is detected
        });
      }
      _speakOnce('Unknown person detected.', 'unknown');
    }
  }

  bool get _showSaveUI => _currentName == null && _hasFace;

  // ══════════════════════════════════════════════════════════════════════════
  // Scan control
  // ══════════════════════════════════════════════════════════════════════════

  void _pauseScan() {
    _stopStream();
    _setMode(_Mode.idle);
    _setStatus('Paused — press volume up or tap Resume');
  }

  void _resumeScan() {
    _svc.resetLiveness();
    _livenessPrompted = false;
    _setMode(_Mode.scanning);
    _setStatus('Scanning…');
    _startStream();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Enrollment sheet
  // ══════════════════════════════════════════════════════════════════════════

  void _openEnrollSheet() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('Not logged in — tap the person icon to login', isError: true);
      _tts.speak('Not logged in.');
      return;
    }
    if (!_svc.modelLoaded) {
      _showSnack('TFLite model not loaded', isError: true);
      return;
    }

    _stopStream();
    _enrollSamples.clear();
    _nameCtrl.clear();
    _setMode(_Mode.enrolling);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _EnrollSheet(
        nameCtrl: _nameCtrl,
        target: _enrollTarget,
        sttReady: _sttReady,
        speechToText: _stt,
        getCount: () => _enrollSamples.length,
        onCapture: _captureEnrollSample,
        onSave: _commitEnrollment,
        onCancel: () {
          Navigator.pop(context);
          _enrollSamples.clear();
          _resumeScan();
        },
      ),
    );
  }

  Future<bool> _captureEnrollSample() async {
    if (_cam == null || !_camReady || _enrollCapturing) return false;
    setState(() => _enrollCapturing = true);
    try {
      final photo = await _cam!.takePicture();
      final emb = await _svc.extractEmbedding(photo);
      if (emb == null) {
        _showSnack(
          'No face detected — ensure face is visible and well-lit',
          isError: true,
        );
        return false;
      }
      _enrollSamples.add(emb);
      print('📸 Sample ${_enrollSamples.length}/$_enrollTarget');
      return true;
    } catch (e) {
      _showSnack('Capture failed: $e', isError: true);
      return false;
    } finally {
      if (mounted) setState(() => _enrollCapturing = false);
    }
  }

  Future<void> _commitEnrollment(String name) async {
    if (Navigator.canPop(context)) Navigator.pop(context);

    if (_enrollSamples.isEmpty) {
      _showSnack(
        'No face samples — please capture at least one',
        isError: true,
      );
      _resumeScan();
      return;
    }

    _setMode(_Mode.saving);
    _setStatus('Saving $name…');

    final result = await _svc.commitSave(
      name: name.trim(),
      embeddings: List.from(_enrollSamples),
    );
    _enrollSamples.clear();

    if (!mounted) return;

    switch (result.status) {
      case SaveStatus.success:
        await _reloadPersons();
        setState(() {
          _currentName = name.trim();
          _status = '✅ ${name.trim()} enrolled!';
        });
        _showSnack('${name.trim()} saved ✅', backgroundColor: Colors.green);
        await _tts.speak(
          '${name.trim()} has been registered. I will recognise them next time.',
        );
        break;

      case SaveStatus.notLoggedIn:
        _showSnack('Not logged in. Tap person icon to login.', isError: true);
        _tts.speak('Not logged in.');
        break;

      case SaveStatus.noModel:
        _showSnack('TFLite model not loaded', isError: true);
        _tts.speak('Model not available.');
        break;

      case SaveStatus.permissionDenied:
        _showSnack(
          'Firestore permission denied.\n'
          'Fix: Firebase Console → Firestore → Rules → '
          'allow read, write: if request.auth != null;',
          isError: true,
          duration: const Duration(seconds: 8),
        );
        _tts.speak('Permission denied. Saved locally.');
        break;

      default:
        _showSnack('Save failed: ${result.message}', isError: true);
        _tts.speak('Save failed.');
    }

    await Future.delayed(const Duration(seconds: 2));
    if (mounted) _resumeScan();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _reloadPersons() async {
    final list = await _svc.loadPersons();
    if (mounted) setState(() => _persons = list);
  }

  void _setMode(_Mode m) {
    if (mounted) setState(() => _mode = m);
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  /// Speak [text] only if different from last utterance or cooldown passed.
  void _speakOnce(String text, String key) {
    final now = DateTime.now();
    if (_lastSpoken == key &&
        _lastSpokenAt != null &&
        now.difference(_lastSpokenAt!) < _speakCooldown)
      return;
    _lastSpoken = key;
    _lastSpokenAt = now;
    _tts.speak(text);
  }

  Future<void> _speakCurrentResult({
    bool force = false,
    bool hi = false,
  }) async {
    if (force) {
      _lastSpoken = null;
    }
    if (_currentName != null) {
      await _tts.speak(
        hi
            ? '${_currentName} आपके सामने हैं।'
            : '$_currentName is in front of you.',
      );
    } else if (_hasFace) {
      await _tts.speak(hi ? 'अज्ञात व्यक्ति।' : 'Unknown person detected.');
    } else {
      await _tts.speak(hi ? 'कोई चेहरा नहीं मिला।' : 'No face detected.');
    }
  }

  void _showSnack(
    String msg, {
    bool isError = false,
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            backgroundColor ?? (isError ? Colors.redAccent : Colors.grey[800]),
        duration: duration,
      ),
    );
  }

  void _confirmDeleteAll(bool hi) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: Text(
          hi ? 'सभी हटाएं?' : 'Delete all?',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          hi
              ? 'सभी सहेजे गए लोगों को हटाया जाएगा।'
              : 'All enrolled persons will be removed.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              hi ? 'रद्द' : 'Cancel',
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _svc.deleteAllPersons();
              await _reloadPersons();
              _tts.speak(hi ? 'सब हटा दिया।' : 'All persons deleted.');
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  // ── AppBar ─────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() => AppBar(
    backgroundColor: Colors.black,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back, color: Colors.white),
      onPressed: () {
        _stopStream();
        Navigator.pop(context);
      },
    ),
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Person Identification',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          'Scan #$_scanCount  •  Enrolled: ${_persons.length}  '
          '${_svc.modelLoaded ? "• ✅ AI Ready" : "• ⚠️ No Model"}  '
          '${isMixinListening ? "• 🎤" : ""}',
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
      ],
    ),
    actions: [
      // Liveness toggle
      IconButton(
        icon: Icon(
          Icons.remove_red_eye,
          color: _requireLiveness ? _green : Colors.white38,
        ),
        tooltip: 'Toggle liveness check',
        onPressed: () {
          setState(() => _requireLiveness = !_requireLiveness);
          _svc.resetLiveness();
          _tts.speak('Liveness check ${_requireLiveness ? "on" : "off"}.');
        },
      ),
      // Repeat result
      IconButton(
        icon: Icon(Icons.volume_up, color: _hasFace ? _accent : Colors.white38),
        onPressed: () => _speakCurrentResult(force: true),
      ),
      // Auth
      StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (_, snap) => IconButton(
          icon: Icon(
            snap.data != null ? Icons.account_circle : Icons.login,
            color: snap.data != null ? _green : Colors.redAccent,
          ),
          tooltip: snap.data != null
              ? 'Logged in: ${snap.data!.email ?? snap.data!.uid}'
              : 'Not logged in — tap to login',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => snap.data != null
                  ? const ProfileScreen()
                  : const RegistrationScreen(),
            ),
          ),
        ),
      ),
    ],
  );

  // ── Body ───────────────────────────────────────────────────────────────────

  Widget _buildBody() {
    if (_mode == _Mode.initializing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('Loading AI model…', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Camera view — takes most of the screen
        Expanded(flex: 5, child: _buildCameraView()),
        // Status strip
        _buildStatusStrip(),
        // Result / action panel
        _buildResultPanel(),
        // Controls
        _buildControls(),
      ],
    );
  }

  // ── Camera view ────────────────────────────────────────────────────────────

  Widget _buildCameraView() {
    if (!_camReady || _cam == null) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    // Border color reflects current state
    final Color borderColor;
    if (_mode == _Mode.scanning && _currentName != null) {
      borderColor = _green;
    } else if (_mode == _Mode.scanning && _hasFace) {
      borderColor = _orange;
    } else {
      borderColor = _accent;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Live preview
        CameraPreview(_cam!),

        // Pulsing border when scanning
        if (_mode == _Mode.scanning || _mode == _Mode.enrolling)
          _PulsingBorder(color: borderColor),

        // Face detection overlay: name badge
        if (_hasFace)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: _FaceBadge(
              name: _currentName,
              distance: _lastDistance,
              livenessOk: _livenessOk,
              requireLiveness: _requireLiveness,
            ),
          ),

        // Liveness instruction overlay
        if (_requireLiveness &&
            _hasFace &&
            !_livenessOk &&
            _mode == _Mode.scanning)
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(child: _LivenessPrompt()),
          ),

        // Listening indicator
        if (isMixinListening)
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text(
                    'Listening…',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Paused overlay
        if (_mode == _Mode.idle)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Icon(
                Icons.pause_circle_filled,
                color: Colors.white54,
                size: 80,
              ),
            ),
          ),
      ],
    );
  }

  // ── Status strip ───────────────────────────────────────────────────────────

  Widget _buildStatusStrip() => Container(
    width: double.infinity,
    color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Row(
      children: [
        if (_mode == _Mode.scanning)
          _PulseDot(color: _currentName != null ? _green : _orange),
        if (_mode == _Mode.saving)
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2,
            ),
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _status,
            style: TextStyle(
              color: _mode == _Mode.scanning ? Colors.white : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
  );

  // ── Result panel ───────────────────────────────────────────────────────────

  Widget _buildResultPanel() {
    if (!_hasFace && _mode != _Mode.scanning) {
      return Container(
        height: 80,
        color: Colors.grey[850],
        child: const Center(
          child: Text(
            'Point camera at a person',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    if (_currentName != null) {
      return _KnownPersonCard(
        name: _currentName!,
        distance: _lastDistance,
        onRepeat: () => _speakCurrentResult(force: true),
      );
    }

    if (_hasFace) {
      return _UnknownPersonCard(
        onSave: _openEnrollSheet,
        persons: _persons,
        onDelete: (p) async {
          await _svc.deletePerson(p);
          await _reloadPersons();
          _tts.speak('${p.name} removed.');
        },
      );
    }

    return Container(
      height: 80,
      color: Colors.grey[850],
      child: const Center(
        child: Text(
          'No face detected',
          style: TextStyle(color: Colors.white38, fontSize: 13),
        ),
      ),
    );
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Widget _buildControls() => Container(
    color: Colors.black,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
    child: Row(
      children: [
        // Scan / Pause
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _camReady
                ? (_mode == _Mode.scanning ? _pauseScan : _resumeScan)
                : null,
            icon: Icon(
              _mode == _Mode.scanning
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              size: 26,
            ),
            label: Text(
              _mode == _Mode.scanning ? 'Pause' : 'Resume',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _mode == _Mode.scanning ? _orange : _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Repeat
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () => _speakCurrentResult(force: true),
            icon: const Icon(Icons.replay, size: 20),
            label: const Text('Repeat', style: TextStyle(fontSize: 14)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[800],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Enroll
        ElevatedButton(
          onPressed: _openEnrollSheet,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey[700],
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: const Icon(Icons.person_add_rounded, size: 22),
        ),
      ],
    ),
  );
}

// ═════════════════════════════════════════════════════════════════════════════
// Sub-widgets
// ═════════════════════════════════════════════════════════════════════════════

// ── Face badge (top of camera) ────────────────────────────────────────────────

class _FaceBadge extends StatelessWidget {
  final String? name;
  final double? distance;
  final bool livenessOk;
  final bool requireLiveness;
  const _FaceBadge({
    this.name,
    this.distance,
    required this.livenessOk,
    required this.requireLiveness,
  });

  @override
  Widget build(BuildContext context) {
    final isKnown = name != null;
    final color = isKnown ? const Color(0xFF00E676) : Colors.orange;
    final icon = isKnown ? Icons.check_circle : Icons.help_outline;
    final label = isKnown ? name! : 'Unknown';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(0.8), width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (distance != null) ...[
            const SizedBox(width: 8),
            Text(
              '${distance!.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
          if (requireLiveness) ...[
            const SizedBox(width: 8),
            Icon(
              livenessOk ? Icons.visibility : Icons.remove_red_eye_outlined,
              color: livenessOk ? const Color(0xFF00E676) : Colors.white38,
              size: 14,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Liveness prompt ────────────────────────────────────────────────────────────

class _LivenessPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 32),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.85),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.yellowAccent.withOpacity(0.6)),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.remove_red_eye, color: Colors.yellowAccent, size: 20),
        SizedBox(width: 10),
        Flexible(
          child: Text(
            'Please blink once to verify',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Known person card ─────────────────────────────────────────────────────────

class _KnownPersonCard extends StatelessWidget {
  final String name;
  final double? distance;
  final VoidCallback onRepeat;
  const _KnownPersonCard({
    required this.name,
    this.distance,
    required this.onRepeat,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFF00E676),
            radius: 24,
            child: Icon(Icons.check, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'IDENTIFIED',
                  style: TextStyle(
                    color: Color(0xFF00E676),
                    fontSize: 10,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$name is in front of you',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (distance != null)
                  Text(
                    'Confidence: ${((1 - distance! / 2) * 100).clamp(0, 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.volume_up, color: Colors.white54),
            onPressed: onRepeat,
          ),
        ],
      ),
    );
  }
}

// ── Unknown person card ───────────────────────────────────────────────────────

class _UnknownPersonCard extends StatelessWidget {
  final VoidCallback onSave;
  final List<SavedPerson> persons;
  final void Function(SavedPerson) onDelete;
  const _UnknownPersonCard({
    required this.onSave,
    required this.persons,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withOpacity(0.5)),
                ),
                child: const Text(
                  'UNKNOWN PERSON',
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const Spacer(),
              // Show enrolled persons count
              Text(
                '${persons.length} enrolled',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.person_add_rounded, size: 22),
              label: const Text(
                'Register This Person',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFBB86FC),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          // Quick list of enrolled persons with delete option
          if (persons.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: persons.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final p = persons[i];
                  return GestureDetector(
                    onLongPress: () => onDelete(p),
                    child: Chip(
                      label: Text(
                        p.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      backgroundColor: Colors.grey[700],
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () => onDelete(p),
                    ),
                  );
                },
              ),
            ),
            const Text(
              'Hold or tap × to remove a person',
              style: TextStyle(color: Colors.white24, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Enrollment sheet
// ═════════════════════════════════════════════════════════════════════════════

class _EnrollSheet extends StatefulWidget {
  final TextEditingController nameCtrl;
  final int target;
  final bool sttReady;
  final stt.SpeechToText speechToText;
  final int Function() getCount;
  final Future<bool> Function() onCapture;
  final Future<void> Function(String) onSave;
  final VoidCallback onCancel;

  const _EnrollSheet({
    required this.nameCtrl,
    required this.target,
    required this.sttReady,
    required this.speechToText,
    required this.getCount,
    required this.onCapture,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_EnrollSheet> createState() => _EnrollSheetState();
}

class _EnrollSheetState extends State<_EnrollSheet> {
  static const _accent = Color(0xFFBB86FC);
  bool _listening = false;
  bool _capturing = false;
  bool _saving = false;
  int _count = 0;

  // Instructions for each capture step
  static const _stepHints = [
    'Look straight at the camera',
    'Turn slightly left',
    'Turn slightly right',
    'Tilt head slightly up',
    'Normal position again',
  ];

  @override
  void initState() {
    super.initState();
    _count = widget.getCount();
  }

  Future<void> _capture() async {
    if (_capturing || _count >= widget.target) return;
    setState(() => _capturing = true);
    final ok = await widget.onCapture();
    setState(() {
      _capturing = false;
      if (ok) _count = widget.getCount();
    });
  }

  @override
  Widget build(BuildContext context) {
    final allDone = _count >= widget.target;
    final hint = _count < _stepHints.length ? _stepHints[_count] : 'Capture';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),

            // Title
            const Icon(Icons.face_retouching_natural, color: _accent, size: 40),
            const SizedBox(height: 8),
            const Text(
              'Register a Person',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Capture ${widget.target} face samples from different angles.\n'
              'This creates a robust face signature for reliable recognition.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 18),

            // Progress dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                widget.target,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i < _count ? 16 : 12,
                  height: i < _count ? 16 : 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _count
                        ? const Color(0xFF00E676)
                        : Colors.white24,
                    boxShadow: i < _count
                        ? [
                            const BoxShadow(
                              color: Color(0x6600E676),
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              allDone
                  ? '✓ All samples captured!'
                  : '$_count / ${widget.target}  —  $hint',
              style: TextStyle(
                color: allDone ? const Color(0xFF00E676) : Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),

            // Capture button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (_capturing || allDone) ? null : _capture,
                icon: _capturing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _accent,
                        ),
                      )
                    : Icon(
                        allDone ? Icons.check_circle : Icons.camera_alt,
                        color: allDone ? const Color(0xFF00E676) : _accent,
                        size: 20,
                      ),
                label: Text(
                  _capturing
                      ? 'Capturing…'
                      : allDone
                      ? 'All samples done!'
                      : 'Capture sample ${_count + 1} of ${widget.target}',
                  style: TextStyle(
                    color: allDone ? const Color(0xFF00E676) : _accent,
                    fontSize: 14,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: allDone ? const Color(0xFF00E676) : _accent,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Name field
            TextField(
              controller: widget.nameCtrl,
              autofocus: false,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: "Person's name (e.g. Rahul)",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.07),
                prefixIcon: const Icon(
                  Icons.badge_outlined,
                  color: Colors.white38,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _accent, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Mic + Save row
            Row(
              children: [
                // Mic button
                GestureDetector(
                  onTap: () async {
                    if (_listening) {
                      await widget.speechToText.stop();
                      setState(() => _listening = false);
                      return;
                    }
                    if (!widget.sttReady) return;
                    setState(() => _listening = true);
                    await widget.speechToText.listen(
                      onResult: (r) {
                        widget.nameCtrl.text = r.recognizedWords;
                        if (r.finalResult) setState(() => _listening = false);
                      },
                      listenFor: const Duration(seconds: 10),
                      localeId: 'en_IN',
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _listening
                          ? Colors.red.withOpacity(0.15)
                          : _accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _listening
                            ? Colors.red
                            : _accent.withOpacity(0.4),
                      ),
                    ),
                    child: Icon(
                      _listening ? Icons.mic_off : Icons.mic,
                      color: _listening ? Colors.red : _accent,
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Save button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_saving || _count == 0)
                        ? null
                        : () async {
                            final name = widget.nameCtrl.text.trim();
                            if (name.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter a name'),
                                ),
                              );
                              return;
                            }
                            setState(() => _saving = true);
                            await widget.onSave(name);
                          },
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_rounded, size: 22),
                    label: Text(
                      _saving
                          ? 'Saving…'
                          : _count == 0
                          ? 'Capture first ↑'
                          : 'Save  ($_count / ${widget.target})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _count == 0 ? Colors.grey[700] : _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            TextButton(
              onPressed: widget.onCancel,
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ),

            if (_listening)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '🎤 Listening…',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Animated helpers
// ═════════════════════════════════════════════════════════════════════════════

class _PulsingBorder extends StatefulWidget {
  final Color color;
  const _PulsingBorder({required this.color});
  @override
  State<_PulsingBorder> createState() => _PulsingBorderState();
}

class _PulsingBorderState extends State<_PulsingBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);
  late final Animation<double> _a = Tween(begin: 0.3, end: 1.0).animate(_c);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (_, __) => IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.color.withOpacity(_a.value),
            width: 3.0,
          ),
        ),
      ),
    ),
  );
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, __) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withOpacity(0.4 + 0.6 * _c.value),
      ),
    ),
  );
}
