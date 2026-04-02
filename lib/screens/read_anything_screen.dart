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
  String _lastCapturedText = ''; // Track last OCR result to avoid repeats

  // Fields used for stable reading and avoiding re-reads
  String _lastSpokenNormalizedText = '';
  String _pendingStableText = '';
  String _pendingStableTextNormalized = '';
  Timer? _stableReadTimer;
  final Duration _stableReadDelay = const Duration(milliseconds: 1200);

  DateTime _lastSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration _minReadInterval = const Duration(seconds: 4);

  final Map<String, String> _ocrCorrectionMap = {
    '0': 'O',
    '1': 'I',
    '5': 'S',
    '6': 'G',
    '8': 'B',
    'ﬁ': 'fi',
    'ﬂ': 'fl',
  };

  final Map<String, String> _commonWordFixes = {
    'teh': 'the',
    'adn': 'and',
    'languge': 'language',
    'recongnition': 'recognition',
    'scaning': 'scanning',
    'readng': 'reading',
  };

  int _stableCaptureCount = 0; // Count of consecutive similar captures
  final int _stableCaptureThreshold =
      2; // Number of repeats required to consider text stable
  DateTime? _lastReadTime; // Track last read timestamp
  DateTime? _lastAutoCaptureTime;
  Duration _autoCaptureInterval = const Duration(seconds: 5);
  int _noTextCaptureCount = 0; // Count consecutive captures with no text
  final int _noTextCaptureThreshold =
      3; // How many times to see no text before showing 'No text found'
  final int _textReadCooldownSeconds =
      3; // Minimum gap between readings same text
  final double _textSimilarityThreshold =
      0.92; // 92% similarity = treat as same text (helps avoid re-reading on small framing shifts)
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

    final now = DateTime.now();
    if (_lastAutoCaptureTime != null &&
        now.difference(_lastAutoCaptureTime!) < _autoCaptureInterval) {
      // Wait for the interval to pass before the next capture
      Future.delayed(
        _autoCaptureInterval - now.difference(_lastAutoCaptureTime!),
        () {
          if (mounted && _autoCapture) {
            _startAutoCapture();
          }
        },
      );
      return;
    }

    _lastAutoCaptureTime = now;

    Future.delayed(const Duration(seconds: 1), () async {
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

  bool _canSpeakText(String normalizedText) {
    if (normalizedText.isEmpty) return false;
    final now = DateTime.now();
    if (now.difference(_lastSpokenTime) < _minReadInterval) {
      debugPrint('Skipping speak: cooldown active');
      return false;
    }
    if (_lastSpokenNormalizedText.isNotEmpty) {
      final similarity = _calculateTextSimilarity(
        normalizedText,
        _lastSpokenNormalizedText,
      );
      if (similarity >= _textSimilarityThreshold) {
        debugPrint('Skipping speak: similar text ($similarity)');
        return false;
      }
    }
    return true;
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

      await Future.delayed(const Duration(milliseconds: 150));

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
        _noTextCaptureCount++;
        if (_noTextCaptureCount >= _noTextCaptureThreshold) {
          if (!silent && mounted) {
            setState(() => _statusMessage = 'No text found');
          }
        } else {
          if (mounted) {
            setState(() => _statusMessage = 'Looking for text...');
          }
        }
      } else {
        _noTextCaptureCount = 0;
        if (silent && combinedText.length < 5) {
          if (mounted) {
            setState(() => _isProcessing = false);
          }
          return;
        }

        final rawText = combinedText.trim();
        final processedText = _postProcessText(rawText);
        final normalizedText = _normalizeForComparison(processedText);

        if (!silent) {
          if (!_canSpeakText(normalizedText)) {
            if (mounted) {
              setState(() => _statusMessage = 'Already read recently');
            }
            return;
          }

          _lastCapturedText = processedText;
          _lastSpokenNormalizedText = normalizedText;
          _lastSpokenTime = DateTime.now();
          _lastReadText = processedText;
          _detectLanguagesFromText(processedText);
          if (mounted) {
            setState(() {
              _detectedText = processedText;
              final langInfo = _detectedLanguages.isNotEmpty
                  ? _detectedLanguages.join(', ')
                  : 'English';
              _statusMessage = 'Reading: $langInfo text';
            });
          }

          try {
            await HapticFeedback.lightImpact();
          } catch (_) {}
          await _speak(processedText);
          return;
        }

        final normalizedLastCapture = _normalizeForComparison(
          _lastCapturedText,
        );
        final captureSimilarity = _calculateTextSimilarity(
          normalizedText,
          normalizedLastCapture,
        );
        final isSameCapture = captureSimilarity >= _textSimilarityThreshold;

        _autoCaptureInterval = isSameCapture
            ? const Duration(seconds: 10)
            : const Duration(seconds: 5);

        if (isSameCapture) {
          _stableCaptureCount++;
        } else {
          _stableCaptureCount = 1;
          _lastCapturedText = processedText;
        }

        if (_stableCaptureCount >= _stableCaptureThreshold) {
          if (!_canSpeakText(normalizedText)) {
            if (mounted) {
              setState(() => _statusMessage = 'Text stable but recently read');
            }
            return;
          }
          if (mounted) {
            setState(
              () =>
                  _statusMessage = 'Stable text detected. Preparing to read...',
            );
          }
          _scheduleStableRead(processedText, normalizedText, silent: silent);
          return;
        }

        debugPrint('Waiting for stable capture ($_stableCaptureCount)');
        if (mounted) {
          setState(() => _statusMessage = 'Holding still for stable read...');
        }
        return;
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
      inputImage = null;

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
          _flutterTts.speak(text);
        } else if (hasEnglish && !hasHindi) {
          debugPrint('Speaking in English: $text');
          await _flutterTts.setLanguage('en-IN');
          await _flutterTts.setSpeechRate(0.5);
          await _flutterTts.setPitch(1.0);
          _flutterTts.speak(text);
        } else if (hasHindi && hasEnglish) {
          debugPrint('Speaking mixed content in Hindi: $text');
          await _flutterTts.setLanguage('hi-IN');
          await _flutterTts.setSpeechRate(0.4);
          await _flutterTts.setPitch(1.0);
          _flutterTts.speak(text);
        } else {
          debugPrint('Speaking default English: $text');
          await _flutterTts.setLanguage('en-IN');
          await _flutterTts.setSpeechRate(0.5);
          _flutterTts.speak(text);
        }
      } catch (e) {
        debugPrint('TTS speak error: $e');
      }
    } catch (e) {
      debugPrint('TTS error: $e');
    }
  }

  String _normalizeForComparison(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[\s\W_]+'), '').trim();
  }

  String _postProcessText(String text) {
    String cleaned = text
        .replaceAll('\u00A0', ' ')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    _ocrCorrectionMap.forEach((wrong, right) {
      cleaned = cleaned.replaceAll(wrong, right);
    });

    final words = cleaned.split(' ');
    for (int i = 0; i < words.length; i++) {
      final key = words[i].toLowerCase();
      if (_commonWordFixes.containsKey(key)) {
        words[i] = _commonWordFixes[key]!;
      }
    }
    cleaned = words.join(' ').trim();
    return cleaned;
  }

  void _scheduleStableRead(
    String text,
    String normalizedText, {
    bool silent = false,
  }) {
    _pendingStableText = text;
    _pendingStableTextNormalized = normalizedText;
    _stableReadTimer?.cancel();
    _stableReadTimer = Timer(_stableReadDelay, () async {
      if (_pendingStableTextNormalized != normalizedText) return;

      if (!_canSpeakText(normalizedText)) {
        if (mounted) {
          setState(() => _statusMessage = 'Stable text unchanged');
        }
        return;
      }

      final newTextToRead = _extractNewText(
        _lastReadText,
        _pendingStableText,
      ).trim();
      final textToRead = newTextToRead.isNotEmpty
          ? newTextToRead
          : _pendingStableText.trim();

      if (textToRead.isEmpty) {
        if (mounted) {
          setState(() => _statusMessage = 'No new text detected');
        }
        return;
      }

      _lastReadText = _pendingStableText;
      _lastSpokenNormalizedText = normalizedText;
      _lastSpokenTime = DateTime.now();

      _detectLanguagesFromText(_pendingStableText);
      if (mounted) {
        setState(() {
          _detectedText = _pendingStableText;
          final langInfo = _detectedLanguages.isNotEmpty
              ? _detectedLanguages.join(', ')
              : 'English';
          _statusMessage = 'Reading: $langInfo text';
        });
      }

      _continuousReadLineIndex = _pendingStableText.split('\n').length;

      if (!silent) {
        try {
          await HapticFeedback.lightImpact();
        } catch (_) {}
        await _speak(textToRead);
      } else {
        if (mounted) {
          setState(() => _statusMessage = 'Text stabilized (silent mode)');
        }
      }
    });
  }

  String _extractNewText(String previous, String current) {
    final prevLines = previous.split('\n');
    final currLines = current.split('\n');
    int firstDiff = 0;

    while (firstDiff < prevLines.length &&
        firstDiff < currLines.length &&
        _normalizeForComparison(prevLines[firstDiff]) ==
            _normalizeForComparison(currLines[firstDiff])) {
      firstDiff++;
    }

    if (firstDiff >= currLines.length) return '';
    return currLines.sublist(firstDiff).join('\n');
  }

  double _calculateTextSimilarity(String text1, String text2) {
    final normalized1 = text1.toLowerCase().replaceAll(RegExp(r'[\s\W_]+'), '');
    final normalized2 = text2.toLowerCase().replaceAll(RegExp(r'[\s\W_]+'), '');

    if (normalized1.isEmpty && normalized2.isEmpty) return 1.0;
    if (normalized1.isEmpty || normalized2.isEmpty) return 0.0;

    final dist = _levenshteinDistance(normalized1, normalized2);
    final maxLen = normalized1.length > normalized2.length
        ? normalized1.length
        : normalized2.length;
    final similarity = 1.0 - (dist / maxLen);
    return similarity.clamp(0.0, 1.0);
  }

  int _levenshteinDistance(String s, String t) {
    final m = s.length;
    final n = t.length;
    if (m == 0) return n;
    if (n == 0) return m;

    final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;

    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return dp[m][n];
  }

  Future<void> _checkAndAutoEnableTorch(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;

      int brightnessSum = 0;
      int sampleSize = bytes.length > 1000 ? 1000 : bytes.length;

      for (int i = 0; i < sampleSize; i++) {
        brightnessSum += bytes[i];
      }

      double averageBrightness = brightnessSum / sampleSize;
      debugPrint(
        'Average brightness: ${averageBrightness.toStringAsFixed(1)}/255',
      );

      if (averageBrightness < 100 && !_torchEnabled) {
        debugPrint('Dark environment detected, enabling torch');
        await _enableTorch();
      }
    } catch (e) {
      debugPrint('Error checking brightness: $e');
    }
  }

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

  Future<void> _continuousRead(String currentText) async {
    try {
      final lines = currentText.split('\n');

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
      } else if (lines.length <= _continuousReadLineIndex) {
        _continuousReadLineIndex = lines.length;
        debugPrint('Continuing reading, no new lines to read yet');
      }
    } catch (e) {
      debugPrint('Error in continuous read: $e');
    }
  }

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
    _stableReadTimer?.cancel();
    _pendingStableText = '';
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
