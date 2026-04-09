import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:firebase_auth/firebase_auth.dart';

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
  // ── Services ──────────────────────────────────────────────────
  final PersonIdentificationService _service =
      PersonIdentificationService();
  final TtsService _ttsService = TtsService();
  final stt.SpeechToText _speech = stt.SpeechToText();

  // ── Camera ────────────────────────────────────────────────────
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;

  // ── Face Detection (ML Kit — local, fast) ─────────────────────
  late final FaceDetector _faceDetector;

  // ── Scan state ────────────────────────────────────────────────
  bool _isScanning = false;
  bool _shouldKeepScanning = false;
  bool _isProcessing = false;
  bool _isSpeaking = false;
  bool _speechAvailable = false;

  String _statusMessage = 'Initializing...';
  int _scanCount = 0;
  int _facesFound = 0;

  // ── Result state ──────────────────────────────────────────────
  String? _lastIdentifiedName;
  String? _lastDescription;
  bool _lastWasUnknown = false;
  Uint8List? _lastFaceImageBytes;

  // ── Known persons cache ───────────────────────────────────────
  List<PersonData> _storedPersons = [];

  // ── Name input ────────────────────────────────────────────────
  final TextEditingController _nameController = TextEditingController();

  // ── Theme colours ─────────────────────────────────────────────
  static const _accent = Color(0xFFBB86FC);

  // ══════════════════════════════════════════════════════════════
  // ── Lifecycle ────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableClassification: false,
        enableTracking: false,
        enableContours: false,
        enableLandmarks: false,
      ),
    );

    _initSpeech();
    _initCamera();
    _loadStoredPersons();

    _ttsService.speak(
      'Person identification. Point your camera at someone to identify them.',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _shouldKeepScanning = false;
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shouldKeepScanning = false;
    _cameraController?.dispose();
    _faceDetector.close();
    _ttsService.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════
  // ── Init helpers ─────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _statusMessage = 'No camera found');
        return;
      }
      await _setupCamera(_cameras.first);
    } catch (e) {
      setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  Future<void> _setupCamera(CameraDescription cam) async {
    final ctrl = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() {
        _cameraController = ctrl;
        _isCameraReady = true;
        _statusMessage = 'Ready — scanning for faces';
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _startScanning();
    } catch (e) {
      setState(() => _statusMessage = 'Camera failed: $e');
    }
  }

  Future<void> _loadStoredPersons() async {
    try {
      _storedPersons = await _service.getStoredPersons();
      print('Loaded ${_storedPersons.length} stored person(s)');
    } catch (e) {
      print('Failed to load persons: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════
  // ── Scan control ─────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════

  void _toggleScanning() =>
      _isScanning ? _stopScanning() : _startScanning();

  void _startScanning() {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _shouldKeepScanning = true;
      _statusMessage = 'Scanning for faces...';
      _lastIdentifiedName = null;
      _lastWasUnknown = false;
    });
    _ttsService.speak('Scanning started.');
    _scanLoop();
  }

  void _stopScanning() {
    setState(() {
      _isScanning = false;
      _shouldKeepScanning = false;
      _statusMessage = 'Paused';
    });
    _ttsService.speak('Scanning paused.');
  }

  Future<void> _scanLoop() async {
    while (_shouldKeepScanning && mounted) {
      await _captureAndDetect();
      if (_shouldKeepScanning && mounted) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  // ══════════════════════════════════════════════════════════════
  // ── Capture → Face‑detect → Identify ────────────────────────
  // ══════════════════════════════════════════════════════════════

  Future<void> _captureAndDetect() async {
    if (_isProcessing || !_isCameraReady || _cameraController == null) return;
    if (!mounted) return;

    _scanCount++;
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Scan #$_scanCount — looking for faces...';
    });

    try {
      // 1. Take picture
      final photo = await _cameraController!.takePicture();
      final imageBytes = await photo.readAsBytes();

      // 2. ML Kit face detection (fast & free, runs locally)
      final inputImage = InputImage.fromFilePath(photo.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        setState(() {
          _statusMessage = 'Scan #$_scanCount — no face detected';
          _lastIdentifiedName = null;
          _lastWasUnknown = false;
        });
        return;
      }

      // 3. Face detected!
      _facesFound++;
      setState(() {
        _statusMessage = 'Face detected! Identifying...';
        _lastFaceImageBytes = imageBytes;
      });

      // 4. Try identification against stored persons
      if (_storedPersons.isNotEmpty) {
        final matchedName = await _service.identifyPerson(
          newFaceBytes: imageBytes,
          storedPersons: _storedPersons,
        );

        if (!mounted) return;

        if (matchedName != null) {
          setState(() {
            _lastIdentifiedName = matchedName;
            _lastWasUnknown = false;
            _statusMessage = '✓ Identified: $matchedName';
          });
          setState(() => _isSpeaking = true);
          await _ttsService.speak('This is $matchedName');
          if (mounted) setState(() => _isSpeaking = false);
          return;
        }
      }

      // 5. Unknown person — describe face, pause, and prompt
      final description = await _service.describeFace(imageBytes);
      if (!mounted) return;

      setState(() {
        _lastIdentifiedName = null;
        _lastWasUnknown = true;
        _lastDescription = description;
        _statusMessage = 'Unknown person detected';
      });

      // Pause scanning while the user decides
      _shouldKeepScanning = false;
      setState(() => _isScanning = false);

      setState(() => _isSpeaking = true);
      await _ttsService.speak(
        'I don\'t recognize this person. '
        '${description ?? ''} '
        'Tap the save button to add them, or resume scanning.',
      );
      if (mounted) setState(() => _isSpeaking = false);
    } catch (e) {
      print('Error: $e');
      if (!mounted) return;

      final msg = e.toString().toLowerCase();
      if (msg.contains('quota') ||
          msg.contains('429') ||
          msg.contains('rate')) {
        setState(() => _statusMessage = 'API quota reached — waiting...');
        await _ttsService.speak('Quota reached. Please wait.');
        await Future.delayed(const Duration(seconds: 30));
      } else if (msg.contains('api key') ||
          msg.contains('key not valid')) {
        setState(() => _statusMessage = 'Invalid API key');
        await _ttsService.speak('API key is invalid.');
        _stopScanning();
      } else {
        setState(() => _statusMessage = 'Error — retrying in 5 s...');
        await Future.delayed(const Duration(seconds: 5));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ══════════════════════════════════════════════════════════════
  // ── Save person ──────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════

  void _showSavePersonDialog() {
    if (_lastFaceImageBytes == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _ttsService.speak('Please log in first to save people.');
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RegistrationScreen()),
      );
      return;
    }

    _nameController.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SavePersonSheet(
        nameController: _nameController,
        description: _lastDescription ?? 'No description available',
        speechAvailable: _speechAvailable,
        speech: _speech,
        onSave: (name) async {
          Navigator.pop(ctx);
          await _saveNewPerson(name);
        },
        onCancel: () {
          Navigator.pop(ctx);
          _startScanning();
        },
      ),
    );
  }

  Future<void> _saveNewPerson(String name) async {
    if (_lastFaceImageBytes == null || name.trim().isEmpty) return;

    setState(() => _statusMessage = 'Saving $name...');

    try {
      await _service.savePerson(
        name: name.trim(),
        imageBytes: _lastFaceImageBytes!,
        description: _lastDescription ?? '',
      );

      // Reload the cache
      await _loadStoredPersons();

      if (!mounted) return;

      setState(() {
        _lastIdentifiedName = name.trim();
        _lastWasUnknown = false;
        _statusMessage = '✓ Saved: ${name.trim()}';
      });

      await _ttsService.speak(
        '${name.trim()} has been saved. I will recognize them next time.',
      );

      // Resume scanning after a brief pause
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _startScanning();
    } catch (e) {
      setState(() => _statusMessage = 'Failed to save: $e');
      await _ttsService.speak('Failed to save. Please try again.');
      _startScanning();
    }
  }

  // ══════════════════════════════════════════════════════════════
  // ── Repeat last result ───────────────────────────────────────
  // ══════════════════════════════════════════════════════════════

  Future<void> _repeatResult() async {
    if (_lastIdentifiedName != null) {
      await _ttsService.speak('This is $_lastIdentifiedName');
    } else if (_lastWasUnknown) {
      await _ttsService.speak(
        'Unknown person. ${_lastDescription ?? ''}',
      );
    } else {
      await _ttsService.speak('No person detected yet.');
    }
  }

  // ══════════════════════════════════════════════════════════════
  // ── Build ────────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _appBar(),
      body: Column(
        children: [
          Expanded(flex: 3, child: _cameraView()),
          _statusBar(),
          _resultPanel(),
          _controls(),
        ],
      ),
    );
  }

  // ── AppBar ──────────────────────────────────────────────────

  PreferredSizeWidget _appBar() => AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Person ID',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            Text(
              'Scans: $_scanCount  |  Faces: $_facesFound  |  Known: ${_storedPersons.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _shouldKeepScanning = false;
            _ttsService.speak('Going back.');
            Navigator.pop(context);
          },
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.volume_up,
                color: _isSpeaking ? _accent : Colors.white),
            onPressed: _repeatResult,
            tooltip: 'Repeat',
          ),
          IconButton(
            icon: const Icon(Icons.person, color: Colors.white),
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const RegistrationScreen()),
                );
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ProfileScreen()),
              );
            },
          ),
        ],
      );

  // ── Camera preview ──────────────────────────────────────────

  Widget _cameraView() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text('Initializing camera...',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_cameraController!),

      // Pulsing scan border
      if (_isScanning) _ScanBorder(color: _accent),

      // Identification badge top-left
      if (_lastIdentifiedName != null || _lastWasUnknown)
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _lastIdentifiedName != null
                    ? Colors.greenAccent.withOpacity(0.7)
                    : Colors.orange.withOpacity(0.7),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _lastIdentifiedName != null
                    ? Icons.check_circle
                    : Icons.help_outline,
                color: _lastIdentifiedName != null
                    ? Colors.greenAccent
                    : Colors.orange,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                _lastIdentifiedName ?? 'Unknown',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ),

      // Processing indicator
      if (_isProcessing)
        Positioned(
          bottom: 14,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(24),
                border:
                    Border.all(color: _accent.withOpacity(0.5)),
              ),
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          color: _accent, strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    const Text('Identifying...',
                        style: TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ]),
            ),
          ),
        ),

      // Speaking badge
      if (_isSpeaking)
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.85),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.volume_up, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text('Speaking',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ]),
          ),
        ),
    ]);
  }

  // ── Status bar ──────────────────────────────────────────────

  Widget _statusBar() => Container(
        width: double.infinity,
        color: Colors.grey[900],
        padding:
            const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Row(children: [
          if (_isScanning) _PulseDot(color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                color: _isScanning ? _accent : Colors.white60,
                fontSize: 12,
              ),
            ),
          ),
        ]),
      );

  // ── Result panel ────────────────────────────────────────────

  Widget _resultPanel() {
    // Empty state
    if (_lastIdentifiedName == null && !_lastWasUnknown) {
      return Container(
        height: 110,
        color: Colors.grey[850],
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.face, color: Colors.white30, size: 28),
              SizedBox(height: 6),
              Text(
                'Point camera at a person\nto identify them',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 110),
      color: Colors.grey[850],
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status tag
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: (_lastIdentifiedName != null
                      ? Colors.greenAccent
                      : Colors.orange)
                  .withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (_lastIdentifiedName != null
                        ? Colors.greenAccent
                        : Colors.orange)
                    .withOpacity(0.4),
              ),
            ),
            child: Text(
              _lastIdentifiedName != null
                  ? 'IDENTIFIED'
                  : 'UNKNOWN PERSON',
              style: TextStyle(
                color: _lastIdentifiedName != null
                    ? Colors.greenAccent
                    : Colors.orange,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Name or description
          Text(
            _lastIdentifiedName != null
                ? 'This is $_lastIdentifiedName'
                : _lastDescription ?? 'Unknown person detected',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),

          // Save button for unknown person
          if (_lastWasUnknown) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _showSavePersonDialog,
                icon: const Icon(Icons.person_add, size: 20),
                label: const Text('Save This Person',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Bottom controls ─────────────────────────────────────────

  Widget _controls() => Container(
        color: Colors.black,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Row(children: [
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _isCameraReady ? _toggleScanning : null,
              icon: Icon(
                _isScanning
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                size: 26,
              ),
              label: Text(
                _isScanning ? 'Pause' : 'Resume',
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _isScanning ? Colors.orange : _accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _repeatResult,
              icon: const Icon(Icons.replay, size: 22),
              label:
                  const Text('Repeat', style: TextStyle(fontSize: 15)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[800],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ]),
      );
}

// ════════════════════════════════════════════════════════════════
// ── Save-person bottom sheet ──────────────────────────────────
// ════════════════════════════════════════════════════════════════

class _SavePersonSheet extends StatefulWidget {
  final TextEditingController nameController;
  final String description;
  final bool speechAvailable;
  final stt.SpeechToText speech;
  final Future<void> Function(String name) onSave;
  final VoidCallback onCancel;

  const _SavePersonSheet({
    required this.nameController,
    required this.description,
    required this.speechAvailable,
    required this.speech,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_SavePersonSheet> createState() => _SavePersonSheetState();
}

class _SavePersonSheetState extends State<_SavePersonSheet> {
  bool _isListening = false;

  static const _accent = Color(0xFFBB86FC);

  void _startListening() async {
    if (!widget.speechAvailable) return;
    setState(() => _isListening = true);

    await widget.speech.listen(
      onResult: (result) {
        setState(() {
          widget.nameController.text = result.recognizedWords;
        });
        if (result.finalResult) {
          setState(() => _isListening = false);
        }
      },
      listenFor: const Duration(seconds: 10),
      localeId: 'en_IN',
    );
  }

  void _stopListening() async {
    await widget.speech.stop();
    setState(() => _isListening = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E2E),
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // Icon + title
            const Icon(Icons.person_add_alt_1,
                color: _accent, size: 40),
            const SizedBox(height: 12),
            const Text('Unknown Person',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              widget.description,
              style:
                  const TextStyle(color: Colors.white60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // Name input field
            TextField(
              controller: widget.nameController,
              style:
                  const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Enter person\'s name...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.08),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: _accent, width: 1.5),
                ),
                prefixIcon:
                    const Icon(Icons.person, color: Colors.white54),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 16),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),

            // Action buttons
            Row(
              children: [
                // Mic button
                Container(
                  decoration: BoxDecoration(
                    color: _isListening
                        ? Colors.red.withOpacity(0.2)
                        : _accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _isListening
                          ? Colors.red
                          : _accent.withOpacity(0.4),
                    ),
                  ),
                  child: IconButton(
                    onPressed:
                        _isListening ? _stopListening : _startListening,
                    icon: Icon(
                      _isListening ? Icons.mic_off : Icons.mic,
                      color: _isListening ? Colors.red : _accent,
                      size: 28,
                    ),
                    tooltip: _isListening
                        ? 'Stop listening'
                        : 'Speak name',
                    padding: const EdgeInsets.all(14),
                  ),
                ),
                const SizedBox(width: 12),

                // Save button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final name =
                          widget.nameController.text.trim();
                      if (name.isEmpty) return;
                      widget.onSave(name);
                    },
                    icon: const Icon(Icons.save, size: 20),
                    label: const Text('Save Person',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Cancel
            TextButton(
              onPressed: widget.onCancel,
              child: const Text('Cancel / Resume Scanning',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 14)),
            ),

            // Listening indicator
            if (_isListening) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _PulseDot(color: Colors.red),
                  const SizedBox(width: 6),
                  const Text('Listening...',
                      style: TextStyle(
                          color: Colors.red, fontSize: 12)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// ── Animated helpers ──────────────────────────────────────────
// ════════════════════════════════════════════════════════════════

class _ScanBorder extends StatefulWidget {
  final Color color;
  const _ScanBorder({required this.color});

  @override
  State<_ScanBorder> createState() => _ScanBorderState();
}

class _ScanBorderState extends State<_ScanBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);
  late final Animation<double> _a =
      Tween<double>(begin: 0.3, end: 1.0).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _a,
      builder: (_, __) => Container(
          decoration: BoxDecoration(
              border: Border.all(
                  color: widget.color.withOpacity(_a.value),
                  width: 2.5))));
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
      vsync: this, duration: const Duration(milliseconds: 800))
    ..repeat(reverse: true);

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
              color:
                  widget.color.withOpacity(0.4 + 0.6 * _c.value))));
}
