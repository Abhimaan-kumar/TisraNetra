import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../services/color_service.dart';
import '../../services/tts_service.dart';

class ColorScreen extends StatefulWidget {
  const ColorScreen({super.key});

  @override
  State<ColorScreen> createState() => _ColorScreenState();
}

class _ColorScreenState extends State<ColorScreen>
    with WidgetsBindingObserver {
  final ColorService _service = ColorService();
  final TtsService _ttsService = TtsService();

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;

  ColorResult? _lastResult;
  ColorResult? _previousResult;

  bool _isIdentifying = false;
  bool _isScanning = false;
  bool _isSpeaking = false;
  bool _shouldKeepScanning = false;

  String _statusMessage = 'Initializing camera...';
  int _scanCount = 0;
  int _successCount = 0;
  int _sameColorCount = 0;

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
        _statusMessage = 'Ready — point camera at any object';
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        _ttsService.speak(
            'Color detection ready. Point the camera at any object to hear its color.');
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
    _sameColorCount = 0;
    _previousResult = null; // force speak on first result
    setState(() {
      _isScanning = true;
      _shouldKeepScanning = true;
      _statusMessage = 'Scanning for colors...';
    });
    _ttsService.speak('Color scanning started.');
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
      await _captureAndIdentify();
      if (_shouldKeepScanning && mounted) {
        //  8 seconds between scans = ~7/min, under 20/min free limit
        await Future.delayed(const Duration(seconds: 8));
      }
    }
  }

  // ── Color Change Detection ──────────────────────────────────
  String _extractBaseColor(String color) {
    const baseColors = [
      'red', 'orange', 'yellow', 'green', 'blue', 'purple',
      'pink', 'brown', 'black', 'white', 'grey', 'gray',
      'beige', 'gold', 'silver', 'teal', 'navy', 'maroon',
      'olive', 'cyan', 'coral', 'cream', 'indigo', 'violet',
    ];
    final lower = color.toLowerCase();
    for (final base in baseColors) {
      if (lower.contains(base)) return base;
    }
    return lower;
  }

  bool _isColorChanged(ColorResult? previous, ColorResult? current) {
    if (previous == null || current == null) return true;

    final prevBase = _extractBaseColor(previous.dominantColor);
    final currBase = _extractBaseColor(current.dominantColor);

    print('🔍 Compare: "$prevBase" vs "$currBase"');

    // Different base color family → changed
    if (prevBase != currBase) return true;

    // Same base — check shade changed
    final prevFull = previous.dominantColor.toLowerCase();
    final currFull = current.dominantColor.toLowerCase();

    if (prevFull != currFull) {
      const darkShades = ['dark', 'deep', 'navy', 'charcoal'];
      const lightShades = ['light', 'pale', 'bright', 'neon'];
      final prevIsDark = darkShades.any((s) => prevFull.contains(s));
      final currIsDark = darkShades.any((s) => currFull.contains(s));
      final prevIsLight =
          lightShades.any((s) => prevFull.contains(s));
      final currIsLight =
          lightShades.any((s) => currFull.contains(s));
      if (prevIsDark != currIsDark || prevIsLight != currIsLight) {
        return true;
      }
    }

    return false;
  }

  // ── Capture & Identify ──────────────────────────────────────
  Future<void> _captureAndIdentify() async {
    if (_isIdentifying || !_isCameraReady || _cameraController == null)
      return;
    if (!mounted) return;

    _scanCount++;
    setState(() {
      _isIdentifying = true;
      _statusMessage = 'Scan #$_scanCount — detecting...';
    });

    try {
      final photo = await _cameraController!.takePicture();
      final bytes = await photo.readAsBytes();
      print('📷 Image: ${bytes.length} bytes');

      final result = await _service.identifyColor(bytes);

      if (!mounted) return;

      if (result != null && result.dominantColor.isNotEmpty) {
        _successCount++;
        final changed = _isColorChanged(_previousResult, result);

        setState(() {
          _previousResult = _lastResult;
          _lastResult = result;
        });

        if (changed) {
          _sameColorCount = 0;
          setState(() => _statusMessage =
              '🎨 #$_scanCount: ${result.dominantColor}');
          setState(() => _isSpeaking = true);
          await _ttsService.speak(result.description);
          if (mounted) setState(() => _isSpeaking = false);
        } else {
          _sameColorCount++;
          setState(() => _statusMessage =
              '↺ #$_scanCount: Still ${result.dominantColor}');
          // Re-confirm every 5 same scans
          if (_sameColorCount % 5 == 0) {
            setState(() => _isSpeaking = true);
            await _ttsService.speak('Still ${result.description}');
            if (mounted) setState(() => _isSpeaking = false);
          }
        }
      } else {
        setState(() =>
            _statusMessage = 'Scan #$_scanCount: Retrying...');
        print('⚠️ Null/invalid result — skip');
      }
    } catch (e) {
      print('💥 Error: $e');
      if (!mounted) return;

      final msg = e.toString().toLowerCase();

      if (msg.contains('api key') || msg.contains('key not valid')) {
        setState(() => _statusMessage = '❌ Invalid API key');
        await _ttsService.speak('API key is invalid.');
        _stopScanning();
      } else if (msg.contains('quota') || msg.contains('exhausted') ||
          msg.contains('rate') || msg.contains('limit') ||
          msg.contains('429')) {
        // ✅ Extract retry seconds from error and wait exactly that
        final retryMatch =
            RegExp(r'retry in (\d+)').firstMatch(e.toString());
        final retrySeconds =
            int.tryParse(retryMatch?.group(1) ?? '60') ?? 60;

        setState(() => _statusMessage =
            '⏳ Quota hit — waiting ${retrySeconds}s...');
        await _ttsService.speak(
            'Quota reached. Waiting $retrySeconds seconds then resuming.');

        await Future.delayed(Duration(seconds: retrySeconds + 2));

        if (mounted) {
          setState(() => _statusMessage = 'Resuming...');
          await _ttsService.speak('Resuming color detection.');
        }
      } else {
        setState(
            () => _statusMessage = 'Error — retrying in 5s...');
        await Future.delayed(const Duration(seconds: 5));
      }
    } finally {
      if (mounted) setState(() => _isIdentifying = false);
    }
  }

  // ── Repeat ──────────────────────────────────────────────────
  Future<void> _repeatResult() async {
    if (_lastResult == null) {
      await _ttsService.speak('No color detected yet.');
      return;
    }
    await _ttsService.speak(_lastResult!.description);
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
          _colorPanel(),
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
            const Text('Color',
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
                color: _isSpeaking ? Colors.amber : Colors.white),
            onPressed: _repeatResult,
            tooltip: 'Repeat color',
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

      // Animated crosshair in center
      Center(
        child: _CrosshairTarget(
          color: _lastResult?.displayColor ?? Colors.white,
          isScanning: _isScanning,
        ),
      ),

      // Color badge top-left
      if (_lastResult != null)
        Positioned(
          top: 12,
          left: 12,
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _lastResult!.displayColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black45,
                      blurRadius: 6,
                      offset: Offset(0, 2))
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _lastResult!.dominantColor,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ]),
        ),

      // Detecting indicator bottom
      if (_isIdentifying)
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
                    color: Colors.amber.withOpacity(0.5)),
              ),
              child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          color: Colors.amber, strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Detecting color...',
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
                color: Colors.amber.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20)),
            child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.volume_up,
                      color: Colors.black, size: 14),
                  SizedBox(width: 4),
                  Text('Speaking',
                      style: TextStyle(
                          color: Colors.black,
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
          if (_isScanning) _PulseDot(color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                  color:
                      _isScanning ? Colors.amber : Colors.white60,
                  fontSize: 12),
            ),
          ),
        ]),
      );

  Widget _colorPanel() {
    if (_lastResult == null) {
      return Container(
        height: 100,
        color: Colors.grey[850],
        child: const Center(
          child: Text(
            'Point camera at any object\nto detect its color',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ),
      );
    }

    final r = _lastResult!;
    return Container(
      height: 100,
      color: Colors.grey[850],
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        // Big color swatch
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: r.displayColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24, width: 1.5),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                r.dominantColor.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2),
              ),
              const SizedBox(height: 4),
              Text(
                _sameColorCount > 0
                    ? 'Seen $_sameColorCount time${_sameColorCount == 1 ? '' : 's'} in a row'
                    : 'New color detected',
                style: TextStyle(
                    color: _sameColorCount > 0
                        ? Colors.white38
                        : Colors.amber,
                    fontSize: 12),
              ),
            ],
          ),
        ),
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
                    _isScanning ? Colors.orange : Colors.amber,
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

// ── Crosshair widget ───────────────────────────────────────────
class _CrosshairTarget extends StatefulWidget {
  final Color color;
  final bool isScanning;
  const _CrosshairTarget(
      {required this.color, required this.isScanning});

  @override
  State<_CrosshairTarget> createState() => _CrosshairTargetState();
}

class _CrosshairTargetState extends State<_CrosshairTarget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))
    ..repeat(reverse: true);
  late final Animation<double> _a =
      Tween<double>(begin: 0.4, end: 1.0).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (_, __) => SizedBox(
          width: 120,
          height: 120,
          child: CustomPaint(
            painter: _CrosshairPainter(
              color: widget.isScanning
                  ? widget.color.withOpacity(_a.value)
                  : Colors.white.withOpacity(0.5),
            ),
          ),
        ),
      );
}

class _CrosshairPainter extends CustomPainter {
  final Color color;
  _CrosshairPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final cx = size.width / 2;
    final cy = size.height / 2;
    const arm = 20.0;
    const gap = 14.0;

    final corners = [
      [
        Offset(cx - gap, cy - gap),
        Offset(cx - gap - arm, cy - gap),
        Offset(cx - gap, cy - gap),
        Offset(cx - gap, cy - gap - arm)
      ],
      [
        Offset(cx + gap, cy - gap),
        Offset(cx + gap + arm, cy - gap),
        Offset(cx + gap, cy - gap),
        Offset(cx + gap, cy - gap - arm)
      ],
      [
        Offset(cx - gap, cy + gap),
        Offset(cx - gap - arm, cy + gap),
        Offset(cx - gap, cy + gap),
        Offset(cx - gap, cy + gap + arm)
      ],
      [
        Offset(cx + gap, cy + gap),
        Offset(cx + gap + arm, cy + gap),
        Offset(cx + gap, cy + gap),
        Offset(cx + gap, cy + gap + arm)
      ],
    ];

    for (final corner in corners) {
      canvas.drawLine(corner[0], corner[1], paint);
      canvas.drawLine(corner[2], corner[3], paint);
    }

    canvas.drawCircle(
        Offset(cx, cy), 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) =>
      old.color != color;
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