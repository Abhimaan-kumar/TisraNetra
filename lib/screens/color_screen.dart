// lib/screens/color_screen.dart
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/color_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';

class ColorScreen extends StatefulWidget {
  const ColorScreen({super.key});
  @override
  State<ColorScreen> createState() => _ColorScreenState();
}

class _ColorScreenState extends State<ColorScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {
  final ColorService _svc = ColorService();
  final TtsService _tts = TtsService();

  CameraController? _cam;
  List<CameraDescription> _cameras = [];
  bool _camReady = false;

  ColorResult? _last, _prev;
  bool _identifying = false, _scanning = false, _isSpeaking = false;
  bool _keepScanning = false;
  String _status = 'Initializing…';
  int _scanNo = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _initCamera();
    _tts.speak(
      'Color detection screen. Point camera at any object to detect its color.',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) {
      _keepScanning = false;
      _cam?.dispose();
    } else if (s == AppLifecycleState.resumed)
      _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keepScanning = false;
    _cam?.dispose();
    _tts.dispose();
    super.dispose();
  }

  @override
  Future<void> onVolumeUp() async {
    if (_scanning) {
      _stopScan();
    } else {
      _startScan();
    }
  }

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final isRepeat =
        cmd.contains('repeat') ||
        cmd.contains('phir') ||
        cmd.contains('batao') ||
        cmd.contains('rang batao');
    final isScan =
        cmd.contains('scan') ||
        cmd.contains('again') ||
        cmd.contains('dubara') ||
        cmd.contains('kro');
    final isStop =
        cmd.contains('stop') || cmd.contains('ruko') || cmd.contains('band');
    if (isStop) {
      _stopScan();
      await _tts.speak(hi ? 'रुक गया।' : 'Stopped.');
    } else if (isScan) {
      _startScan();
      await _tts.speak(hi ? 'फिर से देख रहा हूँ।' : 'Scanning again.');
    } else if (isRepeat) {
      if (_last != null)
        await _tts.speak(_last!.description);
      else
        await _tts.speak(hi ? 'अभी कुछ नहीं मिला।' : 'Nothing detected yet.');
    } else {
      await _tts.speak(
        hi ? 'कमांड समझ नहीं आई।' : 'Say "scan again" or "repeat".',
      );
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _status = 'No camera');
        return;
      }
      final ctrl = CameraController(
        _cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      if (!mounted) return;
      setState(() {
        _cam = ctrl;
        _camReady = true;
      });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _startScan();
    } catch (e) {
      setState(() => _status = 'Camera error: $e');
    }
  }

  void _startScan() {
    if (_scanning) return;
    _keepScanning = true;
    setState(() {
      _scanning = true;
      _status = 'Scanning for color…';
    });
    _loop();
  }

  void _stopScan() {
    _keepScanning = false;
    setState(() {
      _scanning = false;
      _status = 'Paused.';
    });
  }

  Future<void> _loop() async {
    while (_keepScanning && mounted) {
      await _detect();
      if (_keepScanning && mounted)
        await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _detect() async {
    if (_identifying || !_camReady || _cam == null) return;
    _scanNo++;
    setState(() {
      _identifying = true;
      _status = 'Scan #$_scanNo…';
    });
    try {
      final photo = await _cam!.takePicture();
      final bytes = await photo.readAsBytes();
      final result = await _svc.identifyColor(bytes);
      if (!mounted) return;
      if (result != null) {
        final same =
            _prev != null && _prev!.dominantColor == result.dominantColor;
        if (same) {
          setState(() => _last = result);
          return;
        }
        setState(() {
          _prev = _last;
          _last = result;
          _status = 'Color: ${result.description}';
        });
        setState(() => _isSpeaking = true);
        await _tts.speak(result.description);
        if (mounted) setState(() => _isSpeaking = false);
      } else {
        setState(() => _status = 'Could not detect color.');
      }
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('quota') || msg.contains('429')) {
        setState(() => _status = 'Quota exceeded.');
        _stopScan();
      } else {
        setState(() => _status = 'Error: $e');
      }
    } finally {
      if (mounted) setState(() => _identifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _keepScanning = false;
            Navigator.pop(context);
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Color Detection',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              isMixinListening
                  ? '🎤 Listening…'
                  : 'Vol↑ = scan/pause  Vol↓ = home',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          if (_last != null)
            IconButton(
              icon: Icon(
                Icons.volume_up,
                color: _isSpeaking ? Colors.yellow : Colors.white,
              ),
              onPressed: () {
                if (_last != null) _tts.speak(_last!.description);
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(flex: 3, child: _buildCamera()),
          _buildStatus(),
          if (_last != null) _buildColorPanel(),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildCamera() {
    if (!_camReady || _cam == null)
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_cam!),
        if (_scanning)
          Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: (_last?.displayColor ?? Colors.yellow).withOpacity(0.7),
                width: 3,
              ),
            ),
          ),
        if (_identifying)
          const Center(
            child: CircularProgressIndicator(color: Colors.yellowAccent),
          ),
        if (isMixinListening)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                '🎤 Listening…',
                style: TextStyle(color: Colors.yellowAccent, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStatus() => Container(
    width: double.infinity,
    color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Text(
      _status,
      style: TextStyle(
        color: _scanning ? Colors.yellowAccent : Colors.white60,
        fontSize: 12,
      ),
    ),
  );

  Widget _buildColorPanel() {
    final r = _last!;
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: r.displayColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DETECTED COLOR',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  r.description,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() => Container(
    color: Colors.black,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _camReady ? (_scanning ? _stopScan : _startScan) : null,
            icon: Icon(
              _scanning
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              size: 26,
            ),
            label: Text(
              _scanning ? 'Pause' : 'Resume',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _scanning ? Colors.orange : Colors.yellowAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _last != null
                ? () => _tts.speak(_last!.description)
                : null,
            icon: const Icon(Icons.replay, size: 22),
            label: const Text('Repeat', style: TextStyle(fontSize: 15)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[800],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 18),
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
