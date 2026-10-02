// lib/screens/object_recognition_screen.dart
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/language_preference_service.dart';
import '../services/object_recognition_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';

class ObjectRecognitionScreen extends StatefulWidget {
  const ObjectRecognitionScreen({super.key});
  @override State<ObjectRecognitionScreen> createState() => _ObjectRecognitionScreenState();
}

class _ObjectRecognitionScreenState extends State<ObjectRecognitionScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {

  final ObjectRecognitionService _svc = ObjectRecognitionService();
  final TtsService _tts = TtsService();

  CameraController? _cam;
  List<CameraDescription> _cameras = [];
  bool _camReady = false;

  ObjectRecognitionResult? _last;
  ObjectRecognitionResult? _prev;

  bool _recognizing = false;
  bool _scanning    = false;
  bool _isSpeaking  = false;
  bool _isHighPrecisionLoading = false;

  String _status  = 'Initializing…';

  // Multi-frame temporal consensus smoothing buffer
  final List<List<String>> _historyBuffer = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _initCamera();
    _tts.speakLocalized(
      'High-precision object recognition. Scanning for objects automatically.',
      'उच्च सटीकता वस्तु पहचान। वस्तुओं की स्वचालित स्कैनिंग शुरू हो रही है।',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) {
      _cam?.dispose();
    } else if (s == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    _tts.stop();
    _svc.dispose();
    super.dispose();
  }

  // ── VolumeButtonMixin ────────────────────────────────────────────────────
  @override Future<void> onVolumeUp() async {
    if (_scanning) { _stopScan(); } else { _startScan(); }
  }

  @override Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final lowerCmd = cmd.toLowerCase();

    final isAiScan = lowerCmd.contains('ai') || lowerCmd.contains('precision') || lowerCmd.contains('detailed') ||
        lowerCmd.contains('gahan') || lowerCmd.contains('sateek') || lowerCmd.contains('spot check');
    final isRepeat = lowerCmd.contains('repeat') || lowerCmd.contains('phir') || lowerCmd.contains('dobara') || lowerCmd.contains('batao');
    final isScan   = lowerCmd.contains('scan')   || lowerCmd.contains('again')  || lowerCmd.contains('dubara') || lowerCmd.contains('kro') || lowerCmd.contains('start');
    final isStop   = lowerCmd.contains('stop')   || lowerCmd.contains('ruko')   || lowerCmd.contains('band');

    if (isAiScan) {
      await _runHighPrecisionAIScan();
    } else if (isStop) {
      _stopScan();
      await _tts.speak(hi ? 'रुक गया।' : 'Stopped.');
    } else if (isScan) {
      _startScan();
      await _tts.speak(hi ? 'स्कैन शुरू कर रहा हूँ।' : 'Starting scan.');
    } else if (isRepeat) {
      if (_last != null) {
        setState(() => _isSpeaking = true);
        await _tts.speak(_last!.spokenText);
        setState(() => _isSpeaking = false);
      } else {
        await _tts.speak(hi ? 'अभी कुछ नहीं मिला।' : 'Nothing detected yet.');
      }
    } else {
      await _tts.speak(hi ? 'कमांड समझ नहीं आई। "स्कैन", "हाई प्रेसिजन" या "स्टॉप" कहें।' : 'Say "scan again", "high precision", or "stop".');
    }
  }

  // ── Camera ───────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      await _svc.init();
      _cameras = await availableCameras();
      if (_cameras.isEmpty) { setState(() => _status = 'No camera'); return; }
      final ctrl = CameraController(_cameras.first, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      if (!mounted) return;
      setState(() { _cam = ctrl; _camReady = true; _status = 'Ready — starting…'; });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _startScan();
    } catch (e) { setState(() => _status = 'Camera error: $e'); }
  }

  void _startScan() {
    if (_scanning || _isHighPrecisionLoading) return;
    setState(() { _scanning = true; _status = 'Scanning with NMS accuracy…'; });
    _tts.speakLocalized('Scanning started.', 'स्कैनिंग शुरू।');
    if (!mounted || !_camReady || _cam == null) return;
    _cam!.startImageStream((image) => _processFrame(image));
  }

  void _stopScan() {
    setState(() { _scanning = false; _status = 'Paused.'; });
    _tts.speakLocalized('Scanning paused.', 'स्कैनिंग रुकी।');
    if (_cam?.value.isStreamingImages ?? false) {
      _cam!.stopImageStream();
    }
  }

  DateTime _lastProcessTime = DateTime.now();
  DateTime _lastSpeakTime = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _processFrame(CameraImage image) async {
    if (_recognizing || !_scanning || _isHighPrecisionLoading || !mounted) return;
    
    // Process frame every 350ms to ensure smooth high-accuracy processing
    if (DateTime.now().difference(_lastProcessTime).inMilliseconds < 350) return;
    
    _recognizing = true;
    _lastProcessTime = DateTime.now();
    
    try {
      final result = await _svc.recognizeObjects(image, _cam!.description.sensorOrientation);
      if (!mounted) return;
      
      if (result == null || result.objects.isEmpty) {
        _historyBuffer.clear();
        setState(() { 
          _last = null; 
          _status = 'Scanning area for objects...';
          _recognizing = false;
        });
      } else {
        // Multi-frame consensus filtering: require object label to persist across frames or have high score (>0.70)
        final currentNames = result.objects.map((o) => o.name).toList();
        _historyBuffer.add(currentNames);
        if (_historyBuffer.length > 3) _historyBuffer.removeAt(0);

        final confirmedObjects = result.objects.where((obj) {
          if (obj.confidence >= 0.70) return true;
          // Check if object appeared in at least 2 frames in buffer
          int appearances = 0;
          for (final frame in _historyBuffer) {
            if (frame.contains(obj.name)) appearances++;
          }
          return appearances >= 2;
        }).toList();

        if (confirmedObjects.isEmpty) {
          setState(() { _recognizing = false; });
          return;
        }

        final filteredResult = ObjectRecognitionResult(objects: confirmedObjects);

        final timeSinceSpeak = DateTime.now().difference(_lastSpeakTime).inMilliseconds;
        final isNew = !filteredResult.isSimilarTo(_prev);
        final shouldSpeak = timeSinceSpeak > 3000 || (isNew && timeSinceSpeak > 1200);

        setState(() {
          _last = filteredResult;
          _status = '${filteredResult.objects.length} object(s) accurately identified';
          _recognizing = false;
          if (shouldSpeak) _isSpeaking = true;
        });

        if (shouldSpeak) {
          _prev = filteredResult;
          _lastSpeakTime = DateTime.now();
          await _tts.speak(filteredResult.spokenText);
          if (mounted) setState(() => _isSpeaking = false);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _status = 'Error: $e'; _recognizing = false; });
    }
  }

  /// Trigger High Precision Cloud AI Scan (Gemini Vision)
  Future<void> _runHighPrecisionAIScan() async {
    if (!_camReady || _cam == null || _isHighPrecisionLoading) return;

    final wasScanning = _scanning;
    if (wasScanning) _stopScan();

    setState(() {
      _isHighPrecisionLoading = true;
      _status = 'Running High-Precision AI Vision analysis…';
    });

    final isHindi = LanguagePreferenceService().isHindi;
    await _tts.speak(isHindi ? 'सटीक AI विश्लेषण शुरू कर रहा हूँ।' : 'Running high precision AI spot check.');

    try {
      final XFile pic = await _cam!.takePicture();
      final bytes = await pic.readAsBytes();

      final aiResult = await _svc.recognizeObjectsGemini(bytes);

      if (!mounted) return;

      if (aiResult != null && aiResult.objects.isNotEmpty) {
        setState(() {
          _last = aiResult;
          _status = '✨ AI Vision: ${aiResult.objects.length} object(s) identified';
          _isHighPrecisionLoading = false;
        });
        await _tts.speak(aiResult.spokenText);
      } else {
        setState(() {
          _status = 'AI analysis could not confirm objects.';
          _isHighPrecisionLoading = false;
        });
        await _tts.speak(isHindi ? 'कोई स्पष्ट वस्तु नहीं पहचानी जा सकी।' : 'No distinct objects identified by AI.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'AI Scan error: $e';
          _isHighPrecisionLoading = false;
        });
      }
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
          onPressed: () { _tts.speakLocalized('Going back', 'वापस जा रहे हैं'); Navigator.pop(context); },
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Object Recognition', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          Text('Detecting Objects  ${isMixinListening ? "🎤 Listening…" : "Vol↑ = pause"}',
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
        ]),
        actions: [
          IconButton(
            icon: Icon(Icons.volume_up, color: _isSpeaking ? Colors.cyanAccent : Colors.white),
            onPressed: () { if (_last != null) _tts.speak(_last!.spokenText); },
          ),
        ],
      ),
      body: Column(children: [
        Expanded(flex: 3, child: _cameraView()),
        _statusBar(),
        if (_last != null && _last!.objects.isNotEmpty) _chips(),
        _controls(),
      ]),
    );
  }

  Widget _cameraView() {
    if (!_camReady || _cam == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_cam!),
      if (_last != null && _last!.objects.isNotEmpty)
        Positioned.fill(child: CustomPaint(painter: _BBoxPainter(objects: _last!.objects))),
      if (_scanning) const _ScanBorder(),
      if (_recognizing || _isHighPrecisionLoading) Positioned(bottom: 14, left: 0, right: 0,
        child: Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.75), borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _isHighPrecisionLoading ? Colors.amberAccent : Colors.cyanAccent.withOpacity(0.5))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(color: _isHighPrecisionLoading ? Colors.amberAccent : Colors.cyanAccent, strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(_isHighPrecisionLoading ? '✨ Gemini AI High Precision Analysis…' : 'Analyzing frame…',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
          ])))),
      if (isMixinListening) Positioned(top: 12, left: 12,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(20)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mic, color: Colors.cyanAccent, size: 14),
            SizedBox(width: 4),
            Text('Listening…', style: TextStyle(color: Colors.white, fontSize: 11)),
          ]))),
    ]);
  }

  Widget _statusBar() => Container(
    width: double.infinity, color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Text(_status, style: TextStyle(color: _isHighPrecisionLoading ? Colors.amberAccent : (_scanning ? Colors.cyanAccent : Colors.white60), fontSize: 12)));

  Widget _chips() => Container(
    height: 54, color: Colors.grey[850],
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _last!.objects.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, i) {
        final obj = _last!.objects[i];
        final confStr = obj.confidence < 1.0 ? ' ${(obj.confidence * 100).toInt()}%' : '';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _last!.isHighPrecisionAI ? Colors.amberAccent.withOpacity(0.15) : Colors.cyanAccent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _last!.isHighPrecisionAI ? Colors.amberAccent : Colors.cyanAccent.withOpacity(0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_last!.isHighPrecisionAI) ...[
                const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 13),
                const SizedBox(width: 4),
              ],
              Text(
                '${obj.displayName}$confStr',
                style: TextStyle(
                  color: _last!.isHighPrecisionAI ? Colors.amberAccent : Colors.cyanAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    ));

  Widget _controls() => Container(
    color: Colors.black, padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
    child: Row(children: [
      Expanded(child: ElevatedButton.icon(
        onPressed: _camReady && !_isHighPrecisionLoading ? (_scanning ? _stopScan : _startScan) : null,
        icon: Icon(_scanning ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 22),
        label: Text(_scanning ? 'Pause' : 'Scan', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _scanning ? Colors.orange : Colors.cyanAccent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
      const SizedBox(width: 8),
      Expanded(flex: 2, child: ElevatedButton.icon(
        onPressed: _camReady && !_isHighPrecisionLoading ? _runHighPrecisionAIScan : null,
        icon: const Icon(Icons.auto_awesome, size: 20),
        label: const Text('AI Spot Check', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.amber[700],
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
      const SizedBox(width: 8),
      ElevatedButton(
        onPressed: _last != null ? () => _tts.speak(_last!.spokenText) : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey[800], foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        child: const Icon(Icons.replay, size: 22),
      ),
    ]));
}

// ── Bounding box painter ──────────────────────────────────────────────────────
class _BBoxPainter extends CustomPainter {
  final List<DetectedObject> objects;
  static const _colors = [Colors.cyanAccent, Colors.yellowAccent, Colors.greenAccent,
    Colors.orangeAccent, Colors.pinkAccent, Colors.lightBlueAccent];
  const _BBoxPainter({required this.objects});

  @override void paint(Canvas canvas, Size size) {
    for (int i = 0; i < objects.length; i++) {
      final obj = objects[i];
      final color = _colors[i % _colors.length];
      final rect = Rect.fromLTWH(obj.left*size.width, obj.top*size.height, obj.width*size.width, obj.height*size.height);
      canvas.drawRect(rect, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5);
      _drawCorners(canvas, rect, color);

      final confLabel = obj.confidence < 1.0 ? ' (${(obj.confidence * 100).toInt()}%)' : '';
      final labelText = '  ${obj.displayName}$confLabel  ';

      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700, background: Paint()..color = color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(rect.left, rect.top > tp.height + 4 ? rect.top - tp.height - 4 : rect.top + 4));
    }
  }

  void _drawCorners(Canvas canvas, Rect r, Color c) {
    final p = Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 4.0..strokeCap = StrokeCap.round;
    const l = 18.0;
    canvas.drawLine(r.topLeft, r.topLeft+const Offset(l,0), p);
    canvas.drawLine(r.topLeft, r.topLeft+const Offset(0,l), p);
    canvas.drawLine(r.topRight, r.topRight+const Offset(-l,0), p);
    canvas.drawLine(r.topRight, r.topRight+const Offset(0,l), p);
    canvas.drawLine(r.bottomLeft, r.bottomLeft+const Offset(l,0), p);
    canvas.drawLine(r.bottomLeft, r.bottomLeft+const Offset(0,-l), p);
    canvas.drawLine(r.bottomRight, r.bottomRight+const Offset(-l,0), p);
    canvas.drawLine(r.bottomRight, r.bottomRight+const Offset(0,-l), p);
  }

  @override bool shouldRepaint(_BBoxPainter old) => old.objects != objects;
}

class _ScanBorder extends StatefulWidget {
  const _ScanBorder();
  @override State<_ScanBorder> createState() => _ScanBorderState();
}
class _ScanBorderState extends State<_ScanBorder> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  late final Animation<double> _a = Tween(begin: 0.3, end: 1.0).animate(_c);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: _a,
      builder: (_, __) => Container(decoration: BoxDecoration(border: Border.all(color: Colors.cyanAccent.withOpacity(_a.value), width: 2.5))));
}