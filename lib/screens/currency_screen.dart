import 'package:flutter/material.dart';
import 'registration.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_screen.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'dart:async';

class CurrencyScreen extends StatefulWidget {
  const CurrencyScreen({super.key});

  @override
  State<CurrencyScreen> createState() => _CurrencyScreenState();
}

class _CurrencyScreenState extends State<CurrencyScreen>
    with WidgetsBindingObserver {
  late CameraController _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer();
  late ObjectDetector _objectDetector;
  FlutterTts flutterTts = FlutterTts();
  final SpeechToText _speechToText = SpeechToText();
  bool isCameraInitialized = false;
  bool isDetecting = false;
  String detectedCurrency = 'Waiting for currency...';
  int totalAmount = 0;
  Map<String, int> denominationCount = {};
  bool isSpeaking = false;
  Timer? detectionTimer;
  String? lastDetectedDenomination;
  Map<String, DateTime> denominationLastCountedTime = {};
  bool _isListeningForCommands = false;
  DateTime? _lastVoiceCommandAt;
  String? _pendingDenomination;
  String? _pendingNoteKey;
  int _pendingDetectionCount = 0;
  Set<String> _detectedSerialNumbers = {}; // Track unique serial numbers
  String? _lastSerialNumber;

  // Indian rupee denominations
  final Map<String, int> rupeeValues = {
    '2000': 2000,
    '500': 500,
    '200': 200,
    '100': 100,
    '50': 50,
    '20': 20,
    '10': 10,
    '5': 5,
    '2': 2,
    '1': 1,
  };

  // English denomination names for blind users
  final Map<String, String> currencyNameEnglish = {
    '2000': 'Two Thousand',
    '500': 'Five Hundred',
    '200': 'Two Hundred',
    '100': 'One Hundred',
    '50': 'Fifty',
    '20': 'Twenty',
    '10': 'Ten',
    '5': 'Five',
    '2': 'Two',
    '1': 'One',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeObjectDetector();
    _initializeCamera();
    _initializeTTS();
    _initializeSpeechCommands();
  }

  void _initializeObjectDetector() {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: false,
    );
    _objectDetector = ObjectDetector(options: options);
  }

  Future<void> _initializeTTS() async {
    await flutterTts.setLanguage('en-US');
    await flutterTts.setSpeechRate(0.45);
    await flutterTts.setVolume(1.0);
    await flutterTts.awaitSpeakCompletion(true);
  }

  Future<void> _initializeSpeechCommands() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _showErrorSnackBar(
        'Microphone permission is required for voice commands',
      );
      return;
    }

    final isAvailable = await _speechToText.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _isListeningForCommands = false;
          _startListeningForCommands();
        }
      },
      onError: (error) {
        _isListeningForCommands = false;
      },
    );

    if (isAvailable) {
      _startListeningForCommands();
    }
  }

  Future<void> _startListeningForCommands() async {
    if (!mounted || !_speechToText.isAvailable || _isListeningForCommands) {
      return;
    }

    _isListeningForCommands = true;
    await _speechToText.listen(
      onResult: (result) {
        final heardText = result.recognizedWords.trim().toLowerCase();
        if (heardText.isNotEmpty) {
          _handleVoiceCommand(heardText);
        }
      },
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      localeId: 'en_IN',
      cancelOnError: true,
    );
  }

  void _handleVoiceCommand(String heardText) {
    final isResetCommand =
        heardText.contains('reset') ||
        heardText.contains('wapas se') ||
        heardText.contains('vaapas se') ||
        heardText.contains('वापस से') ||
        heardText.contains('रीसेट');

    final isBackCommand =
        heardText.contains('back') ||
        heardText.contains('go back') ||
        heardText.contains('main page') ||
        heardText.contains('home') ||
        heardText.contains('peeche') ||
        heardText.contains('piche') ||
        heardText.contains('पीछे') ||
        heardText.contains('वापस');

    if (!isResetCommand && !isBackCommand) {
      return;
    }

    final now = DateTime.now();
    if (_lastVoiceCommandAt != null &&
        now.difference(_lastVoiceCommandAt!).inMilliseconds < 2000) {
      return;
    }

    _lastVoiceCommandAt = now;
    if (isBackCommand) {
      _goBackToMain();
      return;
    }

    _resetDetection();
  }

  Future<void> _goBackToMain() async {
    if (_isListeningForCommands) {
      await _speechToText.stop();
      _isListeningForCommands = false;
    }

    if (!mounted) {
      return;
    }

    Navigator.maybePop(context);
  }

  Future<void> _initializeCamera() async {
    PermissionStatus cameraStatus = await Permission.camera.request();

    if (cameraStatus.isGranted) {
      try {
        final cameras = await availableCameras();
        if (cameras.isNotEmpty) {
          _cameraController = CameraController(
            cameras[0],
            ResolutionPreset.high,
            enableAudio: false,
          );

          await _cameraController.initialize();

          _startDetectionTimer();

          if (mounted) {
            setState(() {
              isCameraInitialized = true;
              detectedCurrency = 'Scanning for currency...';
            });
          }
        }
      } catch (e) {
        print('Error initializing camera: $e');
        _showErrorSnackBar('Failed to initialize camera');
      }
    } else {
      _showErrorSnackBar('Camera permission is required');
    }
  }

  void _startDetectionTimer() {
    detectionTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (isCameraInitialized && !isDetecting) {
        await _performDetection();
      }
    });
  }

  Future<void> _performDetection() async {
    if (!isCameraInitialized) return;

    isDetecting = true;

    try {
      final image = await _cameraController.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);

      // Stage 1: Try object detection (helper only, do not block OCR)
      try {
        await _objectDetector.processImage(inputImage);
      } catch (_) {
        // Continue with OCR even if object detection fails for this frame
      }

      // Stage 2: Run text recognition
      final recognizedText = await _textRecognizer.processImage(inputImage);

      // Only analyze if we got substantial text
      if (recognizedText.text.trim().isEmpty) {
        _pendingDenomination = null;
        _pendingDetectionCount = 0;
        if (mounted) {
          setState(() {
            detectedCurrency = 'No currency detected';
          });
        }
        return;
      }

      // Analyze text for currency denominations
      _analyzeCurrencyFromText(recognizedText.text);
    } catch (e) {
      print('Error during detection: $e');
    } finally {
      isDetecting = false;
    }
  }

  void _analyzeCurrencyFromText(String text) {
    final detectedDenomination = _extractDetectedDenomination(text);

    if (detectedDenomination == null) {
      _pendingDenomination = null;
      _pendingNoteKey = null;
      _pendingDetectionCount = 0;
      _lastSerialNumber = null;
      if (mounted) {
        setState(() {
          detectedCurrency = 'No currency detected';
        });
      }
      return;
    }

    // Extract serial number to identify unique notes
    final serialNumber = _extractSerialNumber(text);
    final noteFingerprint = _buildNoteFingerprint(text, detectedDenomination);
    final noteKey = serialNumber != null && serialNumber.isNotEmpty
        ? '$detectedDenomination-$serialNumber'
        : '$detectedDenomination-$noteFingerprint';

    if (_pendingDenomination == detectedDenomination &&
        _pendingNoteKey == noteKey) {
      _pendingDetectionCount += 1;
    } else {
      _pendingDenomination = detectedDenomination;
      _pendingNoteKey = noteKey;
      _lastSerialNumber = serialNumber;
      _pendingDetectionCount = 1;
    }

    // Require same denomination in at least 2 consecutive frames
    if (_pendingDetectionCount < 2) {
      return;
    }

    final value = rupeeValues[detectedDenomination];
    if (value == null) {
      return;
    }

    // Check if this is a new note by serial/fingerprint key
    final noteIdentifier = noteKey;

    if (_detectedSerialNumbers.contains(noteIdentifier)) {
      // Already counted this exact note
      return;
    }

    // Check if this denomination was shown recently (within 5 seconds)
    // This allows re-scanning after brief removal
    final now = DateTime.now();
    final lastCountTime = denominationLastCountedTime[detectedDenomination];

    final canCount =
        lastCountTime == null || now.difference(lastCountTime).inSeconds >= 5;

    // Count if it's a new stable note key OR enough time has passed for re-scan
    if (canCount || !_detectedSerialNumbers.contains(noteIdentifier)) {
      _detectedSerialNumbers.add(noteIdentifier);

      _updateCurrencyDisplay(detectedDenomination, value);
      _speakCurrencyDetected(detectedDenomination, value);
      lastDetectedDenomination = detectedDenomination;
      denominationLastCountedTime[detectedDenomination] = now;
      _pendingDetectionCount = 0;
      _pendingNoteKey = null;
    }
  }

  String? _extractDetectedDenomination(String rawText) {
    final normalizedText = rawText.toLowerCase().replaceAll('\n', ' ');

    const denominationPattern = '(2000|500|200|100|50|20|10|5|2|1)';
    final rupeeBeforeRegex = RegExp(
      r'(₹|rs\.?|rupee|rupees)\s*' + denominationPattern + r'\b',
      caseSensitive: false,
    );
    final rupeeAfterRegex = RegExp(
      r'\b' + denominationPattern + r'\s*(₹|rs\.?|rupee|rupees)',
      caseSensitive: false,
    );

    final beforeMatch = rupeeBeforeRegex.firstMatch(normalizedText);
    if (beforeMatch != null) {
      return beforeMatch.group(2);
    }

    final afterMatch = rupeeAfterRegex.firstMatch(normalizedText);
    if (afterMatch != null) {
      return afterMatch.group(1);
    }

    // Fallback for partial OCR: denomination without explicit ₹/rupee marker,
    // but only when other currency-context keywords are present.
    final hasCurrencyContext = RegExp(
      r'(reserve\s*bank|rbi|india|bharat|mahatma|gandhi|bank\s*note)',
      caseSensitive: false,
    ).hasMatch(normalizedText);

    if (!hasCurrencyContext) {
      return null;
    }

    final allDenomMatches = RegExp(
      r'(?<!\d)' + denominationPattern + r'(?!\d)',
      caseSensitive: false,
    ).allMatches(normalizedText);

    final counts = <String, int>{};
    for (final match in allDenomMatches) {
      final denom = match.group(1);
      if (denom == null) continue;
      counts[denom] = (counts[denom] ?? 0) + 1;
    }

    if (counts.isEmpty) {
      return null;
    }

    // Pick denomination that appears most often in OCR text.
    String? bestDenomination;
    int bestCount = 0;
    counts.forEach((denom, count) {
      if (count > bestCount) {
        bestDenomination = denom;
        bestCount = count;
      }
    });

    // Require at least 2 occurrences in fallback mode to reduce false positives.
    if (bestCount < 2) {
      return null;
    }

    return bestDenomination;
  }

  String _buildNoteFingerprint(String rawText, String denomination) {
    final cleaned = rawText
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^A-Z0-9 ]'), '')
        .trim();

    final core = cleaned.length > 30 ? cleaned.substring(0, 30) : cleaned;
    return '$denomination-$core';
  }

  String? _extractSerialNumber(String rawText) {
    // Indian currency serial numbers follow patterns:
    // - Typically 6-10 alphanumeric characters
    // - Format examples: "1AB234567", "A12B345678", "12A345678"
    // - Contains both letters and numbers

    final normalizedText = rawText
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');

    // Pattern 1: Letter followed by digits (common pattern)
    final pattern1 = RegExp(r'\b([A-Z]{1,3}\d{5,8})\b', caseSensitive: false);
    final match1 = pattern1.firstMatch(normalizedText);
    if (match1 != null) {
      return match1.group(1)?.toUpperCase();
    }

    // Pattern 2: Digits followed by letter and more digits
    final pattern2 = RegExp(
      r'\b(\d{1,3}[A-Z]{1,2}\d{5,7})\b',
      caseSensitive: false,
    );
    final match2 = pattern2.firstMatch(normalizedText);
    if (match2 != null) {
      return match2.group(1)?.toUpperCase();
    }

    // Pattern 3: Mixed alphanumeric (6-10 chars with both letters and numbers)
    final pattern3 = RegExp(r'\b([A-Z0-9]{6,10})\b', caseSensitive: false);
    final matches = pattern3.allMatches(normalizedText);

    for (final match in matches) {
      final candidate = match.group(1);
      if (candidate != null &&
          candidate.contains(RegExp(r'[A-Z]', caseSensitive: false)) &&
          candidate.contains(RegExp(r'\d'))) {
        // Must have both letters and numbers
        return candidate.toUpperCase();
      }
    }

    // If no clear serial found, create a hash of the full text as fingerprint
    return null;
  }

  void _updateCurrencyDisplay(String denomination, int value) {
    setState(() {
      // Mark that we've detected this denomination
      if (denominationCount.containsKey(denomination)) {
        denominationCount[denomination] = denominationCount[denomination]! + 1;
      } else {
        denominationCount[denomination] = 1;
      }
      // Add to total only once when detected
      totalAmount += value;
      detectedCurrency = '₹$denomination';
    });
  }

  Future<void> _speakCurrencyDetected(String denomination, int value) async {
    if (isSpeaking) return;

    isSpeaking = true;

    try {
      String currencyName = currencyNameEnglish[denomination] ?? denomination;

      // Speak in English - announce the actual currency value
      await flutterTts.setLanguage('en-US');
      await flutterTts.setVolume(1.0);
      await flutterTts.speak(
        'Detected: $currencyName rupees. Total: $totalAmount rupees',
      );

      // Wait for English to finish
      await Future.delayed(const Duration(milliseconds: 1500));

      // Speak in Hindi - announce the actual currency value
      await flutterTts.setLanguage('hi-IN');
      await flutterTts.setVolume(1.0);
      String hindiText = _getHindiDenomination(denomination);
      await flutterTts.speak(
        'पहचाना गया: $hindiText। कुल राशि: $totalAmount रुपये',
      );
    } catch (e) {
      print('Error speaking: $e');
    } finally {
      isSpeaking = false;
    }
  }

  String _getCountText(int count) {
    switch (count) {
      case 1:
        return 'One';
      case 2:
        return 'Two';
      case 3:
        return 'Three';
      case 4:
        return 'Four';
      case 5:
        return 'Five';
      default:
        return count.toString();
    }
  }

  String _getHindiCountText(int count, String hindiDenom) {
    final hindiCounts = {1: 'एक', 2: 'दो', 3: 'तीन', 4: 'चार', 5: 'पांच'};
    String countStr = hindiCounts[count] ?? count.toString();
    return '$countStr $hindiDenom नोट';
  }

  String _getHindiDenomination(String denomination) {
    final hindiMap = {
      '2000': 'दो हजार',
      '500': 'पांच सौ',
      '200': 'दो सौ',
      '100': 'एक सौ',
      '50': 'पचास',
      '20': 'बीस',
      '10': 'दस',
      '5': 'पांच',
      '2': 'दो',
      '1': 'एक',
    };

    return hindiMap[denomination] ?? 'रुपये';
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isCameraInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      detectionTimer?.cancel();
      _cameraController.dispose();
      _speechToText.stop();
      _isListeningForCommands = false;
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
      _startListeningForCommands();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    detectionTimer?.cancel();
    _cameraController.dispose();
    _textRecognizer.close();
    _objectDetector.close();
    _speechToText.stop();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rupee Detector'),
        backgroundColor: Colors.deepPurple,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _goBackToMain,
        ),
        actions: [
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
      body: !isCameraInitialized
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Initializing Camera...'),
                ],
              ),
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    flex: 6,
                    child: Container(
                      width: double.infinity,
                      color: Colors.black,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _cameraController.value.aspectRatio,
                          child: CameraPreview(_cameraController),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                        ),
                      ),
                      padding: const EdgeInsets.all(20.0),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Last Detected',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(color: Colors.white70),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              detectedCurrency,
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: Colors.greenAccent,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.deepPurple.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                children: [
                                  const Text(
                                    'Total Amount',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '₹$totalAmount',
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (denominationCount.isNotEmpty) ...[
                              const Text(
                                'Denominations Detected:',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: denominationCount.entries
                                    .map(
                                      (entry) => Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.greenAccent,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Text(
                                          '₹${entry.key} x${entry.value}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: _resetDetection,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Reset'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.deepPurple,
                                  ),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () => _speakTotalAmount(),
                                  icon: const Icon(Icons.volume_up),
                                  label: const Text('Speak Total'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.deepPurple,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: _goBackToMain,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                              ),
                              child: const Text('Back'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  void _resetDetection() async {
    if (_isListeningForCommands) {
      await _speechToText.stop();
      _isListeningForCommands = false;
    }

    setState(() {
      totalAmount = 0;
      denominationCount.clear();
      detectedCurrency = 'Waiting for detection...';
      lastDetectedDenomination = null;
      denominationLastCountedTime.clear();
      _pendingDenomination = null;
      _pendingNoteKey = null;
      _pendingDetectionCount = 0;
      _detectedSerialNumbers.clear();
      _lastSerialNumber = null;
    });
    _showErrorSnackBar('Detection reset');

    // Speak reset confirmation
    try {
      await flutterTts.setLanguage('en-US');
      await flutterTts.speak('Reset');

      await Future.delayed(const Duration(milliseconds: 500));

      await flutterTts.setLanguage('hi-IN');
      await flutterTts.speak('रीसेट');
    } catch (e) {
      print('Error speaking reset: $e');
    } finally {
      _startListeningForCommands();
    }
  }

  Future<void> _speakTotalAmount() async {
    if (totalAmount == 0) {
      await flutterTts.setLanguage('en-US');
      await flutterTts.setVolume(1.0);
      await flutterTts.speak('No currency detected yet');
      return;
    }

    try {
      // Build list of detected currency values in English
      List<String> detectedNames = [];
      List<String> hindiNames = [];

      denominationCount.forEach((denomination, count) {
        detectedNames.add(currencyNameEnglish[denomination] ?? denomination);
        hindiNames.add(_getHindiDenomination(denomination));
      });

      // Speak in English - list all detected currency values
      await flutterTts.setLanguage('en-US');
      await flutterTts.setVolume(1.0);
      String namesList = detectedNames.join(', ');
      await flutterTts.speak(
        'Detected currencies: $namesList. Total amount: $totalAmount rupees',
      );

      // Wait for English to finish
      await Future.delayed(const Duration(milliseconds: 1500));

      // Speak in Hindi
      await flutterTts.setLanguage('hi-IN');
      await flutterTts.setVolume(1.0);
      String hindiNamesList = hindiNames.join(', ');
      await flutterTts.speak(
        'पहचाने गए मुद्राएं: $hindiNamesList। कुल राशि: $totalAmount रुपये',
      );
    } catch (e) {
      print('Error speaking total: $e');
    }
  }
}
