import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../services/object_recognition_service.dart';
import '../../services/tts_service.dart';

class ObjectRecognitionScreen extends StatefulWidget {
  const ObjectRecognitionScreen({super.key});

  @override
  State<ObjectRecognitionScreen> createState() =>
      _ObjectRecognitionScreenState();
}

class _ObjectRecognitionScreenState extends State<ObjectRecognitionScreen>
    with WidgetsBindingObserver {
  final ObjectRecognitionService _service = ObjectRecognitionService();
  final TtsService _ttsService = TtsService();

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;

  ObjectRecognitionResult? _lastResult;
  ObjectRecognitionResult? _previousResult;

  bool _isRecognizing = false;
  bool _isScanning = false;
  bool _isSpeaking = false;
  bool _shouldKeepScanning = false;

  String _statusMessage = 'Initializing...';
  int _scanCount = 0;
  int _successCount = 0;

  // ── API key constant — same as in service ──────────────────
  static const _apiKey = 'REDACTED_PRIVATE_API_KEY';

  @override
  void initState() {
    super.initState();
    _debugListModels();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _ttsService.speak(
    'Object recognition screen. Tap the start button to begin recognizing objects around you.',
  );
  }

  // ── Debug: list models available for your API key ──────────
  Future<void> _debugListModels() async {
    try {
      final res = await http.get(Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models?key=$_apiKey',
      ));
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body);
        final models = (json['models'] as List?) ?? [];
        print('========== AVAILABLE MODELS ==========');
        for (final m in models) {
          final name = m['name'];
          final methods = m['supportedGenerationMethods'];
          if (methods != null &&
              (methods as List).contains('generateContent')) {
            print('$name');
          }
        }
        print('======================================');
      } else {
        print('ListModels failed: ${res.statusCode} — ${res.body}');
      }
    } catch (e) {
      print('ListModels error: $e');
    }
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
      ResolutionPreset.low, // small image = fast upload
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      if (!mounted) return;
      setState(() {
        _cameraController = ctrl;
        _isCameraReady = true;
        _statusMessage = 'Ready — starting...';
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _startScanning();
    } catch (e) {
      setState(() => _statusMessage = 'Camera failed: $e');
    }
  }

  void _toggleScanning() =>
      _isScanning ? _stopScanning() : _startScanning();

  void _startScanning() {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _shouldKeepScanning = true;
      _statusMessage = 'Scanning...';
    });
    _ttsService.speak('Scanning started.');
    _scanLoop();
  }

  void _stopScanning() {
    setState(() {
      _isScanning = false;
      _shouldKeepScanning = false;
      _statusMessage = 'Paused.';
    });
    _ttsService.speak('Scanning paused.');
  }

  Future<void> _scanLoop() async {
    while (_shouldKeepScanning && mounted) {
      await _captureAndRecognize();
      if (_shouldKeepScanning && mounted) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _captureAndRecognize() async {
    if (_isRecognizing || !_isCameraReady || _cameraController == null) return;
    if (!mounted) return;

    _scanCount++;
    setState(() {
      _isRecognizing = true;
      _statusMessage = 'Scan #$_scanCount — analyzing...';
    });

    try {
      final photo = await _cameraController!.takePicture();
      final bytes = await photo.readAsBytes();
      print('Image: ${bytes.length} bytes');

      final result = await _service.recognizeObjects(bytes);

      if (!mounted) return;

      if (result != null && result.description.isNotEmpty) {
        _successCount++;
        final isNew = !result.isSimilarTo(_previousResult);

        setState(() {
          _previousResult = _lastResult;
          _lastResult = result;
          _statusMessage = isNew
              ? '✓ Scan #$_scanCount: ${result.objects.length} object(s)'
              : '↺ Scene unchanged (#$_scanCount)';
        });

        if (isNew || _successCount == 1) {
          setState(() => _isSpeaking = true);
          await _ttsService.speak(result.description);
          if (mounted) setState(() => _isSpeaking = false);
        }
      } else {
        setState(() =>
            _statusMessage = 'Scan #$_scanCount: No result, retrying...');
      }
    } catch (e) {
      print('Error: $e');
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      if (msg.contains('api key') || msg.contains('key not valid')) {
        setState(() => _statusMessage = 'Invalid API key');
        await _ttsService.speak('API key is invalid.');
        _stopScanning();
      } else if (msg.contains('quota') || msg.contains('exhausted')) {
        setState(() => _statusMessage = 'Quota exceeded');
        await _ttsService.speak('API quota reached. Try again later.');
        _stopScanning();
      } else if (msg.contains('socket') || msg.contains('network')) {
        setState(() => _statusMessage = 'No internet');
        await _ttsService.speak('No internet connection.');
        _stopScanning();
      } else {
        setState(() => _statusMessage = 'Retrying in 5s... ($e)');
        await Future.delayed(const Duration(seconds: 5));
      }
    } finally {
      if (mounted) setState(() => _isRecognizing = false);
    }
  }

  Future<void> _repeatResult() async {
    if (_lastResult == null) {
      await _ttsService.speak('Nothing detected yet.');
      return;
    }
    await _ttsService.speak(_lastResult!.description);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _appBar(),
      body: Column(
        children: [
          Expanded(flex: 3, child: _cameraView()),
          _statusBar(),
          if (_lastResult != null) _resultPanel(),
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
            const Text('Object Recognition',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            Text(
              'Scans: $_scanCount  |  Success: $_successCount',
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
                color: _isSpeaking ? Colors.cyanAccent : Colors.white),
            onPressed: _repeatResult,
            tooltip: 'Repeat',
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
      ));
    }
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_cameraController!),
      if (_isScanning) _ScanBorder(),
      if (_isRecognizing)
        Positioned(
          bottom: 14,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                      color: Colors.cyanAccent.withOpacity(0.5))),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        color: Colors.cyanAccent, strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Recognizing...',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ]),
            ),
          ),
        ),
      if (_lastResult != null)
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: Colors.cyanAccent.withOpacity(0.5))),
            child: Text(_lastResult!.objects.take(3).join(', '),
                style:
                    const TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ),
      if (_isSpeaking)
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.volume_up, color: Colors.white, size: 12),
              SizedBox(width: 4),
              Text('Speaking',
                  style: TextStyle(color: Colors.white, fontSize: 11)),
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
          if (_isScanning) _PulseDot(color: Colors.cyanAccent),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_statusMessage,
                  style: TextStyle(
                      color:
                          _isScanning ? Colors.cyanAccent : Colors.white60,
                      fontSize: 12))),
        ]),
      );

  Widget _resultPanel() {
    final r = _lastResult!;
    return Container(
      constraints: const BoxConstraints(maxHeight: 110),
      color: Colors.grey[850],
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r.description,
            style: const TextStyle(
                color: Colors.white, fontSize: 14, height: 1.4),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        if (r.objects.isNotEmpty) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: r.objects.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.cyanAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: Colors.cyanAccent.withOpacity(0.4))),
                child: Text(r.objects[i],
                    style: const TextStyle(
                        color: Colors.cyanAccent, fontSize: 11)),
              ),
            ),
          ),
        ]
      ]),
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
                  backgroundColor:
                      _isScanning ? Colors.orange : Colors.cyanAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
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
                      borderRadius: BorderRadius.circular(14))),
            ),
          ),
        ]),
      );
}

// ── Animated helpers ───────────────────────────────────────────

class _ScanBorder extends StatefulWidget {
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
                  color: Colors.cyanAccent.withOpacity(_a.value),
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