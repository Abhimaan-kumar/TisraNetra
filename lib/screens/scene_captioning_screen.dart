import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../services/scene_captioning_service.dart';
import '../../services/tts_service.dart';

class SceneCaptioningScreen extends StatefulWidget {
  const SceneCaptioningScreen({super.key});

  @override
  State<SceneCaptioningScreen> createState() => _SceneCaptioningScreenState();
}

class _SceneCaptioningScreenState extends State<SceneCaptioningScreen>
    with WidgetsBindingObserver {
  final SceneCaptioningService _service = SceneCaptioningService();
  final TtsService _ttsService = TtsService();

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;

  SceneCaptioningResult? _lastResult;
  SceneCaptioningResult? _previousResult;

  bool _isCapturing = false;
  bool _isScanning = false;
  bool _isSpeaking = false;
  bool _shouldKeepScanning = false;

  String _statusMessage = 'Initializing camera...';
  int _scanCount = 0;
  int _successCount = 0;
  int _sameSceneCaptioningCount = 0;

  // ── Lifecycle ───────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
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
    _ttsService.dispose();
    super.dispose();
  }

  // ── Camera ──────────────────────────────────────────────────
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
        _statusMessage = 'Ready — scanning your surroundings';
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        _ttsService.speak(
            'Scene captioning ready. I will describe what is in front of you.');
        _startScanning();
      }
    } catch (e) {
      setState(() => _statusMessage = 'Camera failed: $e');
    }
  }

  // ── Scan Control ────────────────────────────────────────────
  void _toggleScanning() =>
      _isScanning ? _stopScanning() : _startScanning();

  void _startScanning() {
    if (_isScanning) return;
    _sameSceneCaptioningCount = 0;
    _previousResult = null;
    setState(() {
      _isScanning = true;
      _shouldKeepScanning = true;
      _statusMessage = 'Scanning scene...';
    });
    _ttsService.speak('Scene scanning started.');
    _scanLoop();
  }

  void _stopScanning() {
    setState(() {
      _isScanning = false;
      _shouldKeepScanning = false;
      _statusMessage = 'Paused. Tap Resume to continue.';
    });
    _ttsService.speak('Scanning paused.');
  }

  Future<void> _scanLoop() async {
    while (_shouldKeepScanning && mounted) {
      await _captureAndDescribe();
      if (_shouldKeepScanning && mounted) {
        // ✅ 8 seconds between scans to stay under free quota
        await Future.delayed(const Duration(seconds: 8));
      }
    }
  }

  // ── Capture & Describe ──────────────────────────────────────
  Future<void> _captureAndDescribe() async {
    if (_isCapturing || !_isCameraReady || _cameraController == null)
      return;
    if (!mounted) return;

    _scanCount++;
    setState(() {
      _isCapturing = true;
      _statusMessage = 'Scan #$_scanCount — reading SceneCaptioning...';
    });

    try {
      final photo = await _cameraController!.takePicture();
      final bytes = await photo.readAsBytes();
      print('📷 Image: ${bytes.length} bytes');

      final result = await _service.captureSceneCaptioning(bytes);

      if (!mounted) return;

      if (result != null && result.caption.isNotEmpty) {
        _successCount++;
        final changed = !result.isSimilarTo(_previousResult);

        setState(() {
          _previousResult = _lastResult;
          _lastResult = result;
        });

        if (changed) {
          _sameSceneCaptioningCount = 0;
          setState(() =>
              _statusMessage = '🎬 #$_scanCount: ${result.environment}');
          setState(() => _isSpeaking = true);
          await _ttsService.speak(result.caption);
          if (mounted) setState(() => _isSpeaking = false);
        } else {
          _sameSceneCaptioningCount++;
          setState(() =>
              _statusMessage = '↺ #$_scanCount: Same SceneCaptioning');
          // Re-confirm every 4 same scans
          if (_sameSceneCaptioningCount % 4 == 0) {
            setState(() => _isSpeaking = true);
            await _ttsService.speak(
                'SceneCaptioning unchanged. ${result.caption}');
            if (mounted) setState(() => _isSpeaking = false);
          }
        }
      } else {
        setState(() =>
            _statusMessage = 'Scan #$_scanCount: Retrying...');
        print('Null result');
      }
    } catch (e) {
      print('Error: $e');
      if (!mounted) return;

      final msg = e.toString().toLowerCase();

      if (msg.contains('api key') || msg.contains('key not valid')) {
        setState(() => _statusMessage = 'Invalid API key');
        await _ttsService.speak('API key is invalid.');
        _stopScanning();
      } else if (msg.contains('quota') || msg.contains('exhausted') ||
          msg.contains('rate') || msg.contains('limit') ||
          msg.contains('429')) {
        final retryMatch =
            RegExp(r'retry in (\d+)').firstMatch(e.toString());
        final retrySeconds =
            int.tryParse(retryMatch?.group(1) ?? '60') ?? 60;
        setState(() => _statusMessage =
            'Quota hit — waiting ${retrySeconds}s...');
        await _ttsService.speak(
            'Quota reached. Waiting $retrySeconds seconds then resuming.');
        await Future.delayed(Duration(seconds: retrySeconds + 2));
        if (mounted) {
          setState(() => _statusMessage = 'Resuming...');
          await _ttsService.speak('Resuming scene captioning.');
        }
      } else {
        setState(
            () => _statusMessage = 'Error — retrying in 5s...');
        await Future.delayed(const Duration(seconds: 5));
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  // ── Repeat ──────────────────────────────────────────────────
  Future<void> _repeatResult() async {
    if (_lastResult == null) {
      await _ttsService.speak('No scene described yet.');
      return;
    }
    await _ttsService.speak(_lastResult!.caption);
  }

  // ── Build ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _appBar(),
      body: Column(
        children: [
          Expanded(flex: 3, child: _cameraView()),
          _statusBar(),
          _scenePanel(),
          _controls(),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar() => AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Scene',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            Text(
              'Scans: $_scanCount  |  Success: $_successCount',
              style: const TextStyle(
                  color: Colors.white54, fontSize: 11),
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
                color: _isSpeaking ? Colors.green : Colors.white),
            onPressed: _repeatResult,
            tooltip: 'Repeat scene',
          ),
        ],
      );

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

      // Scanning overlay border
      if (_isScanning) _ScanBorder(),

      // Environment badge top-left
      if (_lastResult != null)
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: Colors.greenAccent.withOpacity(0.6)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.place,
                  color: Colors.greenAccent, size: 13),
              const SizedBox(width: 5),
              Text(
                _lastResult!.environment,
                style: const TextStyle(
                    color: Colors.white, fontSize: 12),
              ),
            ]),
          ),
        ),

      // Capturing indicator bottom center
      if (_isCapturing)
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
                border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.5)),
              ),
              child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          color: Colors.greenAccent, strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Reading scene...',
                        style: TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ]),
            ),
          ),
        ),

      // Speaking indicator top-right
      if (_isSpeaking)
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20)),
            child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.volume_up,
                      color: Colors.white, size: 14),
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

  Widget _statusBar() => Container(
        width: double.infinity,
        color: Colors.grey[900],
        padding:
            const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Row(children: [
          if (_isScanning) _PulseDot(color: Colors.greenAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                  color: _isScanning
                      ? Colors.greenAccent
                      : Colors.white60,
                  fontSize: 12),
            ),
          ),
        ]),
      );

  Widget _scenePanel() {
    if (_lastResult == null) {
      return Container(
        height: 110,
        color: Colors.grey[850],
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera_outlined,
                  color: Colors.white30, size: 28),
              SizedBox(height: 6),
              Text(
                'Point camera at your surroundings\nto get a scene description',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final r = _lastResult!;
    return Container(
      constraints: const BoxConstraints(minHeight: 110),
      color: Colors.grey[850],
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Environment tag
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.greenAccent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Colors.greenAccent.withOpacity(0.4)),
            ),
            child: Text(
              r.environment.toUpperCase(),
              style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0),
            ),
          ),
          const SizedBox(height: 8),
          // Caption text
          Text(
            r.caption,
            style: const TextStyle(
                color: Colors.white, fontSize: 14, height: 1.5),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (_sameSceneCaptioningCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              'SceneCaptioning unchanged for $_sameSceneCaptioningCount scan${_sameSceneCaptioningCount == 1 ? '' : 's'}',
              style: const TextStyle(
                  color: Colors.white30, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

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
                  size: 26),
              label: Text(_isScanning ? 'Pause' : 'Resume',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isScanning
                    ? Colors.orange
                    : Colors.greenAccent,
                foregroundColor: Colors.black,
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
              label: const Text('Repeat',
                  style: TextStyle(fontSize: 15)),
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

// ── Scan border ────────────────────────────────────────────────
class _ScanBorder extends StatefulWidget {
  @override
  State<_ScanBorder> createState() => _ScanBorderState();
}

class _ScanBorderState extends State<_ScanBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))
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
                  color: Colors.greenAccent.withOpacity(_a.value),
                  width: 2.5))));
}

// ── Pulse dot ──────────────────────────────────────────────────
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
              color: widget.color
                  .withOpacity(0.4 + 0.6 * _c.value))));
}