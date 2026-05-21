// lib/screens/currency_screen.dart
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/currency_service.dart';
import '../services/tts_service.dart';
import '../utils/image_utils.dart';
import '../widgets/volume_button_mixin.dart';

// Sharpness (Laplacian variance) is now computed in a background isolate.
// See lib/utils/image_utils.dart


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
    _tts.speakLocalized(
      'Currency detection screen. Scanning will start automatically.',
      'मुद्रा पहचान स्क्रीन। स्कैनिंग अपने आप शुरू होगी।',
    );
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
    _tts.stop();
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

  int _stableFrames = 0;
  static const int _stableNeeded = 3;
  static const double _sharpThresh = 110.0;
  
  void _startScan() {
    if (_scanning) {
      _stopScan();
      return;
    }
    _last = null;
    _stableFrames = 0;
    setState(() {
      _scanning = true;
      _status = 'Point camera at currency…';
    });
    _tts.speakLocalized(
      'Scanning started. Hold camera steady over currency.',
      'स्कैनिंग शुरू। कैमरा नोट के ऊपर स्थिर रखें।',
    );
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _checkFrame());
  }

  void _stopScan() {
    _timer?.cancel();
    setState(() {
      _scanning = false;
      _status = 'Stopped. Tap to scan again.';
    });
  }

  Future<void> _checkFrame() async {
    if (_detecting || _cam == null || !_camReady || !_scanning) return;
    try {
      _detecting = true;
      final photo = await _cam!.takePicture();
      final bytes = await photo.readAsBytes();
      final sharp = await computeLaplacianVariance(bytes);
      
      if (!mounted) return;
      
      if (sharp >= _sharpThresh) {
        _stableFrames++;
        setState(() => _status = 'Sharp — hold still ($_stableFrames/$_stableNeeded)');
        if (_stableFrames >= _stableNeeded) {
           _stopScan();
           await _captureAndRead(photo.path);
        }
      } else {
        _stableFrames = 0;
        setState(() => _status = 'Move closer or hold steady');
      }
    } catch (_) {} finally {
      if (mounted) _detecting = false;
    }
  }

  Future<void> _captureAndRead(String path) async {
    setState(() {
      _detecting = true;
      _status = 'Analyzing currency…';
    });
    try {
      final result = await _svc.detectCurrency(path);
      if (!mounted) return;
      if (result != null && result.detectedNotes.isNotEmpty) {
        setState(() {
          _last = result;
          _status = 'Detection complete!';
        });
        final notes = result.detectedNotes.map((n) => '₹$n').join(', ');
        await _tts.speakLocalized(
          'Detected ${result.detectedNotes.length} notes: $notes. Total is ${result.totalAmount} rupees.',
          '${result.detectedNotes.length} नोट मिले: $notes। कुल ${result.totalAmount} रुपये।',
        );
      } else {
        setState(() => _status = 'No notes found. Tap repeat to scan again.');
        await _tts.speakLocalized(
          'Could not detect currency. Ensure notes are well lit.',
          'मुद्रा पहचान नहीं हो सकी। नोट अच्छी रोशनी में रखें।',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: $e');
      await _tts.speakLocalized(
        'An error occurred. Please try again.',
        'एक त्रुटि हुई। कृपया फिर से प्रयास करें।',
      );
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _speak() {
    if (_last == null) {
      _tts.speakLocalized(
        'No result yet. Please scan currency first.',
        'अभी कोई परिणाम नहीं। पहले मुद्रा स्कैन करें।',
      );
      return;
    }
    _tts.speakLocalized(
      'Total amount is ${_last!.totalAmount} rupees. '
      'Notes: ${_last!.detectedNotes.map((n) => "₹$n").join(", ")}.',
      'कुल राशि ${_last!.totalAmount} रुपये। '
      'नोट: ${_last!.detectedNotes.map((n) => "₹$n").join(", ")}।',
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
            _tts.speakLocalized('Going back', 'वापस जा रहे हैं');
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
