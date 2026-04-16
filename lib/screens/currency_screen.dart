// lib/screens/currency_screen.dart
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/currency_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';

class CurrencyScreen extends StatefulWidget {
  const CurrencyScreen({super.key});
  @override
  State<CurrencyScreen> createState() => _CurrencyScreenState();
}

class _CurrencyScreenState extends State<CurrencyScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {
  CameraController? _cam;
  final CurrencyService _svc = CurrencyService();
  final TtsService _tts = TtsService();

  List<CameraDescription> _cameras = [];
  CurrencyDetectionResult? _last;

  bool _detecting = false;
  bool _camReady = false;
  bool _scanning = false;
  String _status = 'Starting camera…';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _initCamera().then((_) {
      if (_camReady) _startScan();
    });
    _tts.speak('Currency detection screen. Scanning will start automatically.');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) {
      _cam?.dispose();
    } else if (s == AppLifecycleState.resumed) {
      _startCamera(_cameras.first);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _cam?.dispose();
    _tts.dispose();
    super.dispose();
  }

  // ── VolumeButtonMixin ────────────────────────────────────────────────────
  @override
  Future<void> onVolumeUp() async => _restart();

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final isRepeat =
        cmd.contains('repeat') ||
        cmd.contains('phir') ||
        cmd.contains('dobara');
    final isScan =
        cmd.contains('scan') ||
        cmd.contains('again') ||
        cmd.contains('restart') ||
        cmd.contains('dubara') ||
        cmd.contains('kro');
    final isStop =
        cmd.contains('stop') || cmd.contains('ruko') || cmd.contains('band');
    if (isStop) {
      _stopScan();
      await _tts.speak(hi ? 'रुक गया।' : 'Stopped.');
    } else if (isScan) {
      _restart();
      await _tts.speak(hi ? 'फिर से स्कैन कर रहा हूँ।' : 'Scanning again.');
    } else if (isRepeat) {
      _speak();
      await _tts.speak(hi ? '' : '');
    } else {
      await _tts.speak(
        hi
            ? 'कमांड समझ नहीं आई।'
            : 'Command not understood. Say scan again or repeat.',
      );
    }
  }

  // ── Camera ───────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _status = 'No camera');
        return;
      }
      await _startCamera(_cameras.first);
    } catch (e) {
      setState(() => _status = 'Camera error: $e');
    }
  }

  Future<void> _startCamera(CameraDescription cam) async {
    final ctrl = CameraController(
      cam,
      ResolutionPreset.high,
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
        _cam = ctrl;
        _camReady = true;
      });
    } catch (e) {
      setState(() => _status = 'Camera failed: $e');
    }
  }

  void _startScan() {
    if (_scanning) {
      _stopScan();
      return;
    }
    setState(() {
      _scanning = true;
      _status = 'Scanning… hold camera over currency';
    });
    _tts.speak('Scanning started. Hold camera over currency notes.');
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_scanning && !_detecting) _capture();
    });
    _capture();
  }

  void _stopScan() {
    _timer?.cancel();
    setState(() {
      _scanning = false;
      _status = 'Stopped. Tap to scan again.';
    });
  }

  Future<void> _capture() async {
    if (_detecting || _cam == null || !_camReady) return;
    setState(() {
      _detecting = true;
      _status = 'Analyzing…';
    });
    try {
      await _cam!.setFocusMode(FocusMode.auto);
      await Future.delayed(const Duration(milliseconds: 600));
      final photo = await _cam!.takePicture();
      // Offload to local offline ML Kit text engine
      final result = await _svc.detectCurrency(photo.path);
      if (!mounted) return;
      if (result != null && result.detectedNotes.isNotEmpty) {
        setState(() {
          _last = result;
          _status = 'Detection complete!';
        });
        final notes = result.detectedNotes.map((n) => '₹$n').join(', ');
        await _tts.speak(
          'Detected ${result.detectedNotes.length} notes: $notes. '
          'Total is ${result.totalAmount} rupees.',
        );
      } else {
        setState(() => _status = 'No notes found. Keep camera steady.');
        await _tts.speak(
          'Could not detect currency. Ensure notes are well lit.',
        );
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
      await _tts.speak('An error occurred. Please try again.');
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _speak() {
    if (_last == null) {
      _tts.speak('No result yet. Please scan currency first.');
      return;
    }
    _tts.speak(
      'Total amount is ${_last!.totalAmount} rupees. '
      'Notes: ${_last!.detectedNotes.map((n) => "₹$n").join(", ")}.',
    );
  }

  void _restart() {
    _last = null;
    _startScan();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Currency Detection',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              isMixinListening
                  ? '🎤 Listening…'
                  : 'Vol↑ = scan again  Vol↓ = home',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _tts.speak('Going back');
            Navigator.pop(context);
          },
        ),
        actions: [
          if (_last != null)
            IconButton(
              icon: const Icon(Icons.volume_up, color: Colors.white),
              onPressed: _speak,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(flex: 3, child: _buildCamera()),
          Container(
            width: double.infinity,
            color: Colors.grey[900],
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _scanning ? Colors.greenAccent : Colors.white70,
                fontSize: 14,
              ),
            ),
          ),
          if (_last != null) _buildResult(),
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
      children: [
        SizedBox.expand(child: CameraPreview(_cam!)),
        if (_scanning)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.greenAccent, width: 3),
            ),
          ),
        if (_detecting)
          Container(
            color: Colors.black38,
            child: const Center(
              child: CircularProgressIndicator(color: Colors.greenAccent),
            ),
          ),
        if (isMixinListening)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Text(
                  '🎤 Listening…',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResult() {
    final r = _last!;
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Amount:',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              Text(
                '₹${r.totalAmount}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: r.detectedNotes
                .map(
                  (n) => Chip(
                    label: Text(
                      '₹$n',
                      style: const TextStyle(color: Colors.black),
                    ),
                    backgroundColor: Colors.greenAccent,
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() => Container(
    color: Colors.black,
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          flex: 3,
          child: ElevatedButton.icon(
            onPressed: _camReady ? _startScan : null,
            icon: Icon(
              _scanning ? Icons.stop_circle : Icons.document_scanner,
              size: 28,
            ),
            label: Text(
              _scanning ? 'Stop Scan' : 'Start Scan',
              style: const TextStyle(fontSize: 18),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _scanning
                  ? Colors.redAccent
                  : Colors.greenAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        if (_last != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _restart,
              icon: const Icon(Icons.refresh),
              label: const Text('Restart'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
