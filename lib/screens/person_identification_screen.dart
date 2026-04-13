import 'dart:async';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/person_identification_service.dart';
import '../services/tts_service.dart';
import 'registration.dart';
import 'profile_screen.dart';

class PersonIdentificationScreen extends StatefulWidget {
  const PersonIdentificationScreen({super.key});

  @override
  State<PersonIdentificationScreen> createState() =>
      _PersonIdentificationScreenState();
}

class _PersonIdentificationScreenState
    extends State<PersonIdentificationScreen> with WidgetsBindingObserver {

  // ── Services ───────────────────────────────────────────────────────────────
  final PersonIdentificationService _service = PersonIdentificationService();
  final TtsService _ttsService = TtsService();
  final stt.SpeechToText _speech = stt.SpeechToText();

  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _isCameraReady = false;

  // ── Face detector ──────────────────────────────────────────────────────────
  late final FaceDetector _faceDetector;

  // ── Scan loop ──────────────────────────────────────────────────────────────
  bool _isScanning       = false;
  bool _keepScanning     = false;
  bool _isProcessing     = false;
  bool _isSpeaking       = false;
  bool _speechAvailable  = false;

  String _status  = 'Initializing...';
  int _scanCount  = 0;
  int _faceCount  = 0;

  // ── Result display ─────────────────────────────────────────────────────────
  String? _identifiedName;   // non-null = known person identified
  bool   _showSaveUI = false; // true = unknown person, show save button

  // ── Consecutive-frame guards ───────────────────────────────────────────────
  int     _unknownStreak     = 0;
  int     _knownStreak       = 0;
  String? _pendingKnownName;
  static const int _unknownStreakNeeded = 3;
  static const int _knownStreakNeeded   = 2;

  DateTime? _lastUnknownSpokenAt;
  static const Duration _unknownSpeakCooldown = Duration(seconds: 20);

  // ── Stored persons cache ───────────────────────────────────────────────────
  List<PersonData> _persons = [];

  // ══════════════════════════════════════════════════════════════════════════
  // ENROLLMENT STATE — kept as instance fields, never lost between frames
  // ══════════════════════════════════════════════════════════════════════════
  // These hold the actual vectors we will write to Firestore.
  // They are ONLY cleared after a successful save or explicit cancel.

  final List<List<double>> _enrollVectors = [];
  static const int _enrollTarget = 3;

  // The latest single vector from any scan (used to seed enrollment)
  List<double>? _latestVector;

  // Name field controller
  final TextEditingController _nameCtrl = TextEditingController();

  static const _accent = Color(0xFFBB86FC);

  // ══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableContours: true,
        enableLandmarks: true,
        enableClassification: false,
        enableTracking: false,
      ),
    );

    _initSpeech();
    _initCamera();
    _loadPersons();
    _ttsService.speak(
        'Person identification. Point camera at someone to identify them.');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _keepScanning = false;
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keepScanning = false;
    _cameraController?.dispose();
    _faceDetector.close();
    _ttsService.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Init
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) { _setStatus('No camera found'); return; }
      final ctrl = CameraController(
        cams.first, ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() { _cameraController = ctrl; _isCameraReady = true; });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _startScan();
    } catch (e) { _setStatus('Camera error: $e'); }
  }

  Future<void> _loadPersons() async {
    final list = await _service.getStoredPersons();
    if (mounted) setState(() => _persons = list);
    print('🔄 Persons loaded: ${list.length}');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Scan loop
  // ══════════════════════════════════════════════════════════════════════════

  void _startScan() {
    if (_isScanning) return;
    _unknownStreak = _knownStreak = 0;
    _pendingKnownName = null;
    setState(() { _isScanning = true; _keepScanning = true; _status = 'Scanning...'; });
    _ttsService.speak('Scanning started.');
    _loop();
  }

  void _stopScan() {
    setState(() { _isScanning = false; _keepScanning = false; _status = 'Paused'; });
  }

  Future<void> _loop() async {
    while (_keepScanning && mounted) {
      await _scanFrame();
      if (_keepScanning && mounted) await Future.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> _scanFrame() async {
    if (_isProcessing || !_isCameraReady || _cameraController == null) return;
    _scanCount++;
    setState(() { _isProcessing = true; _status = 'Scan #$_scanCount...'; });

    try {
      final photo = await _cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(photo.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        _unknownStreak = _knownStreak = 0;
        _setStatus('No face detected — point camera at a person');
        return;
      }

      _faceCount++;
      final vec = _service.extractFaceVector(faces.first);
      if (vec.isEmpty) { _setStatus('Face too small — move closer'); return; }

      // Always store latest vector — used to seed enrollment
      setState(() => _latestVector = vec);

      // Match
      final match = _persons.isNotEmpty
          ? _service.matchPerson(vec, _persons)
          : null;

      if (match != null) {
        // ── KNOWN ──────────────────────────────────────────────────────────
        _unknownStreak = 0;
        _knownStreak   = (match == _pendingKnownName) ? _knownStreak + 1 : 1;
        _pendingKnownName = match;

        setState(() {
          _identifiedName = match;
          _showSaveUI = false;
          _status = '✓ $match  ($_knownStreak/$_knownStreakNeeded)';
        });

        if (_knownStreak >= _knownStreakNeeded) {
          _knownStreak = 0; _pendingKnownName = null;
          setState(() => _isSpeaking = true);
          await _ttsService.speak('This is $match');
          if (mounted) setState(() => _isSpeaking = false);
        }
      } else {
        // ── UNKNOWN ────────────────────────────────────────────────────────
        _knownStreak = 0; _pendingKnownName = null;
        _unknownStreak++;

        setState(() {
          _identifiedName = null;
          _showSaveUI = true;   // show save button immediately on first unknown
          _status = 'Unknown person — tap "Save This Person" to add them';
        });

        if (_unknownStreak >= _unknownStreakNeeded) {
          final now = DateTime.now();
          if (_lastUnknownSpokenAt == null ||
              now.difference(_lastUnknownSpokenAt!) > _unknownSpeakCooldown) {
            _lastUnknownSpokenAt = now;
            _unknownStreak = 0;
            setState(() => _isSpeaking = true);
            await _ttsService.speak(
                'Unknown person. Tap save this person to add them.');
            if (mounted) setState(() => _isSpeaking = false);
          }
        }
      }
    } catch (e, st) {
      print('❌ _scanFrame: $e\n$st');
      _setStatus('Error — retrying...');
      await Future.delayed(const Duration(seconds: 3));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Enrollment — capture extra samples
  // ══════════════════════════════════════════════════════════════════════════

  // Called when user opens save dialog — seeds with _latestVector
  void _beginEnrollment() {
    _enrollVectors.clear();
    if (_latestVector != null && _latestVector!.isNotEmpty) {
      _enrollVectors.add(List<double>.from(_latestVector!));
      print('📸 Seed sample added (total: ${_enrollVectors.length})');
    }
  }

  // Called from the dialog when user taps "Capture sample N"
  Future<void> _captureEnrollSample(VoidCallback onUpdate) async {
    if (_cameraController == null || !_isCameraReady) return;
    try {
      final photo = await _cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(photo.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        final v = _service.extractFaceVector(faces.first);
        if (v.isNotEmpty) {
          _enrollVectors.add(v);
          print('📸 Enroll sample ${_enrollVectors.length}/$_enrollTarget captured');
          onUpdate();
        } else {
          _showSnack('Face vector empty — try again', isError: true);
        }
      } else {
        _showSnack('No face detected — face must be visible', isError: true);
      }
    } catch (e) {
      print('❌ _captureEnrollSample: $e');
      _showSnack('Capture failed: $e', isError: true);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Save dialog
  // ══════════════════════════════════════════════════════════════════════════

  void _openSaveDialog() {
    // ── Check login FIRST ──────────────────────────────────────────────────
    final user = FirebaseAuth.instance.currentUser;
    print('🔐 openSaveDialog: user=${user?.uid ?? "NULL"}');

    if (user == null) {
      _showSnack(
        'You are not logged in. Tap the person icon (top-right) to log in first.',
        isError: true,
        duration: const Duration(seconds: 5),
      );
      _ttsService.speak('Not logged in. Please log in first.');
      return;
    }

    // ── Check we have a face to save ───────────────────────────────────────
    if (_latestVector == null || _latestVector!.isEmpty) {
      _showSnack('No face captured yet — point camera at the person', isError: true);
      _ttsService.speak('No face data. Point camera at the person first.');
      return;
    }

    // Seed enrollment with the captured face
    _beginEnrollment();

    // Pause scanning while the dialog is open
    _keepScanning = false;
    setState(() => _isScanning = false);
    _nameCtrl.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      builder: (_) => _EnrollSheet(
        nameCtrl: _nameCtrl,
        speechAvailable: _speechAvailable,
        speech: _speech,
        enrollTarget: _enrollTarget,
        getCount: () => _enrollVectors.length,
        onCapture: _captureEnrollSample,
        onSave: _doSave,
        onCancel: () {
          _enrollVectors.clear();
          Navigator.pop(context);
          _startScan();
        },
      ),
    );
  }

  Future<void> _doSave(String name) async {
    // Close the sheet if still open
    if (Navigator.canPop(context)) Navigator.pop(context);

    if (_enrollVectors.isEmpty && _latestVector != null) {
      _enrollVectors.add(List<double>.from(_latestVector!));
    }

    print('📝 _doSave: name="$name" vectors=${_enrollVectors.length}');

    if (_enrollVectors.isEmpty) {
      _showSnack('No face samples captured — cannot save', isError: true);
      _startScan();
      return;
    }

    _setStatus('Saving $name to Firebase...');

    final result = await _service.savePerson(
      name: name.trim(),
      faceVectors: List<List<double>>.from(_enrollVectors),
    );

    _enrollVectors.clear();

    if (!mounted) return;

    if (result.isSuccess) {
      // ✅ SUCCESS
      await _loadPersons();
      setState(() {
        _identifiedName = name.trim();
        _showSaveUI = false;
        _status = '✅ ${name.trim()} saved!';
      });
      _showSnack('${name.trim()} saved to Firebase ✅',
          backgroundColor: Colors.green);
      await _ttsService.speak('${name.trim()} saved. I will recognise them next time.');
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _startScan();
    } else if (result.message == 'not_logged_in') {
      // Not logged in — direct them to login
      setState(() => _status = 'Not logged in');
      _showSnack(
        'Not logged in. Tap the person icon (top-right) to log in.',
        isError: true,
        duration: const Duration(seconds: 6),
      );
      _ttsService.speak('Not logged in. Please log in to save people.');
      _startScan();
    } else if (result.message.contains('permission')) {
      _showSnack(
        'Firestore permission denied.\n'
        'Go to Firebase Console → Firestore → Rules and set:\n'
        'allow read, write: if request.auth != null;',
        isError: true,
        duration: const Duration(seconds: 8),
      );
      _ttsService.speak('Permission denied. Please check Firestore rules.');
      _startScan();
    } else {
      _showSnack('Save failed: ${result.message}', isError: true);
      _ttsService.speak('Save failed.');
      _startScan();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════════════════════════════════

  void _setStatus(String s) { if (mounted) setState(() => _status = s); }

  void _showSnack(String msg, {
    bool isError = false,
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: backgroundColor ??
          (isError ? Colors.redAccent : Colors.grey[800]),
      duration: duration,
    ));
  }

  Future<void> _repeatResult() async {
    if (_identifiedName != null) {
      await _ttsService.speak('This is $_identifiedName');
    } else if (_showSaveUI) {
      await _ttsService.speak('Unknown person. Tap save this person to add them.');
    } else {
      await _ttsService.speak('No person detected yet.');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: Column(children: [
        Expanded(flex: 3, child: _buildCamera()),
        _buildStatusBar(),
        _buildResultPanel(),
        _buildControls(),
      ]),
    );
  }

  // ── AppBar ──────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() => AppBar(
    backgroundColor: Colors.black,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back, color: Colors.white),
      onPressed: () { _keepScanning = false; Navigator.pop(context); },
    ),
    title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Person ID',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
      Text('Scans: $_scanCount  Faces: $_faceCount  Saved: ${_persons.length}',
          style: const TextStyle(color: Colors.white54, fontSize: 11)),
    ]),
    actions: [
      IconButton(
        icon: Icon(Icons.volume_up, color: _isSpeaking ? _accent : Colors.white),
        onPressed: _repeatResult,
      ),
      // Login / profile button — always visible
      StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (ctx, snap) {
          final loggedIn = snap.data != null;
          return IconButton(
            icon: Icon(
              loggedIn ? Icons.account_circle : Icons.login,
              color: loggedIn ? Colors.greenAccent : Colors.redAccent,
            ),
            tooltip: loggedIn ? 'Profile' : 'Not logged in — tap to login',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) =>
                  loggedIn ? const ProfileScreen() : const RegistrationScreen()),
            ),
          );
        },
      ),
    ],
  );

  // ── Camera ──────────────────────────────────────────────────────────────────

  Widget _buildCamera() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 12),
          Text('Initializing camera...', style: TextStyle(color: Colors.white70)),
        ],
      ));
    }

    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_cameraController!),

      if (_isScanning) _ScanBorder(color: _accent),

      if (_identifiedName != null || _showSaveUI)
        Positioned(top: 12, left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (_identifiedName != null ? Colors.greenAccent : Colors.orange)
                    .withOpacity(0.8),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _identifiedName != null ? Icons.check_circle : Icons.help_outline,
                color: _identifiedName != null ? Colors.greenAccent : Colors.orange,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(_identifiedName ?? 'Unknown',
                  style: const TextStyle(color: Colors.white, fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),

      if (_isProcessing)
        Positioned(bottom: 14, left: 0, right: 0,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _accent.withOpacity(0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 12, height: 12,
                  child: CircularProgressIndicator(color: _accent, strokeWidth: 2)),
              const SizedBox(width: 8),
              const Text('Identifying...', style: TextStyle(color: Colors.white, fontSize: 13)),
            ]),
          )),
        ),

      if (_isSpeaking)
        Positioned(top: 12, right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.85),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.volume_up, color: Colors.white, size: 14),
              SizedBox(width: 4),
              Text('Speaking', style: TextStyle(color: Colors.white, fontSize: 11,
                  fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
    ]);
  }

  // ── Status bar ──────────────────────────────────────────────────────────────

  Widget _buildStatusBar() => Container(
    width: double.infinity,
    color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Row(children: [
      if (_isScanning) _PulseDot(color: _accent),
      const SizedBox(width: 8),
      Expanded(child: Text(_status, style: TextStyle(
        color: _isScanning ? _accent : Colors.white60, fontSize: 12))),
    ]),
  );

  // ── Result panel ────────────────────────────────────────────────────────────

  Widget _buildResultPanel() {
    // Empty
    if (_identifiedName == null && !_showSaveUI) {
      return Container(
        height: 100,
        color: Colors.grey[850],
        child: const Center(child: Text('Point camera at a person',
            style: TextStyle(color: Colors.white54, fontSize: 13))),
      );
    }

    // Known
    if (_identifiedName != null) {
      return Container(
        color: Colors.grey[850],
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          const CircleAvatar(backgroundColor: Colors.green, radius: 22,
              child: Icon(Icons.check, color: Colors.white)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('IDENTIFIED', style: TextStyle(color: Colors.greenAccent,
                fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('This is $_identifiedName', style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          ])),
        ]),
      );
    }

    // Unknown — big prominent Save button
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.5)),
            ),
            child: const Text('UNKNOWN PERSON', style: TextStyle(
                color: Colors.orange, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 1.0)),
          ),
        ]),
        const SizedBox(height: 10),
        const Text('This person is not in your saved list.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 12),

        // ── THE SAVE BUTTON ─────────────────────────────────────────────────
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _openSaveDialog,
            icon: const Icon(Icons.person_add_rounded, size: 22),
            label: const Text('Save This Person',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Auth status hint
        StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (ctx, snap) {
            final loggedIn = snap.data != null;
            return Text(
              loggedIn
                  ? '✅ Logged in as ${snap.data!.email ?? snap.data!.uid}'
                  : '⚠️ Not logged in — tap person icon (top-right) to login',
              style: TextStyle(
                fontSize: 11,
                color: loggedIn ? Colors.greenAccent : Colors.redAccent,
              ),
              textAlign: TextAlign.center,
            );
          },
        ),
      ]),
    );
  }

  // ── Controls ────────────────────────────────────────────────────────────────

  Widget _buildControls() => Container(
    color: Colors.black,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Row(children: [
      Expanded(flex: 2,
        child: ElevatedButton.icon(
          onPressed: _isCameraReady
              ? (_isScanning ? _stopScan : _startScan)
              : null,
          icon: Icon(_isScanning
              ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 26),
          label: Text(_isScanning ? 'Pause' : 'Resume',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: _isScanning ? Colors.orange : _accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: ElevatedButton.icon(
          onPressed: _repeatResult,
          icon: const Icon(Icons.replay, size: 22),
          label: const Text('Repeat', style: TextStyle(fontSize: 15)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey[800],
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    ]),
  );
}

// ═════════════════════════════════════════════════════════════════════════════
// _EnrollSheet — stateful enrollment bottom sheet
// Uses StatefulWidget so sample count updates live inside the sheet
// ═════════════════════════════════════════════════════════════════════════════

class _EnrollSheet extends StatefulWidget {
  final TextEditingController nameCtrl;
  final bool speechAvailable;
  final stt.SpeechToText speech;
  final int enrollTarget;
  final int Function() getCount;
  final Future<void> Function(VoidCallback onUpdate) onCapture;
  final Future<void> Function(String name) onSave;
  final VoidCallback onCancel;

  const _EnrollSheet({
    required this.nameCtrl,
    required this.speechAvailable,
    required this.speech,
    required this.enrollTarget,
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

  bool _isListening  = false;
  bool _isCapturing  = false;
  bool _isSaving     = false;
  int  _count        = 0;

  @override
  void initState() {
    super.initState();
    _count = widget.getCount();
  }

  void _refresh() => setState(() => _count = widget.getCount());

  Future<void> _capture() async {
    setState(() => _isCapturing = true);
    await widget.onCapture(_refresh);
    setState(() => _isCapturing = false);
  }

  Future<void> _startListen() async {
    if (!widget.speechAvailable) return;
    setState(() => _isListening = true);
    await widget.speech.listen(
      onResult: (r) {
        widget.nameCtrl.text = r.recognizedWords;
        if (r.finalResult) setState(() => _isListening = false);
      },
      listenFor: const Duration(seconds: 10),
      localeId: 'en_IN',
    );
  }

  Future<void> _stopListen() async {
    await widget.speech.stop();
    setState(() => _isListening = false);
  }

  @override
  Widget build(BuildContext context) {
    final allDone = _count >= widget.enrollTarget;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Handle
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.white30,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),

          const Icon(Icons.person_add_alt_1, color: _accent, size: 44),
          const SizedBox(height: 8),
          const Text('Save This Person',
              style: TextStyle(color: Colors.white, fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Capture ${widget.enrollTarget} face samples for best accuracy.\n'
            'You can save with just 1 sample too.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),

          // Sample dots
          Row(mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.enrollTarget, (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 5),
              width: 14, height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _count ? Colors.greenAccent : Colors.white24,
                boxShadow: i < _count ? [BoxShadow(
                    color: Colors.greenAccent.withOpacity(0.4), blurRadius: 6)] : null,
              ),
            )),
          ),
          const SizedBox(height: 6),
          Text('$_count / ${widget.enrollTarget} samples',
              style: TextStyle(
                  color: allDone ? Colors.greenAccent : Colors.white54,
                  fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 14),

          // Capture button
          if (!allDone)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isCapturing ? null : _capture,
                icon: _isCapturing
                    ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _accent))
                    : const Icon(Icons.camera_alt, color: _accent, size: 20),
                label: Text(
                  _isCapturing ? 'Capturing...'
                      : 'Capture sample ${_count + 1} of ${widget.enrollTarget}',
                  style: const TextStyle(color: _accent, fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          const SizedBox(height: 14),

          // Name field
          TextField(
            controller: widget.nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            decoration: InputDecoration(
              hintText: "Enter person's name...",
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white.withOpacity(0.08),
              prefixIcon: const Icon(Icons.badge_outlined, color: Colors.white54),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _accent, width: 1.5)),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 16),
            ),
          ),
          const SizedBox(height: 14),

          // Mic + Save row
          Row(children: [
            // Mic
            Container(
              decoration: BoxDecoration(
                color: _isListening
                    ? Colors.red.withOpacity(0.15) : _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: _isListening ? Colors.red : _accent.withOpacity(0.4)),
              ),
              child: IconButton(
                onPressed: _isListening ? _stopListen : _startListen,
                icon: Icon(_isListening ? Icons.mic_off : Icons.mic,
                    color: _isListening ? Colors.red : _accent, size: 26),
                padding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(width: 12),

            // Save button
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : () async {
                  final name = widget.nameCtrl.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a name')),
                    );
                    return;
                  }
                  if (_count == 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text(
                          'No face samples yet — tap Capture first, or re-open the dialog after pointing camera at face')),
                    );
                    return;
                  }
                  setState(() => _isSaving = true);
                  await widget.onSave(name);
                },
                icon: _isSaving
                    ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_rounded, size: 22),
                label: Text(
                  _isSaving ? 'Saving...'
                      : 'Save  ($_count sample${_count == 1 ? '' : 's'})',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),

          TextButton(
            onPressed: widget.onCancel,
            child: const Text('Cancel — Resume Scanning',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
          ),

          if (_isListening)
            const Padding(padding: EdgeInsets.only(top: 6),
              child: Text('🎤 Listening...',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12))),
        ]),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Animated helpers
// ═════════════════════════════════════════════════════════════════════════════

class _ScanBorder extends StatefulWidget {
  final Color color;
  const _ScanBorder({required this.color});
  @override State<_ScanBorder> createState() => _ScanBorderState();
}
class _ScanBorderState extends State<_ScanBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);
  late final Animation<double> _a = Tween(begin: 0.3, end: 1.0).animate(_c);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (_, __) => Container(decoration: BoxDecoration(
        border: Border.all(color: widget.color.withOpacity(_a.value), width: 2.5))),
  );
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override State<_PulseDot> createState() => _PulseDotState();
}
class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, __) => Container(width: 10, height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle,
          color: widget.color.withOpacity(0.4 + 0.6 * _c.value))),
  );
}