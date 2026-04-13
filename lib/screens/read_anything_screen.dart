import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../services/read_anything_service.dart';
import '../../services/tts_service.dart';
// Note: dart:typed_data kept for Laplacian sharpness analyser (Uint8List).

// ─────────────────────────────────────────────────────────────────────────────
// Sharpness analyser (Laplacian variance, runs on a small downscaled crop)
// Returns a value 0–∞. Higher = sharper. Threshold ~120 works well in practice.
// ─────────────────────────────────────────────────────────────────────────────

double _laplacianVariance(Uint8List jpegBytes) {
  try {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) return 0;

    // Downscale for speed
    final small = img.copyResize(decoded, width: 200);
    final w = small.width;
    final h = small.height;

    // Convert to grayscale luma values
    final gray = List.generate(
    h,
    (y) => List.generate(w, (x) {
    final pixel = small.getPixel(x, y);
    return (pixel.r * 0.299 +
            pixel.g * 0.587 +
            pixel.b * 0.114)
        .toDouble();
  }),
);

    // Apply 3×3 Laplacian kernel and collect squared responses
    double sumSq = 0;
    int count = 0;
    const kernel = [
      [0, 1, 0],
      [1, -4, 1],
      [0, 1, 0],
    ];
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        double v = 0;
        for (int ky = 0; ky < 3; ky++) {
          for (int kx = 0; kx < 3; kx++) {
            v += kernel[ky][kx] * gray[y + ky - 1][x + kx - 1];
          }
        }
        sumSq += v * v;
        count++;
      }
    }
    return count == 0 ? 0 : sumSq / count;
  } catch (_) {
    return 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class ReadAnythingScreen extends StatefulWidget {
  const ReadAnythingScreen({super.key});

  @override
  State<ReadAnythingScreen> createState() => _ReadAnythingScreenState();
}

class _ReadAnythingScreenState extends State<ReadAnythingScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Services ────────────────────────────────────────────────────────────
  final ReadAnythingService _service = ReadAnythingService();
  final TtsService _ttsService = TtsService();

  // ── Camera ──────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _isCameraReady = false;

  // ── State machine ────────────────────────────────────────────────────────
  _ScanState _state = _ScanState.idle;
  String _statusMessage = 'Point camera at text';
  String _sharpnessLabel = '';

  // Sharpness tracking
  double _currentSharpness = 0;
  int _stableSharpFrames = 0;     // consecutive frames above threshold
  static const int _stableRequired = 3;    // frames needed before capture
  static const double _sharpThreshold = 120.0;

  // Scanning loop timer
  Timer? _scanTimer;

  // Result
  String _extractedText = '';
  List<TextSegment> _extractedSegments = [];
  bool _isSpeaking = false;
  int _captureCount = 0;

  // ── Voice commands ───────────────────────────────────────────────────────
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _voiceStatus = '';

  // Sharpness bar animation
  late final AnimationController _sharpAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  // ── Theme ────────────────────────────────────────────────────────────────
  static const _green  = Color(0xFF00E676);
  static const _amber  = Color(0xFFFFD740);
  static const _cyan   = Color(0xFF18FFFF);
  static const _dimBg  = Color(0xCC000000);

  // ══════════════════════════════════════════════════════════════════════════
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _initSpeech();
    _ttsService.speak(
      'Read text screen. Point your camera at any text and I will read it for you automatically.',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _stopScanning();
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopScanning();
    _cameraController?.dispose();
    _sharpAnim.dispose();
    _ttsService.dispose();
    _service.dispose(); // closes ML Kit TextRecognizer
    _speech.cancel();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Camera init
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setStatus('No camera found');
        return;
      }

      final ctrl = CameraController(
        cameras.first,
        ResolutionPreset.high,   // high res = better OCR accuracy
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFlashMode(FlashMode.off);

      if (!mounted) return;
      setState(() {
        _cameraController = ctrl;
        _isCameraReady = true;
      });

      _startScanning();
    } catch (e) {
      _setStatus('Camera error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Scanning loop — checks sharpness every 400 ms
  // ══════════════════════════════════════════════════════════════════════════

  void _startScanning() {
    if (_state == _ScanState.reading) return; // don't interrupt TTS
    _setState(_ScanState.scanning);
    _stableSharpFrames = 0;
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      _checkFrame();
    });
  }

  void _stopScanning() {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  Future<void> _checkFrame() async {
    if (_cameraController == null || !_isCameraReady) return;
    if (_state != _ScanState.scanning) return;

    try {
      final photo = await _cameraController!.takePicture();
      // Load bytes only for the lightweight sharpness check
      final bytes = await photo.readAsBytes();

      // Run sharpness in background (isolate-friendly microtask)
      final sharpness = await Future.microtask(() => _laplacianVariance(bytes));

      if (!mounted) return;

      setState(() {
        _currentSharpness = sharpness;
        _sharpnessLabel = sharpness >= _sharpThreshold ? 'Sharp ✓' : 'Hold steady...';
      });

      _sharpAnim.animateTo(
        (sharpness / 400.0).clamp(0.0, 1.0),
        curve: Curves.easeOut,
      );

      if (sharpness >= _sharpThreshold) {
        _stableSharpFrames++;
        _setStatus('Sharp image — hold still ($_stableSharpFrames/$_stableRequired)');

        if (_stableSharpFrames >= _stableRequired) {
          _stopScanning();
          // Pass file path — ML Kit reads it directly, no re-encoding needed
          await _captureAndRead(photo.path);
        }
      } else {
        _stableSharpFrames = 0;
        _setStatus(
          sharpness < 30
              ? 'No text visible — point camera at text'
              : 'Move closer or hold steady',
        );
      }
    } catch (e) {
      print('Frame check error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Capture + OCR  (on-device ML Kit — ~150-300 ms, offline, no quota)
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _captureAndRead(String imagePath) async {
    _captureCount++;
    _setState(_ScanState.processing);
    _setStatus('Reading text...');

    // ML Kit runs on-device — typically done in well under a second
    // Both Latin (English) + Devanagari (Hindi) recognizers run in parallel
    final result = await _service.extractText(imagePath);

    if (!mounted) return;

    if (result.errorReason != null) {
      _setStatus('Error — resuming scan');
      print('OCR error: ${result.errorReason}');
      await Future.delayed(const Duration(seconds: 1));
      _startScanning();
      _setState(_ScanState.idle);
      return;
    }

    if (!result.hasText || result.text.isEmpty) {
      _setStatus('No text found — scanning again');
      await _ttsService.speak('No text found. Try again.');
      await Future.delayed(const Duration(seconds: 1));
      _startScanning();
      return;
    }

    // Store both the display text and the language-tagged segments
    setState(() {
      _extractedText    = result.text;
      _extractedSegments = result.segments;
    });
    _setState(_ScanState.reading);
    _setStatus('Reading aloud...');

    setState(() => _isSpeaking = true);
    // Speak each segment in its own language (en-IN for English, hi-IN for Hindi)
    await _ttsService.speakSegments(result.segments);
    if (mounted) {
      setState(() => _isSpeaking = false);
      _setState(_ScanState.done);
      _setStatus('Done — tap "Scan Again" to read more');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════════════════════════════════

  void _setState(_ScanState s) {
    if (mounted) setState(() => _state = s);
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _statusMessage = msg);
  }

  void _repeatText() {
    if (_extractedSegments.isEmpty) {
      _ttsService.speak('Nothing read yet.');
      return;
    }
    // Re-speak with correct language per segment
    _ttsService.speakSegments(_extractedSegments);
  }

  void _scanAgain() {
    _ttsService.stop();
    setState(() {
      _extractedText     = '';
      _extractedSegments = [];
      _stableSharpFrames = 0;
      _currentSharpness  = 0;
    });
    _sharpAnim.animateTo(0);
    _startScanning();
  }

  // ── Voice command helpers ────────────────────────────────────────────────

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onError: (e) {
        if (mounted) setState(() => _isListening = false);
      },
      onStatus: (status) {
        // When STT stops on its own (timeout) update the UI
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
    );
    if (mounted) setState(() => _speechEnabled = available);
  }

  Future<void> _startListening() async {
    if (!_speechEnabled || _isListening) return;
    // Stop TTS so mic picks up the user, not TTS audio
    await _ttsService.stop();
    setState(() {
      _isListening = true;
      _voiceStatus = 'Listening...';
    });

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        final words = result.recognizedWords.toLowerCase().trim();
        setState(() => _voiceStatus = words.isNotEmpty ? '"$words"' : 'Listening...');

        if (result.finalResult) {
          setState(() => _isListening = false);
          _handleVoiceCommand(words);
        }
      },
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      cancelOnError: true,
      listenMode: stt.ListenMode.confirmation,
    );
  }

  void _stopListening() {
    _speech.stop();
    if (mounted) setState(() => _isListening = false);
  }

  void _handleVoiceCommand(String words) {
    if (words.isEmpty) {
      _ttsService.speak('No command detected. Say repeat or scan again.');
      setState(() => _voiceStatus = '');
      return;
    }

    // Match "scan again" / "scan" variants
    final isScan = words.contains('scan') ||
        words.contains('scan again') ||
        words.contains('rescan') ||
        words.contains('new scan');

    // Match "repeat" variants
    final isRepeat = words.contains('repeat') ||
        words.contains('again') ||
        words.contains('replay') ||
        words.contains('read again') ||
        words.contains('read it again');

    if (isScan) {
      setState(() => _voiceStatus = '');
      _scanAgain();
    } else if (isRepeat) {
      setState(() => _voiceStatus = '');
      _repeatText();
    } else {
      _ttsService.speak('Command not recognised. Say repeat or scan again.');
      setState(() => _voiceStatus = 'Unknown: "$words"');
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
      body: Column(
        children: [
          // Camera + overlay
          Expanded(flex: 5, child: _buildCameraView()),
          // Sharpness bar
          _buildSharpnessBar(),
          // Status strip
          _buildStatusStrip(),
          // Extracted text panel
          if (_extractedText.isNotEmpty) _buildTextPanel(),
          // Controls
          _buildControls(),
        ],
      ),
    );
  }

  // ── AppBar ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() => AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Read Text',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            Text(
              'Captures: $_captureCount  |  ${_state.label}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _stopScanning();
            _ttsService.speak('Going back.');
            Navigator.pop(context);
          },
        ),
        actions: [
          if (_extractedText.isNotEmpty)
            IconButton(
              icon: Icon(Icons.volume_up,
                  color: _isSpeaking ? _cyan : Colors.white),
              onPressed: _repeatText,
              tooltip: 'Repeat',
            ),
        ],
      );

  // ── Camera view ───────────────────────────────────────────────────────────

  Widget _buildCameraView() {
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
      // Live preview
      CameraPreview(_cameraController!),

      // Scanning overlay — animated border
      if (_state == _ScanState.scanning)
        _AnimatedScanBorder(
          color: _currentSharpness >= _sharpThreshold ? _green : _amber,
        ),

      // Processing overlay — dim + spinner
      if (_state == _ScanState.processing)
        Container(
          color: Colors.black54,
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                SizedBox(height: 16),
                Text('Extracting text...',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),

      // Done overlay — checkmark
      if (_state == _ScanState.done || _state == _ScanState.reading)
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _dimBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _green.withOpacity(0.7)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _isSpeaking ? Icons.volume_up : Icons.check_circle,
                color: _green,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                _isSpeaking ? 'Reading aloud' : 'Text captured',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ),

      // Sharpness badge (top right) — only while scanning
      if (_state == _ScanState.scanning)
        Positioned(
          top: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _dimBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (_currentSharpness >= _sharpThreshold ? _green : _amber)
                    .withOpacity(0.7),
              ),
            ),
            child: Text(
              _sharpnessLabel,
              style: TextStyle(
                color: _currentSharpness >= _sharpThreshold ? _green : _amber,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),

      // Center viewfinder guide (only while scanning)
      if (_state == _ScanState.scanning)
        Center(
          child: _ViewfinderGuide(
            isSharp: _currentSharpness >= _sharpThreshold,
          ),
        ),
    ]);
  }

  // ── Sharpness bar ─────────────────────────────────────────────────────────

  Widget _buildSharpnessBar() => AnimatedBuilder(
        animation: _sharpAnim,
        builder: (_, __) {
          final v = _sharpAnim.value;
          final color = v > 0.4
              ? _green
              : v > 0.15
                  ? _amber
                  : Colors.redAccent;
          return Container(
            height: 4,
            width: double.infinity,
            color: Colors.grey[900],
            child: FractionallySizedBox(
              widthFactor: v,
              alignment: Alignment.centerLeft,
              child: Container(color: color),
            ),
          );
        },
      );

  // ── Status strip ──────────────────────────────────────────────────────────

  Widget _buildStatusStrip() => Container(
        width: double.infinity,
        color: Colors.grey[900],
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Row(children: [
          if (_state == _ScanState.scanning)
            _PulseDot(
              color: _currentSharpness >= _sharpThreshold ? _green : _amber,
            ),
          if (_state == _ScanState.processing)
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                  color: Colors.white70, strokeWidth: 2),
            ),
          if (_state == _ScanState.reading)
            const Icon(Icons.volume_up, color: Colors.white70, size: 14),
          if (_state == _ScanState.done)
            const Icon(Icons.check, color: Colors.green, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                color: _state == _ScanState.scanning
                    ? (_currentSharpness >= _sharpThreshold ? _green : _amber)
                    : Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
        ]),
      );

  // ── Extracted text panel ──────────────────────────────────────────────────

  Widget _buildTextPanel() => Container(
        constraints: const BoxConstraints(maxHeight: 180),
        color: const Color(0xFF1A1A2E),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.text_fields, color: Colors.white54, size: 14),
              const SizedBox(width: 6),
              const Text(
                'EXTRACTED TEXT',
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _repeatText,
                child: Row(children: [
                  Icon(Icons.replay,
                      color: _isSpeaking ? _cyan : Colors.white54, size: 14),
                  const SizedBox(width: 4),
                  Text('Repeat',
                      style: TextStyle(
                          color: _isSpeaking ? _cyan : Colors.white54,
                          fontSize: 11)),
                ]),
              ),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _extractedText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _buildControls() => Container(
        color: Colors.black,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Voice status banner
            if (_isListening || _voiceStatus.isNotEmpty)
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
                decoration: BoxDecoration(
                  color: _isListening
                      ? const Color(0xFF1A1A2E)
                      : Colors.grey[900],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _isListening
                        ? _cyan.withOpacity(0.7)
                        : Colors.grey[700]!,
                  ),
                ),
                child: Row(
                  children: [
                    if (_isListening)
                      _PulseDot(color: _cyan)
                    else
                      const Icon(Icons.info_outline,
                          color: Colors.white54, size: 12),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isListening
                            ? (_voiceStatus.isEmpty
                                ? 'Listening for command...'
                                : _voiceStatus)
                            : _voiceStatus,
                        style: TextStyle(
                          color: _isListening ? _cyan : Colors.white54,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                    if (_isListening)
                      GestureDetector(
                        onTap: _stopListening,
                        child: const Icon(Icons.close,
                            color: Colors.white54, size: 16),
                      ),
                  ],
                ),
              ),
            Row(children: [
              // Scan Again / Stop
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _isCameraReady
                      ? (_state == _ScanState.scanning
                          ? _stopScanning
                          : _scanAgain)
                      : null,
                  icon: Icon(
                    _state == _ScanState.scanning
                        ? Icons.stop_circle_outlined
                        : Icons.document_scanner_outlined,
                    size: 22,
                  ),
                  label: Text(
                    _state == _ScanState.scanning ? 'Stop' : 'Scan Again',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _state == _ScanState.scanning ? Colors.orange : _cyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Repeat button
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _extractedText.isNotEmpty ? _repeatText : null,
                  icon: Icon(
                    _isSpeaking ? Icons.volume_up : Icons.replay,
                    size: 20,
                  ),
                  label: const Text('Repeat', style: TextStyle(fontSize: 14)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[800],
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[900],
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Mic / voice-command button
              SizedBox(
                width: 58,
                height: 54,
                child: Tooltip(
                  message: _speechEnabled
                      ? (_isListening
                          ? 'Tap to stop listening'
                          : 'Say "scan again" or "repeat"')
                      : 'Microphone unavailable',
                  child: ElevatedButton(
                    onPressed: _speechEnabled
                        ? (_isListening ? _stopListening : _startListening)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isListening
                          ? _cyan.withOpacity(0.2)
                          : Colors.grey[850],
                      foregroundColor:
                          _isListening ? _cyan : Colors.white,
                      disabledBackgroundColor: Colors.grey[900],
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: _isListening
                                ? _cyan
                                : Colors.grey[700]!,
                            width: 1.5,
                          )),
                    ),
                    child: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      size: 24,
                      color: _isListening ? _cyan : Colors.white70,
                    ),
                  ),
                ),
              ),
            ]),
          ],
        ),
      );
}

// ═════════════════════════════════════════════════════════════════════════════
// State enum
// ═════════════════════════════════════════════════════════════════════════════

enum _ScanState {
  idle,
  scanning,
  processing,
  reading,
  done;

  String get label => switch (this) {
        _ScanState.idle       => 'Idle',
        _ScanState.scanning   => 'Scanning',
        _ScanState.processing => 'Processing',
        _ScanState.reading    => 'Reading',
        _ScanState.done       => 'Done',
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// Viewfinder guide — corners that turn green when sharp
// ═════════════════════════════════════════════════════════════════════════════

class _ViewfinderGuide extends StatelessWidget {
  final bool isSharp;
  const _ViewfinderGuide({required this.isSharp});

  @override
  Widget build(BuildContext context) {
    final color = isSharp ? const Color(0xFF00E676) : const Color(0xFFFFD740);
    const size = 220.0;
    const len  = 28.0;
    const stroke = 3.0;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CornerPainter(color: color, len: len, stroke: stroke),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  final double len;
  final double stroke;
  const _CornerPainter(
      {required this.color, required this.len, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final tl = Offset.zero;
    final tr = Offset(size.width, 0);
    final bl = Offset(0, size.height);
    final br = Offset(size.width, size.height);

    // Top-left
    canvas.drawLine(tl, tl + Offset(len, 0), p);
    canvas.drawLine(tl, tl + Offset(0, len), p);
    // Top-right
    canvas.drawLine(tr, tr + Offset(-len, 0), p);
    canvas.drawLine(tr, tr + Offset(0, len), p);
    // Bottom-left
    canvas.drawLine(bl, bl + Offset(len, 0), p);
    canvas.drawLine(bl, bl + Offset(0, -len), p);
    // Bottom-right
    canvas.drawLine(br, br + Offset(-len, 0), p);
    canvas.drawLine(br, br + Offset(0, -len), p);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════════════
// Animated scan border (pulses around the whole camera view)
// ═════════════════════════════════════════════════════════════════════════════

class _AnimatedScanBorder extends StatefulWidget {
  final Color color;
  const _AnimatedScanBorder({required this.color});

  @override
  State<_AnimatedScanBorder> createState() => _AnimatedScanBorderState();
}

class _AnimatedScanBorderState extends State<_AnimatedScanBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  late final Animation<double> _a =
      Tween<double>(begin: 0.3, end: 0.9).animate(_c);

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (_, __) => IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.color.withOpacity(_a.value),
                width: 2.5,
              ),
            ),
          ),
        ),
      );
}

// ═════════════════════════════════════════════════════════════════════════════
// Pulse dot
// ═════════════════════════════════════════════════════════════════════════════

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
  void dispose() { _c.dispose(); super.dispose(); }

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