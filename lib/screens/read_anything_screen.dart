import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'dart:io';
import 'dart:async';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'registration.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_screen.dart';

class ReadAnythingScreen extends StatefulWidget {
  const ReadAnythingScreen({super.key});

  @override
  State<ReadAnythingScreen> createState() => _ReadAnythingScreenState();
}

class _ReadAnythingScreenState extends State<ReadAnythingScreen> {
  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isListening = false;
  bool _autoCapture = true;
  bool _recognizerReady = false;
  bool _torchEnabled = false;
  bool _isInContinuousReadMode = false; // Track if in continuous reading
  int _continuousReadLineIndex = 0; // Track current line being read
  String _detectedText = '';
  String _lastReadText = ''; // Track previously read text
  DateTime? _lastReadTime; // Track last read timestamp
  final int _textReadCooldownSeconds =
      3; // Minimum gap between readings same text
  final double _textSimilarityThreshold =
      0.85; // 85% similarity = treat as same text
  String _statusMessage = 'Initializing camera...';
  List<String> _detectedLanguages = [];
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _initializeApp();
    _setupVolumeButtonListener();
  }

  void _setupVolumeButtonListener() {
    // Listen to hardware buttons (volume keys)
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      // Volume Up key triggers capture
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
        if (!_isProcessing && _isCameraInitialized) {
          _captureAndRecognizeText();
        }
        return true; // Prevent default volume behavior
      }
    }
    return false;
  }

  Future<void> _initializeApp() async {
    try {
      // Initialize TTS first for feedback
      await _initializeTts();

      // Request permissions
      await _requestPermissions();
      await Future.delayed(const Duration(milliseconds: 500));

      // Initialize camera
      await _initializeCamera();

      // Initialize ML Kit text recognizer - use ONLY default recognizer
      try {
        _textRecognizer = TextRecognizer();
        _recognizerReady = true;
        debugPrint('TextRecognizer initialized successfully');
      } catch (e) {
        debugPrint('Recognizer initialization failed: $e');
        if (mounted) {
          setState(() => _statusMessage = 'OCR initialization failed: $e');
        }
        _recognizerReady = false;
        return;
      }

      await _initializeSpeech();

      if (mounted) {
        setState(
          () => _statusMessage = 'Ready. Press volume up or button to read.',
        );
      }

      // Only start voice commands if speech is available - with safe delay
      if (_speechAvailable && mounted) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _startListeningForVoiceCommands();
          }
        });
      }
    } catch (e) {
      debugPrint('Initialization error: $e');
      if (mounted) {
        setState(() => _statusMessage = 'Error: $e');
      }
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();
    await Permission.microphone.request();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() => _statusMessage = 'No camera available');
        }
        return;
      }

      // Select back camera for text recognition
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium, // Medium for stability and speed
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _statusMessage = 'Camera ready. Tap button to scan.';
        });
      }

      // Start auto-capture loop after delay
      if (_autoCapture && mounted) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _autoCapture) {
            _startAutoCapture();
          }
        });
      }
    } catch (e) {
      debugPrint('Camera initialization error: $e');
      if (mounted) {
        setState(() => _statusMessage = 'Camera error: $e');
      }
    }
  }

  Future<void> _initializeSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onError: (error) => debugPrint('Speech error: $error'),
        onStatus: (status) => debugPrint('Speech status: $status'),
      );
      debugPrint('Speech available: $_speechAvailable');
    } catch (e) {
      debugPrint('Speech initialization failed: $e');
      _speechAvailable = false;
    }
  }

  Future<void> _initializeTts() async {
    try {
      // Configure for best newspaper reading - no blocking
      await _flutterTts.setLanguage('en-IN');
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      // Set error handler
      _flutterTts.setErrorHandler((msg) {
        debugPrint('TTS error: $msg');
      });

      debugPrint('TTS initialized successfully');
    } catch (e) {
      debugPrint('TTS initialization failed: $e');
    }
  }

  void _startListeningForVoiceCommands() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        _listenForCommands();
      }
    });
  }

  Future<void> _listenForCommands() async {
    if (!_speechAvailable || !mounted) return;

    try {
      if (!_isListening && _speech.isAvailable) {
        try {
          setState(() => _isListening = true);

          await _speech
              .listen(
                onResult: (result) {
                  try {
                    final text = result.recognizedWords.toLowerCase();
                    debugPrint('Voice command: $text');

                    if (mounted &&
                        (text.contains('read') ||
                            text.contains('scan') ||
                            text.contains('padho') ||
                            text.contains('padhna') ||
                            text.contains('btao') ||
                            text.contains('batao'))) {
                      _captureAndRecognizeText();
                    }
                  } catch (e) {
                    debugPrint('Voice result error: $e');
                  }
                },
                listenFor: const Duration(seconds: 30),
                pauseFor: const Duration(seconds: 5),
                localeId: 'en_IN',
              )
              .timeout(
                const Duration(seconds: 35),
                onTimeout: () {
                  debugPrint('Voice listen timeout');
                },
              );

          // Safe restart with delay
          if (mounted && _isListening) {
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted && _isListening) {
                try {
                  _speech.stop();
                } catch (e) {
                  debugPrint('Speech stop error: $e');
                }
                if (mounted) {
                  setState(() => _isListening = false);
                  _listenForCommands();
                }
              }
            });
          }
        } on Exception catch (e) {
          debugPrint('Speech listen error: $e');
          if (mounted) {
            setState(() => _isListening = false);
          }
        }
      }
    } catch (e) {
      debugPrint('Voice command error: $e');
      if (mounted) {
        setState(() => _isListening = false);
      }
    }
  }

  void _startAutoCapture() {
    if (!mounted || !_autoCapture) return;

    Future.delayed(const Duration(seconds: 5), () async {
      if (mounted && _autoCapture && !_isProcessing && _isCameraInitialized) {
        try {
          await _captureAndRecognizeText(silent: true);
        } catch (e) {
          debugPrint('Auto-capture error: $e');
        }
        if (mounted && _autoCapture) {
          _startAutoCapture(); // Continue loop
        }
      }
    });
  }

  Future<void> _captureAndRecognizeText({bool silent = false}) async {
    if (_isProcessing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _textRecognizer == null ||
        !_recognizerReady ||
        !mounted) {
      debugPrint(
        'Cannot capture: processing=$_isProcessing, camera=$_isCameraInitialized, recognizer=$_recognizerReady',
      );
      if (!silent) {
        _speak('Please wait, camera is not ready');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isProcessing = true;
        if (!silent) _statusMessage = 'Reading text...';
      });
    }

    if (!silent) {
      _speak('Scanning');
    }

    XFile? image;
    InputImage? inputImage;

    try {
      // Take picture with error handling
      try {
        image = await _cameraController!.takePicture().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw TimeoutException('Camera capture timeout', Duration.zero);
          },
        );
        debugPrint('Image captured: ${image.path}');
      } catch (e) {
        debugPrint('Failed to capture image: $e');
        if (mounted) {
          setState(() => _statusMessage = 'Camera capture failed');
        }
        if (!silent) {
          _speak('Failed to capture image');
        }
        return;
      }

      // Small delay to ensure file is written
      await Future.delayed(const Duration(milliseconds: 150));

      // Verify file exists
      final imageFile = File(image.path);
      if (!await imageFile.exists()) {
        debugPrint('Captured image file does not exist: ${image.path}');
        if (mounted) {
          setState(() => _statusMessage = 'Image file error');
        }
        if (!silent) {
          _speak('Image file error');
        }
        return;
      }

      // Check brightness and auto-enable torch if dark
      await _checkAndAutoEnableTorch(image.path);

      try {
        inputImage = InputImage.fromFilePath(image.path);
        debugPrint('InputImage created');
      } catch (e) {
        debugPrint('Failed to create InputImage: $e');
        if (mounted) {
          setState(() => _statusMessage = 'Image processing error');
        }
        if (!silent) {
          _speak('Failed to process image');
        }
        return;
      }

      // Process image with single recognizer
      String detectedText = '';

      if (_textRecognizer != null && _recognizerReady) {
        try {
          debugPrint('Starting text recognition...');
          final recognitionResult = await _textRecognizer!
              .processImage(inputImage)
              .timeout(const Duration(seconds: 15));

          detectedText = recognitionResult.text ?? '';
          debugPrint('Text recognized: $detectedText');
        } catch (e) {
          debugPrint('Text recognition error: $e');

          // If recognizer crashes, mark it as not ready and recreate
          if (e.toString().contains('native') ||
              e.toString().contains('platform')) {
            debugPrint(
              'Recognizer native error, attempting to reinitialize...',
            );
            _recognizerReady = false;
            _textRecognizer?.close();
            _textRecognizer = null;
          }

          if (mounted) {
            setState(() => _statusMessage = 'Recognition failed');
          }
          if (!silent) {
            _speak('Failed to read text');
          }
          return;
        }
      } else {
        debugPrint(
          'Recognizer not ready: ready=$_recognizerReady, null=${_textRecognizer == null}',
        );
        if (!silent) {
          _speak('OCR not ready');
        }
        return;
      }

      String combinedText = detectedText;

      if (!mounted) return;

      debugPrint('Combined text: $combinedText');

      if (combinedText.isEmpty) {
        if (!silent && mounted) {
          setState(() => _statusMessage = 'No text found');
        }
      } else {
        // Auto-capture only processes if significant text found
        if (silent && combinedText.length < 5) {
          if (mounted) {
            setState(() => _isProcessing = false);
          }
          return;
        }

        // Check if text is similar to last read (using similarity check)
        double textSimilarity = _calculateTextSimilarity(
          combinedText.trim(),
          _lastReadText.trim(),
        );
        bool isSimilarText =
            textSimilarity >= _textSimilarityThreshold ||
            combinedText.trim().isEmpty;
        bool isWithinCooldown = false;

        if (_lastReadTime != null &&
            isSimilarText &&
            _lastReadText.isNotEmpty) {
          final timeSinceLastRead = DateTime.now()
              .difference(_lastReadTime!)
              .inSeconds;
          isWithinCooldown = timeSinceLastRead < _textReadCooldownSeconds;

          debugPrint(
            'Text similarity check: similarity=$textSimilarity (${(textSimilarity * 100).toStringAsFixed(1)}%), '
            'cooldown=$isWithinCooldown, timeSince=${timeSinceLastRead}s',
          );
        }

        // Handle continuous reading for auto-capture
        if (silent && isSimilarText && _lastReadText.isNotEmpty) {
          // In continuous mode - continue reading next lines
          debugPrint(
            'Continuous reading mode: similarity=${(textSimilarity * 100).toStringAsFixed(1)}%, '
            'reading from line ${_continuousReadLineIndex + 1}',
          );
          _isInContinuousReadMode = true;

          // Read only the new/next lines
          await _continuousRead(combinedText);
          return;
        } else if (!silent) {
          // Manual capture - reset continuous mode
          _isInContinuousReadMode = false;
          _continuousReadLineIndex = 0;
        }

        // Skip reading if similar text and within cooldown period (manual mode)
        if (isWithinCooldown && isSimilarText && !silent) {
          debugPrint(
            'Skipping similar text read (${(textSimilarity * 100).toStringAsFixed(1)}% similar, within cooldown)',
          );
          if (mounted) {
            setState(() {
              _statusMessage = 'Similar text (already read)';
            });
          }
          return;
        }

        // Detect language directly from combined text
        _detectLanguagesFromText(combinedText);

        if (mounted) {
          setState(() {
            _detectedText = combinedText;
            final langInfo = _detectedLanguages.isNotEmpty
                ? _detectedLanguages.join(', ')
                : 'English';
            _statusMessage = 'Reading: $langInfo text';
          });
        }

        // Update last read text and timestamp
        _lastReadText = combinedText;
        _lastReadTime = DateTime.now();

        // Update continuous read line index after reading full text
        final lines = combinedText.split('\n');
        _continuousReadLineIndex = lines.length;
        debugPrint(
          'Full text read, set continuousReadLineIndex to ${lines.length}',
        );

        // Immediately speak the detected text for blind users
        await _speak(_detectedText);
      }
    } catch (e) {
      debugPrint('Text recognition error: $e');
      if (mounted) {
        setState(() => _statusMessage = 'Recognition failed: ${e.toString()}');
      }
      if (!silent) {
        _speak('Unable to read text. Please try again');
      }
    } finally {
      // Cleanup resources - critical to prevent crashes
      inputImage = null;

      // Delete the captured image file immediately
      if (image != null) {
        try {
          final file = File(image.path);
          if (await file.exists()) {
            await file.delete();
            debugPrint('Image file deleted: ${image.path}');
          }
        } catch (e) {
          debugPrint('Warning: Could not delete image file: $e');
        }
      }

      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _detectLanguagesFromText(String text) {
    Set<String> languages = {};

    // Simple language detection based on Unicode ranges
    bool hasHindi = false;
    bool hasEnglish = false;

    for (int rune in text.runes) {
      if (rune >= 0x0900 && rune <= 0x097F) {
        hasHindi = true;
      } else if ((rune >= 0x0041 && rune <= 0x005A) ||
          (rune >= 0x0061 && rune <= 0x007A)) {
        hasEnglish = true;
      }
    }

    if (hasHindi) languages.add('Hindi');
    if (hasEnglish) languages.add('English');

    _detectedLanguages = languages.toList();
    debugPrint('Detected languages: $_detectedLanguages');
  }

  Future<void> _speak(String text) async {
    try {
      if (text.isEmpty || !mounted) return;

      // Non-blocking speak without waiting
      try {
        await _flutterTts.stop();
      } catch (e) {
        debugPrint('TTS stop error: $e');
      }

      await Future.delayed(const Duration(milliseconds: 50));

      bool hasHindi = _detectedLanguages.contains('Hindi');
      bool hasEnglish = _detectedLanguages.contains('English');

      try {
        if (hasHindi && !hasEnglish) {
          debugPrint('Speaking in Hindi: $text');
          await _flutterTts.setLanguage('hi-IN');
          await _flutterTts.setSpeechRate(0.4);
          await _flutterTts.setPitch(1.0);
          _flutterTts.speak(text); // Fire and forget
        } else if (hasEnglish && !hasHindi) {
          debugPrint('Speaking in English: $text');
          await _flutterTts.setLanguage('en-IN');
          await _flutterTts.setSpeechRate(0.5);
          await _flutterTts.setPitch(1.0);
          _flutterTts.speak(text); // Fire and forget
        } else if (hasHindi && hasEnglish) {
          debugPrint('Speaking mixed content in Hindi: $text');
          await _flutterTts.setLanguage('hi-IN');
          await _flutterTts.setSpeechRate(0.4);
          await _flutterTts.setPitch(1.0);
          _flutterTts.speak(text); // Fire and forget
        } else {
          debugPrint('Speaking default English: $text');
          await _flutterTts.setLanguage('en-IN');
          await _flutterTts.setSpeechRate(0.5);
          _flutterTts.speak(text); // Fire and forget
        }
      } catch (e) {
        debugPrint('TTS speak error: $e');
      }
    } catch (e) {
      debugPrint('TTS error: $e');
    }
  }

  // Calculate text similarity using simple algorithm
  double _calculateTextSimilarity(String text1, String text2) {
    if (text1.isEmpty && text2.isEmpty) return 1.0;
    if (text1.isEmpty || text2.isEmpty) return 0.0;

    // Remove common whitespace/punctuation differences
    final normalized1 = text1.toLowerCase().replaceAll(
      RegExp(r'[\s.,!?;:"-]+'),
      '',
    );
    final normalized2 = text2.toLowerCase().replaceAll(
      RegExp(r'[\s.,!?;:"-]+'),
      '',
    );

    if (normalized1 == normalized2) return 1.0;

    // Use Levenshtein-like similarity (simple version)
    final minLength = normalized1.length < normalized2.length
        ? normalized1.length
        : normalized2.length;
    final maxLength = normalized1.length > normalized2.length
        ? normalized1.length
        : normalized2.length;

    int matches = 0;
    for (int i = 0; i < minLength; i++) {
      if (normalized1[i] == normalized2[i]) matches++;
    }

    double similarity = matches / maxLength;
    return similarity;
  }

  // Check image brightness and auto-enable torch if dark
  Future<void> _checkAndAutoEnableTorch(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;

      // Calculate average brightness from first 1000 bytes
      int brightnessSum = 0;
      int sampleSize = bytes.length > 1000 ? 1000 : bytes.length;

      for (int i = 0; i < sampleSize; i++) {
        brightnessSum += bytes[i];
      }

      double averageBrightness = brightnessSum / sampleSize;
      debugPrint(
        'Average brightness: ${averageBrightness.toStringAsFixed(1)}/255',
      );

      // If brightness < 100, enable torch automatically
      if (averageBrightness < 100 && !_torchEnabled) {
        debugPrint('Dark environment detected, enabling torch');
        await _enableTorch();
      }
    } catch (e) {
      debugPrint('Error checking brightness: $e');
    }
  }

  // Enable camera torch
  Future<void> _enableTorch() async {
    try {
      if (_cameraController == null) return;
      await _cameraController!.setFlashMode(FlashMode.torch);
      if (mounted) {
        setState(() => _torchEnabled = true);
        _speak('Torch enabled');
      }
      debugPrint('Torch enabled');
    } catch (e) {
      debugPrint('Error enabling torch: $e');
    }
  }

  // Disable camera torch
  Future<void> _disableTorch() async {
    try {
      if (_cameraController == null) return;
      await _cameraController!.setFlashMode(FlashMode.off);
      if (mounted) {
        setState(() => _torchEnabled = false);
        _speak('Torch disabled');
      }
      debugPrint('Torch disabled');
    } catch (e) {
      debugPrint('Error disabling torch: $e');
    }
  }

  // Continuous reading - reads only new lines from previous position
  Future<void> _continuousRead(String currentText) async {
    try {
      final lines = currentText.split('\n');

      // If text has grown, read new lines from last position
      if (lines.length > _continuousReadLineIndex) {
        final newLines = lines.sublist(_continuousReadLineIndex);
        final textToRead = newLines.join('\n').trim();

        if (textToRead.isNotEmpty) {
          debugPrint(
            'Reading new lines from index $_continuousReadLineIndex: "$textToRead"',
          );
          await _speak(textToRead);
          _continuousReadLineIndex = lines.length;
        }
      }
      // If text is same length or shorter, continue from next line
      else if (lines.length <= _continuousReadLineIndex) {
        _continuousReadLineIndex = lines.length;
        debugPrint('Continuing reading, no new lines to read yet');
      }
    } catch (e) {
      debugPrint('Error in continuous read: $e');
    }
  }

  // Reset continuous reading mode
  void _resetContinuousRead() {
    _isInContinuousReadMode = false;
    _continuousReadLineIndex = 0;
    debugPrint('Continuous read mode reset');
  }

  @override
  void dispose() {
    _autoCapture = false;
    _isListening = false;
    _recognizerReady = false;
    _torchEnabled = false;
    _isInContinuousReadMode = false;
    _continuousReadLineIndex = 0;
    _lastReadTime = null;
    _lastReadText = '';
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    try {
      _disableTorch();
      _cameraController?.dispose();
      _textRecognizer?.close();
      _speech.stop();
      _flutterTts.stop();
    } catch (e) {
      debugPrint('Dispose error: $e');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Text Recognition OCR'),
        actions: [
          IconButton(
            icon: Icon(
              _torchEnabled ? Icons.flashlight_on : Icons.flashlight_off,
            ),
            onPressed: () {
              if (_torchEnabled) {
                _disableTorch();
              } else {
                _enableTorch();
              }
            },
            tooltip: 'Toggle Torch',
          ),
          IconButton(
            icon: Icon(
              _autoCapture ? Icons.auto_awesome : Icons.auto_awesome_outlined,
            ),
            onPressed: () {
              setState(() => _autoCapture = !_autoCapture);
              if (_autoCapture) {
                _startAutoCapture();
                _speak('Auto capture enabled');
              } else {
                _speak('Auto capture disabled');
              }
            },
            tooltip: 'Toggle Auto Capture',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _resetContinuousRead();
              setState(() => _statusMessage = 'Continuous read reset');
              _speak('Reset continuous reading');
            },
            tooltip: 'Reset Reading',
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RegistrationScreen()),
                );
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),
      body: _isCameraInitialized
          ? Column(
              children: [
                // Camera Preview
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: _cameraController!.value.aspectRatio,
                          child: CameraPreview(_cameraController!),
                        ),
                      ),
                      // Overlay with guide
                      Center(
                        child: Container(
                          width: MediaQuery.of(context).size.width * 0.8,
                          height: 200,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.green, width: 2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: Text(
                              'Point camera at text',
                              style: TextStyle(
                                color: Colors.white,
                                backgroundColor: Colors.black54,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Status indicator
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              if (_isProcessing)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              if (_isProcessing) const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _statusMessage,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              if (_isListening)
                                const Icon(
                                  Icons.mic,
                                  color: Colors.red,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Detected Text Display
                Expanded(
                  flex: 2,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      border: Border(top: BorderSide(color: Colors.grey[300]!)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Detected Text:',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (_detectedLanguages.isNotEmpty)
                              Chip(
                                label: Text(_detectedLanguages.join(', ')),
                                backgroundColor: Colors.green[100],
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Text(
                              _detectedText.isEmpty
                                  ? 'Say "Read this" or "Padho" to capture text\n\nSupported languages:\n• English\n• Hindi (हिंदी)'
                                  : _detectedText,
                              style: TextStyle(
                                fontSize: 16,
                                color: _detectedText.isEmpty
                                    ? Colors.grey[600]
                                    : Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_statusMessage),
                ],
              ),
            ),
      floatingActionButton: _isCameraInitialized
          ? FloatingActionButton.extended(
              onPressed: _isProcessing
                  ? null
                  : () => _captureAndRecognizeText(),
              backgroundColor: _isProcessing ? Colors.grey : Colors.green,
              icon: _isProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.camera),
              label: const Text('Capture & Read'),
            )
          : null,
    );
  }
}
