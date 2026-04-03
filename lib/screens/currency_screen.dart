import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../../services/currency_service.dart';
import '../../services/tts_service.dart';

class CurrencyScreen extends StatefulWidget {
  const CurrencyScreen({super.key});

  @override
  State<CurrencyScreen> createState() => _CurrencyScreenState();
}

class _CurrencyScreenState extends State<CurrencyScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final CurrencyService _currencyService = CurrencyService();
  final TtsService _ttsService = TtsService();
  final SpeechToText _speechToText = SpeechToText();

  List<CameraDescription> _cameras = [];
  CurrencyDetectionResult? _lastResult;

  bool _isDetecting = false;
  bool _isCameraReady = false;
  bool _isScanning = false;
  String _statusMessage = 'Tap the button to start scanning';

  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSpeech();
    _initCamera().then((_) {
      if (_isCameraReady) {
        _startScanning();
      }
    });
    _ttsService.speak(
      'Currency detection screen opened. Scanning will start automatically.',
    );
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _statusMessage = 'No camera found');
        return;
      }
      await _startCamera(_cameras.first);
    } catch (e) {
      setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  Future<void> _initSpeech() async {
    await _speechToText.initialize();
  }

  Future<void> _startCamera(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      ResolutionPreset.high, // Changed from medium → high
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      await controller.setFocusMode(FocusMode.auto);
      await controller.setExposureMode(ExposureMode.auto);
      await controller.setFlashMode(FlashMode.off);

      if (!mounted) return;
      setState(() {
        _cameraController = controller;
        _isCameraReady = true;
      });
    } catch (e) {
      setState(() => _statusMessage = 'Camera init failed: $e');
    }
  }

  void _startScanning() {
    if (_isScanning) {
      _stopScanning();
      return;
    }

    setState(() {
      _isScanning = true;
      _statusMessage = 'Scanning... Hold camera over currency notes';
    });

    _ttsService.speak(
      'Scanning started. Hold the camera over the currency notes.',
    );

    // Auto-scan every 4 seconds
    _scanTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_isScanning && !_isDetecting) {
        _captureAndDetect();
      }
    });

    // First scan immediately
    _captureAndDetect();
  }

  void _stopScanning() {
    _scanTimer?.cancel();
    setState(() {
      _isScanning = false;
      _statusMessage = 'Scanning stopped. Tap to scan again.';
    });
    _ttsService.speak('Scanning stopped.');
  }

  Future<void> _captureAndDetect() async {
    if (_isDetecting || _cameraController == null || !_isCameraReady) return;

    setState(() {
      _isDetecting = true;
      _statusMessage = 'Analyzing image...';
    });

    try {
      await _cameraController!.setFocusMode(FocusMode.auto);
      await Future.delayed(
        const Duration(milliseconds: 600),
      ); // Let focus settle

      final XFile photo = await _cameraController!.takePicture();
      final Uint8List imageBytes = await photo.readAsBytes();

      print('Image size: ${imageBytes.length} bytes'); // Should be > 100KB

      if (imageBytes.length < 50000) {
        setState(() => _statusMessage = 'Image too small, retrying...');
        setState(() => _isDetecting = false);
        return;
      }

      final result = await _currencyService.detectCurrency(imageBytes);

      if (!mounted) return;

      if (result != null && result.detectedNotes.isNotEmpty) {
        setState(() {
          _lastResult = result;
          _statusMessage = 'Detection complete!';
        });

        final notesList = result.detectedNotes.map((n) => '₹$n').join(', ');
        final speech =
            'Detected ${result.detectedNotes.length} notes: $notesList. '
            'Total is ${result.totalAmount} rupees.';
        await _ttsService.speak(speech);
      } else {
        final rawMsg = result?.rawResponse ?? 'null result';
        print('No notes detected. Raw response: $rawMsg');

        setState(
          () =>
              _statusMessage = 'No notes found. Keep camera steady and retry.',
        );
        await _ttsService.speak(
          'Could not detect currency. Please hold the camera steadier and ensure notes are well lit.',
        );
      }
    } catch (e) {
      print('Capture error: $e');
      setState(() => _statusMessage = 'Error: $e');
      await _ttsService.speak('An error occurred. Please try again.');
    } finally {
      if (mounted) setState(() => _isDetecting = false);
    }
  }

  Future<void> _speakResult() async {
    if (_lastResult == null) {
      await _ttsService.speak('No result yet. Please scan currency first.');
      return;
    }
    final speech =
        'Total amount is ${_lastResult!.totalAmount} rupees. '
        'Notes detected: ${_lastResult!.detectedNotes.map((n) => "₹$n").join(", ")}.';
    await _ttsService.speak(speech);
  }

  void _clearResult() {
    setState(() {
      _lastResult = null;
      _statusMessage = 'Cleared. Tap scan to start again.';
    });
    _ttsService.speak('Results cleared.');
  }

  void _restart() {
    _clearResult();
    _startScanning();
    _ttsService.speak('Restarting scan.');
  }

  Future<void> _startListeningForRestart() async {
    if (_speechToText.isListening) return;
    await _speechToText.listen(
      onResult: (result) {
        if (result.recognizedWords.toLowerCase().contains('restart')) {
          _restart();
          _speechToText.stop();
        }
      },
    );
    _ttsService.speak('Listening for restart command.');
  }

  void _handleKey(RawKeyEvent event) {
    if (event is RawKeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _startListeningForRestart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera(_cameras.first);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _cameraController?.dispose();
    _speechToText.stop();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKey: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text(
            'Currency Detection',
            style: TextStyle(color: Colors.white, fontSize: 20),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              _ttsService.speak('Going back');
              Navigator.pop(context);
            },
            tooltip: 'Go back',
          ),
          actions: [
            if (_lastResult != null)
              IconButton(
                icon: const Icon(Icons.volume_up, color: Colors.white),
                onPressed: _speakResult,
                tooltip: 'Repeat total',
              ),
          ],
        ),
        body: Column(
          children: [
            // Camera Preview
            Expanded(flex: 3, child: _buildCameraPreview()),

            // Status Bar
            Container(
              width: double.infinity,
              color: Colors.grey[900],
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isScanning ? Colors.greenAccent : Colors.white70,
                  fontSize: 14,
                ),
              ),
            ),

            // Result Panel
            if (_lastResult != null) _buildResultPanel(),

            // Action Buttons
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Initializing camera...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        SizedBox.expand(child: CameraPreview(_cameraController!)),

        // Scanning overlay
        if (_isScanning)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.greenAccent, width: 3),
            ),
          ),

        // Processing indicator
        if (_isDetecting)
          Container(
            color: Colors.black38,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.greenAccent),
                  SizedBox(height: 12),
                  Text(
                    'Analyzing...',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResultPanel() {
    final result = _lastResult!;
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Total
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Amount:',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              Text(
                '₹${result.totalAmount}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Notes chips
          Wrap(
            spacing: 8,
            children: result.detectedNotes.map((note) {
              return Chip(
                label: Text(
                  '₹$note',
                  style: const TextStyle(color: Colors.black),
                ),
                backgroundColor: Colors.greenAccent,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Scan Button (main CTA - large for accessibility)
          Expanded(
            flex: 3,
            child: ElevatedButton.icon(
              onPressed: _isCameraReady ? _startScanning : null,
              icon: Icon(
                _isScanning ? Icons.stop_circle : Icons.document_scanner,
                size: 28,
              ),
              label: Text(
                _isScanning ? 'Stop Scan' : 'Start Scan',
                style: const TextStyle(fontSize: 18),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isScanning
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
          const SizedBox(width: 12),
          // Restart Button
          if (_lastResult != null)
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
      ),
    );
  }
}
