// lib/screens/person_identification_screen.dart
//
// Real-time face recognition screen using:
//   • camera (YUV420 image stream)
//   • google_mlkit_face_detection (face bounding boxes)
//   • tflite_flutter + MobileFaceNet (192-d embeddings)
//   • sqflite (local person database)
//
// Workflow:
//   1. Stream camera frames, process every 5th frame.
//   2. Detect faces via ML Kit.
//   3. Convert YUV→RGB, rotate, crop face, resize 112×112, normalise, run TFLite.
//   4. Compare embedding against all stored persons (cosine similarity ≥ 0.6).
//   5. Display identified name or "Unknown" over the camera preview.
//   6. Unknown faces trigger an optional save flow (5 poses: normal/left/right/up/down).

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../services/face_db_service.dart';
import '../services/face_embedding_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';

// ─── Constants ────────────────────────────────────────────────────────────────

const _kProcessEveryN = 5; // process every N-th frame
const _kThreshold = 0.6; // cosine similarity threshold

const _kGold = Color(0xFFD4AC0D);

const _kGreen = Color(0xFF00E676);
const _kRed = Color(0xFFFF3D71);
const _kSurface = Color(0xFF141929);
const _kCard = Color(0xFF1C2137);
const _kCardBorder = Color(0xFF2A3050);

const List<(String label, String instruction)> _kPoses = [
  ('Normal', 'Look straight at the camera'),
  ('Left', 'Slowly turn head to the left'),
  ('Right', 'Slowly turn head to the right'),
  ('Up', 'Tilt head slightly upward'),
  ('Down', 'Tilt head slightly downward'),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class PersonIdentificationScreen extends StatefulWidget {
  const PersonIdentificationScreen({super.key});

  @override
  State<PersonIdentificationScreen> createState() =>
      _PersonIdentificationScreenState();
}

class _PersonIdentificationScreenState
    extends State<PersonIdentificationScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {
  // ── Services ──────────────────────────────────────────────────────────────
  final FaceDBService _dbService = FaceDBService();
  final FaceEmbeddingService _embeddingService = FaceEmbeddingService();
  final TtsService _tts = TtsService();
  late final FaceDetector _faceDetector;

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _cam;
  List<CameraDescription> _cameras = [];
  bool _camReady = false;
  int _sensorOrientation = 0;

  // ── Processing ────────────────────────────────────────────────────────────
  bool _isProcessing = false;
  int _frameCount = 0;

  // ── Detection results ─────────────────────────────────────────────────────
  List<Face> _faces = [];
  String _identifiedName = '';
  double _confidence = 0.0;
  Size _imageSize = Size.zero;

  // ── TTS debounce ──────────────────────────────────────────────────────────
  String _lastSpokenName = '';
  DateTime _lastSpeakTime = DateTime(2000);

  // ── Person DB cache ───────────────────────────────────────────────────────
  List<PersonRecord> _persons = [];

  // ── Save flow ─────────────────────────────────────────────────────────────
  bool _isSaving = false;
  int _saveStep = -1; // -1 = not saving, 0–4 = pose index
  bool _capturingPose = true; // blocks capture until ready
  List<List<double>> _capturedEmbeddings = [];

  // ── Status ────────────────────────────────────────────────────────────────
  String _status = 'Initializing…';
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
      _cam?.dispose();
      _cam = null;
      _camReady = false;
    } else if (state == AppLifecycleState.resumed && _initialized) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try {
      _cam?.stopImageStream();
    } catch (_) {}
    _cam?.dispose();
    _faceDetector.close();
    _embeddingService.dispose();
    _tts.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Initialisation
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initAll() async {
    try {
      // 1. Load TFLite model
      await _embeddingService.init();

      // 2. Init face detector (fast mode, tracking on)
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableTracking: true,
          minFaceSize: 0.15,
        ),
      );

      // 3. Load saved persons
      await _loadPersons();

      // 4. Init camera
      await _initCamera();

      if (!mounted) return;
      setState(() {
        _initialized = true;
        _status = 'Ready';
      });
      _tts.speak(
        'Person identification ready. Point the camera at a person.',
      );
    } catch (e) {
      debugPrint('[PersonID] Init error: $e');
      if (mounted) {
        setState(() {
          _initError = e.toString();
          _status = 'Initialisation failed';
        });
      }
      _tts.speak('Failed to initialise. Please restart the screen.');
    }
  }

  Future<void> _loadPersons() async {
    _persons = await _dbService.getAllPersons();
    debugPrint('[PersonID] Loaded ${_persons.length} persons from DB');
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
      setState(() => _status = 'No camera available');
      return;
    }

    final camera = _cameras.first; // rear camera
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  Frame processing pipeline
  // ═══════════════════════════════════════════════════════════════════════════

  void _onCameraFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % _kProcessEveryN != 0) return;
    if (_isProcessing) return;
    _isProcessing = true;
    _processImage(image);
  }

  Future<void> _processImage(CameraImage image) async {
    try {
      // ── Synchronous: touch camera data BEFORE any await ──────────────────

      // 1. Build InputImage for ML Kit (copies bytes via WriteBuffer)
      final inputImage = _buildInputImage(image);

      // 2. Convert YUV→RGB (synchronous, uses native camera buffer)
      final rgbImage = _embeddingService.convertCameraImage(image);

      // ── Async: camera data no longer needed after this point ─────────────

      // 3. Rotate to match ML Kit bbox coordinate system
      final rotatedImage =
          _embeddingService.rotateImage(rgbImage, _sensorOrientation);

      // 4. Face detection (runs on native thread)
      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted) return;

      // 5. Effective image size (post-rotation, for overlay scaling)
      final effectiveSize =
          (_sensorOrientation == 90 || _sensorOrientation == 270)
              ? Size(image.height.toDouble(), image.width.toDouble())
              : Size(image.width.toDouble(), image.height.toDouble());

      if (faces.isEmpty) {
        setState(() {
          _faces = [];
          _identifiedName = '';
          _confidence = 0.0;
          _imageSize = effectiveSize;
          _status = _isSaving
              ? '${_kPoses[_saveStep].$2} — waiting for face…'
              : 'No face detected';
        });
        return;
      }

      // 6. Use the first (largest) detected face
      final face = faces.first;

      // 7. Crop face region from rotated RGB image
      final faceImage =
          _embeddingService.cropFace(rotatedImage, face.boundingBox);

      // 8. Run MobileFaceNet → 192-d embedding
      final embedding = _embeddingService.getEmbedding(faceImage);

      // 9. Route to save or identify
      if (_isSaving && _saveStep >= 0 && _saveStep < _kPoses.length) {
        _captureForSave(embedding, faces, effectiveSize);
      } else {
        _identifyPerson(embedding, faces, effectiveSize);
      }
    } catch (e) {
      debugPrint('[PersonID] Processing error: $e');
      if (mounted) setState(() => _status = 'Processing error');
    } finally {
      _isProcessing = false;
    }
  }

  /// Build a proper NV21 InputImage from a YUV_420_888 camera frame.
  ///
  /// NV21 layout: all Y bytes first, then interleaved V,U bytes.
  InputImage _buildInputImage(CameraImage image) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final int width = image.width;
    final int height = image.height;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    late final Uint8List nv21;

    if (uvPixelStride == 2) {
      // Fast path: UV planes are already interleaved
      final int yRowBytes = width;
      final int totalYBytes = yRowBytes * height;
      final int totalUVBytes = vPlane.bytes.length;

      nv21 = Uint8List(totalYBytes + totalUVBytes);

      // Copy Y plane
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
      // Copy VU interleaved
      nv21.setRange(totalYBytes, totalYBytes + totalUVBytes, vPlane.bytes);
    } else {
      // Slow path: UV planes are planar
      final int uvWidth = width ~/ 2;
      final int uvHeight = height ~/ 2;
      final int ySize = width * height;

      nv21 = Uint8List(ySize + uvWidth * uvHeight * 2);

      // Copy Y plane
      int pos = 0;
      for (int row = 0; row < height; row++) {
        final int offset = row * yPlane.bytesPerRow;
        for (int col = 0; col < width; col++) {
          nv21[pos++] = yPlane.bytes[offset + col];
        }
      }

      // Interleave V, U
      for (int row = 0; row < uvHeight; row++) {
        for (int col = 0; col < uvWidth; col++) {
          final int vi = row * vPlane.bytesPerRow + col;
          final int ui = row * uPlane.bytesPerRow + col;
          nv21[pos++] = vPlane.bytes[vi];
          nv21[pos++] = uPlane.bytes[ui];
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  Identification
  // ═══════════════════════════════════════════════════════════════════════════

  void _identifyPerson(
      List<double> embedding, List<Face> faces, Size imageSize) {
    if (!mounted) return;

    String bestName = 'Unknown';
    double bestSim = 0.0;

    for (final person in _persons) {
      for (final stored in person.embeddings) {
        final sim = _embeddingService.cosineSimilarity(embedding, stored);
        if (sim > bestSim) {
          bestSim = sim;
          bestName = person.name;
        }
      }
    }

    if (bestSim < _kThreshold) {
      bestName = 'Unknown';
      bestSim = 0.0;
    }

    // Debounced TTS announcement (speak only on change, with 3s cooldown)
    final now = DateTime.now();
    if (bestName != _lastSpokenName &&
        now.difference(_lastSpeakTime).inSeconds >= 3) {
      _lastSpokenName = bestName;
      _lastSpeakTime = now;
      if (bestName == 'Unknown') {
        _tts.speak('Unknown person.');
      } else {
        _tts.speak('This is $bestName.');
      }
    }

    setState(() {
      _faces = faces;
      _imageSize = imageSize;
      _identifiedName = bestName;
      _confidence = bestSim;
      _status = bestName == 'Unknown'
          ? 'Unknown person detected'
          : 'Identified: $bestName '
              '(${(bestSim * 100).toStringAsFixed(1)}%)';
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Save flow  (5 poses: normal → left → right → up → down)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startSaveFlow() async {
    setState(() {
      _isSaving = true;
      _saveStep = 0;
      _capturedEmbeddings = [];
      _capturingPose = true; // block capture until TTS finishes
      _status = _kPoses[0].$2;
    });

    await _tts.speak(
      'Starting face enrollment. Ask the person to '
      '${_kPoses[0].$2.toLowerCase()}.',
    );
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) _capturingPose = false; // allow first capture
  }

  /// Called while _isSaving to capture an embedding for the current pose.
  void _captureForSave(
      List<double> embedding, List<Face> faces, Size imageSize) {
    // Update overlay
    setState(() {
      _faces = faces;
      _imageSize = imageSize;
    });

    if (_capturingPose) return; // still in transition delay
    _capturingPose = true;

    _capturedEmbeddings.add(embedding);
    _advanceSaveStep();
  }

  Future<void> _advanceSaveStep() async {
    if (_saveStep < _kPoses.length - 1) {
      // Show "Captured ✓" briefly
      setState(() => _status = '${_kPoses[_saveStep].$1} captured ✓');
      await _tts.speak('Captured.');
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;

      // Move to next pose
      setState(() {
        _saveStep++;
        _status = _kPoses[_saveStep].$2;
      });
      await _tts.speak('Now ${_kPoses[_saveStep].$2.toLowerCase()}.');
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _capturingPose = false; // allow next capture
    } else {
      // All 5 poses captured
      setState(() => _status = 'All views captured!');
      await _tts.speak('All views captured. Please enter the person\'s name.');
      if (mounted) _showNameDialog();
    }
  }

  void _cancelSave() {
    setState(() {
      _isSaving = false;
      _saveStep = -1;
      _capturedEmbeddings = [];
      _capturingPose = true;
      _status = 'Save cancelled';
    });
    _tts.speak('Face enrollment cancelled.');
  }

  Future<void> _savePerson(String name) async {
    await _dbService.addPerson(name, _capturedEmbeddings);
    await _loadPersons();
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      _saveStep = -1;
      _capturedEmbeddings = [];
      _capturingPose = true;
      _status = '$name saved successfully!';
      _lastSpokenName = ''; // reset so next identification speaks
    });
    _tts.speak('$name has been saved. You can now identify them.');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Volume button / voice commands
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> onVolumeUp() async {
    // Default action when no voice command: toggle save or repeat name
    if (_isSaving) {
      _cancelSave();
    } else if (_identifiedName.isNotEmpty && _identifiedName != 'Unknown') {
      await _tts.speak('This is $_identifiedName.');
    } else {
      await _tts.speak('Unknown person. Say "save" to save this face.');
    }
  }

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';

    if (cmd.contains('save') ||
        cmd.contains('bachao') ||
        cmd.contains('store')) {
      if (_isSaving) {
        await _tts
            .speak(hi ? 'पहले से सेव हो रहा है।' : 'Already saving a face.');
      } else if (_identifiedName == 'Unknown' && _faces.isNotEmpty) {
        _startSaveFlow();
      } else if (_faces.isEmpty) {
        await _tts.speak(
            hi ? 'कोई चेहरा नहीं मिला।' : 'No face detected to save.');
      } else {
        await _tts.speak(hi
            ? 'यह व्यक्ति पहले से पहचाना गया है।'
            : 'This person is already identified.');
      }
    } else if (cmd.contains('cancel') || cmd.contains('रद्द')) {
      if (_isSaving) _cancelSave();
    } else if (cmd.contains('who') ||
        cmd.contains('kaun') ||
        cmd.contains('name')) {
      if (_identifiedName.isNotEmpty && _identifiedName != 'Unknown') {
        await _tts
            .speak(hi ? 'यह $_identifiedName है।' : 'This is $_identifiedName.');
      } else {
        await _tts.speak(hi ? 'अनजान व्यक्ति।' : 'Unknown person.');
      }
    } else if (cmd.contains('list') ||
        cmd.contains('persons') ||
        cmd.contains('delete') ||
        cmd.contains('hatao')) {
      _showPersonsDialog();
    } else {
      await _tts.speak(hi
          ? 'कृपया "save", "cancel", या "who" बोलें।'
          : 'Say "save", "cancel", "who is this", or "list persons".');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Dialogs
  // ═══════════════════════════════════════════════════════════════════════════

  void _showNameDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kGold, width: 1),
        ),
        title: Text(
          'Save Person',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.inter(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Person\'s name',
            labelStyle: GoogleFonts.inter(color: Colors.white60),
            hintText: 'e.g. John',
            hintStyle: GoogleFonts.inter(color: Colors.white30),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _kCardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _kGold),
            ),
            filled: true,
            fillColor: _kSurface,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cancelSave();
            },
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: Colors.white60),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGold,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              _savePerson(name);
            },
            child: Text(
              'Save',
              style: GoogleFonts.inter(
                color: Colors.black,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPersonsDialog() async {
    final persons = await _dbService.getAllPersons();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kCardBorder),
        ),
        title: Text(
          'Saved Persons (${persons.length})',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: persons.isEmpty
              ? Center(
                  child: Text(
                    'No persons saved yet.',
                    style: GoogleFonts.inter(color: Colors.white60),
                  ),
                )
              : ListView.separated(
                  itemCount: persons.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: _kCardBorder, height: 1),
                  itemBuilder: (_, i) {
                    final p = persons[i];
                    return ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: _kGold,
                        child: Icon(Icons.person, color: Colors.black),
                      ),
                      title: Text(
                        p.name,
                        style: GoogleFonts.inter(color: Colors.white),
                      ),
                      subtitle: Text(
                        '${p.embeddings.length} view(s)',
                        style: GoogleFonts.inter(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: _kRed, size: 22),
                        onPressed: () async {
                          await _dbService.deletePerson(p.id);
                          await _loadPersons();
                          if (ctx.mounted) Navigator.pop(ctx);
                          _tts.speak('${p.name} deleted.');
                          _showPersonsDialog(); // refresh
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text('Close', style: GoogleFonts.inter(color: Colors.white60)),
          ),
        ],
      ),
    );
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
            Expanded(child: _buildCameraArea()),
            _buildBottomPanel(),
          ],
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.black,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              _tts.speak('Going back');
              Navigator.pop(context);
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isSaving ? 'Face Enrollment' : 'Person Identification',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  isMixinListening
                      ? '🎤 Listening…'
                      : 'Vol↑ = voice command',
                  style: GoogleFonts.inter(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          // Persons list button
          IconButton(
            icon: const Icon(Icons.people_alt_outlined, color: _kGold),
            tooltip: 'Saved Persons',
            onPressed: _showPersonsDialog,
          ),
        ],
      ),
    );
  }

  // ── Camera area ───────────────────────────────────────────────────────────

  Widget _buildCameraArea() {
    // Loading state
    if (_initError.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: _kRed, size: 48),
              const SizedBox(height: 16),
              Text(
                'Initialisation Error',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _initError,
                style: GoogleFonts.inter(color: Colors.white60, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (!_camReady || _cam == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: _kGold),
            const SizedBox(height: 16),
            Text(
              'Initialising camera & model…',
              style: GoogleFonts.inter(color: Colors.white60),
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        CameraPreview(_cam!),

        // Face bounding box overlay
        if (_faces.isNotEmpty && _imageSize != Size.zero)
          Positioned.fill(
            child: CustomPaint(
              painter: _FaceOverlayPainter(
                faces: _faces,
                imageSize: _imageSize,
                name: _identifiedName,
                confidence: _confidence,
                isSaving: _isSaving,
              ),
            ),
          ),

        // Save-mode instruction card
        if (_isSaving && _saveStep >= 0)
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: _buildSaveInstructionCard(),
          ),

        // Listening badge
        if (isMixinListening)
          Positioned(
            top: _isSaving ? 100 : 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mic, color: _kGold, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    'Listening…',
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Identified name overlay at the bottom of the camera preview
        if (_identifiedName.isNotEmpty && _faces.isNotEmpty && !_isSaving)
          Positioned(
            bottom: 12,
            left: 20,
            right: 20,
            child: _buildNameOverlay(),
          ),
      ],
    );
  }

  // ── Save instruction card ─────────────────────────────────────────────────

  Widget _buildSaveInstructionCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kGold.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Step label
          Text(
            'Step ${_saveStep + 1} / ${_kPoses.length}',
            style: GoogleFonts.inter(
              color: _kGold,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          // Instruction
          Text(
            _kPoses[_saveStep].$2,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          // Progress dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_kPoses.length, (i) {
              final captured = i < _capturedEmbeddings.length;
              final current = i == _saveStep;
              return Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: captured
                      ? _kGreen
                      : current
                          ? _kGold
                          : Colors.white24,
                  border: current
                      ? Border.all(color: _kGold, width: 2)
                      : null,
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ── Name overlay ──────────────────────────────────────────────────────────

  Widget _buildNameOverlay() {
    final isKnown = _identifiedName != 'Unknown';
    final color = isKnown ? _kGreen : _kRed;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
              color: color.withValues(alpha: 0.2), blurRadius: 12, spreadRadius: 1),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isKnown ? Icons.check_circle : Icons.help_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              isKnown
                  ? '$_identifiedName  •  ${(_confidence * 100).toStringAsFixed(1)}%'
                  : 'Unknown Person',
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom panel ──────────────────────────────────────────────────────────

  Widget _buildBottomPanel() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kCardBorder),
            ),
            child: Text(
              _status,
              style: GoogleFonts.inter(
                color: _isSaving ? _kGold : Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Action buttons
          if (_isSaving) ...[
            // Cancel save button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _cancelSave,
                icon: const Icon(Icons.close, size: 20),
                label: Text(
                  'Cancel Enrollment',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kRed.withValues(alpha: 0.15),
                  foregroundColor: _kRed,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: _kRed.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            ),
          ] else ...[
            Row(
              children: [
                // Speak name button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      if (_identifiedName.isNotEmpty &&
                          _identifiedName != 'Unknown') {
                        _tts.speak('This is $_identifiedName.');
                      } else {
                        _tts.speak('Unknown person.');
                      }
                    },
                    icon: const Icon(Icons.volume_up, size: 20),
                    label: Text(
                      'Speak',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kSurface,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: _kCardBorder),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Save face button
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: (_identifiedName == 'Unknown' &&
                            _faces.isNotEmpty)
                        ? _startSaveFlow
                        : null,
                    icon: const Icon(Icons.person_add_alt_1, size: 22),
                    label: Text(
                      'Save Face',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kGold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.grey[800],
                      disabledForegroundColor: Colors.grey[600],
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Face overlay painter
// ═══════════════════════════════════════════════════════════════════════════════

class _FaceOverlayPainter extends CustomPainter {
  final List<Face> faces;
  final Size imageSize;
  final String name;
  final double confidence;
  final bool isSaving;

  const _FaceOverlayPainter({
    required this.faces,
    required this.imageSize,
    required this.name,
    required this.confidence,
    required this.isSaving,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (faces.isEmpty || imageSize == Size.zero) return;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final face in faces) {
      final bbox = face.boundingBox;
      final rect = Rect.fromLTRB(
        bbox.left * scaleX,
        bbox.top * scaleY,
        bbox.right * scaleX,
        bbox.bottom * scaleY,
      );

      final color = isSaving
          ? _kGold
          : (name == 'Unknown' ? _kRed : _kGreen);

      // ── Glow ────────────────────────────────────────────────────────────
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 16);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(12)),
        glowPaint,
      );

      // ── Border ──────────────────────────────────────────────────────────
      final borderPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(12)),
        borderPaint,
      );

      // ── Corner accents ──────────────────────────────────────────────────
      _drawCorners(canvas, rect, color);

      // ── Name label above face box ───────────────────────────────────────
      if (!isSaving && name.isNotEmpty) {
        final label = name == 'Unknown'
            ? ' Unknown '
            : ' $name ${(confidence * 100).toStringAsFixed(0)}% ';

        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: name == 'Unknown' ? Colors.white : Colors.black,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              background: Paint()..color = color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final yPos =
            rect.top > tp.height + 8 ? rect.top - tp.height - 6 : rect.bottom + 4;
        tp.paint(canvas, Offset(rect.left, yPos));
      }
    }
  }

  void _drawCorners(Canvas canvas, Rect r, Color color) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;
    const l = 20.0;

    // Top-left
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(l, 0), p);
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(0, l), p);
    // Top-right
    canvas.drawLine(r.topRight, r.topRight + const Offset(-l, 0), p);
    canvas.drawLine(r.topRight, r.topRight + const Offset(0, l), p);
    // Bottom-left
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(l, 0), p);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(0, -l), p);
    // Bottom-right
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(-l, 0), p);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(0, -l), p);
  }

  @override
  bool shouldRepaint(covariant _FaceOverlayPainter old) =>
      old.faces != faces ||
      old.name != name ||
      old.confidence != confidence ||
      old.isSaving != isSaving;
}
