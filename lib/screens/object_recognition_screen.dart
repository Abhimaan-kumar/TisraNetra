// lib/screens/object_recognition_screen.dart
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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
  bool _keepScanning = false;

  String _status  = 'Initializing…';
  int _scanNo     = 0;
  int _successNo  = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _initCamera();
    _tts.speak('Object recognition. Scanning for objects automatically.');
  }

  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) { _keepScanning = false; _cam?.dispose(); }
    else if (s == AppLifecycleState.resumed) _initCamera();
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keepScanning = false; _cam?.dispose(); _tts.dispose(); _svc.dispose();
    super.dispose();
  }

  // ── VolumeButtonMixin ────────────────────────────────────────────────────
  @override Future<void> onVolumeUp() async {
    if (_scanning) { _stopScan(); } else { _startScan(); }
  }

  @override Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final isRepeat = cmd.contains('repeat') || cmd.contains('phir')   || cmd.contains('dobara') || cmd.contains('batao');
    final isScan   = cmd.contains('scan')   || cmd.contains('again')  || cmd.contains('dubara') || cmd.contains('kro') || cmd.contains('start');
    final isStop   = cmd.contains('stop')   || cmd.contains('ruko')   || cmd.contains('band');
    if (isStop)    { _stopScan();  await _tts.speak(hi ? 'रुक गया।' : 'Stopped.'); }
    else if (isScan)   { _startScan(); await _tts.speak(hi ? 'स्कैन शुरू कर रहा हूँ।' : 'Starting scan.'); }
    else if (isRepeat) {
      if (_last != null) { setState(() => _isSpeaking = true); await _tts.speak(_last!.spokenText); setState(() => _isSpeaking = false); }
      else await _tts.speak(hi ? 'अभी कुछ नहीं मिला।' : 'Nothing detected yet.');
    } else {
      await _tts.speak(hi ? 'कमांड समझ नहीं आई।' : 'Say "scan again", "repeat", or "stop".');
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
    if (_scanning) return;
    _keepScanning = true;
    setState(() { _scanning = true; _status = 'Scanning…'; });
    _tts.speak('Scanning started.');
    if (!mounted || !_camReady || _cam == null) return;
    _cam!.startImageStream((image) => _processFrame(image));
  }

  void _stopScan() {
    _keepScanning = false;
    setState(() { _scanning = false; _status = 'Paused.'; });
    _tts.speak('Scanning paused.');
    if (_cam?.value.isStreamingImages ?? false) {
      _cam!.stopImageStream();
    }
  }

  DateTime _lastProcessTime = DateTime.now();
  DateTime _lastSpeakTime = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _processFrame(CameraImage image) async {
    if (_recognizing || !_scanning || !mounted) return;
    
    // Run detection every 300ms for real-time bounding boxes
    if (DateTime.now().difference(_lastProcessTime).inMilliseconds < 300) return;
    
    _recognizing = true;
    _lastProcessTime = DateTime.now();
    
    try {
      final result = await _svc.recognizeObjects(image, _cam!.description.sensorOrientation);
      if (!mounted) return;
      
      if (result == null || result.objects.isEmpty) {
        setState(() { 
          _last = null; 
          _status = 'Scanning area...'; 
        });
      } else {
        _successNo++;
        setState(() {
          _last = result;
          _status = '${result.objects.length} object(s) detected';
        });

        final timeSinceSpeak = DateTime.now().difference(_lastSpeakTime).inMilliseconds;
        final isNew = !result.isSimilarTo(_prev);

        // Only speak every 2.5 seconds OR if the scene completely changed
        if (timeSinceSpeak > 2500 || (isNew && timeSinceSpeak > 1000)) {
          _prev = result;
          _lastSpeakTime = DateTime.now();
          setState(() => _isSpeaking = true);
          await _tts.speak(result.spokenText);
          if (mounted) setState(() => _isSpeaking = false);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _recognizing = false);
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
          onPressed: () { _keepScanning = false; _tts.speak('Going back'); Navigator.pop(context); },
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Object Recognition', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          Text('Scans: $_scanNo  ${isMixinListening ? "🎤 Listening…" : "Vol↑ = scan/pause"}',
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
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
      if (_scanning) _ScanBorder(),
      if (_recognizing) Positioned(bottom: 14, left: 0, right: 0,
        child: Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.cyanAccent.withOpacity(0.5))),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2)),
            SizedBox(width: 8), Text('Analyzing…', style: TextStyle(color: Colors.white, fontSize: 13)),
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
    child: Text(_status, style: TextStyle(color: _scanning ? Colors.cyanAccent : Colors.white60, fontSize: 12)));

  Widget _chips() => Container(
    height: 52, color: Colors.grey[850],
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _last!.objects.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.cyanAccent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.cyanAccent.withOpacity(0.5))),
        child: Text(_last!.objects[i].name,
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.w600))),
    ));

  Widget _controls() => Container(
    color: Colors.black, padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Row(children: [
      Expanded(flex: 2, child: ElevatedButton.icon(
        onPressed: _camReady ? (_scanning ? _stopScan : _startScan) : null,
        icon: Icon(_scanning ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 26),
        label: Text(_scanning ? 'Pause' : 'Resume', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _scanning ? Colors.orange : Colors.cyanAccent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
      const SizedBox(width: 12),
      Expanded(child: ElevatedButton.icon(
        onPressed: _last != null ? () => _tts.speak(_last!.spokenText) : null,
        icon: const Icon(Icons.replay, size: 22),
        label: const Text('Repeat', style: TextStyle(fontSize: 15)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey[800], foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
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
      final obj = objects[i]; final color = _colors[i % _colors.length];
      final rect = Rect.fromLTWH(obj.left*size.width, obj.top*size.height, obj.width*size.width, obj.height*size.height);
      canvas.drawRect(rect, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5);
      _drawCorners(canvas, rect, color);
      final tp = TextPainter(text: TextSpan(text: '  ${obj.name}  ',
          style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700, background: Paint()..color = color)),
          textDirection: TextDirection.ltr)..layout();
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
  @override State<_ScanBorder> createState() => _ScanBorderState();
}
class _ScanBorderState extends State<_ScanBorder> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  late final Animation<double> _a = Tween(begin: 0.3, end: 1.0).animate(_c);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: _a,
      builder: (_, __) => Container(decoration: BoxDecoration(border: Border.all(color: Colors.cyanAccent.withOpacity(_a.value), width: 2.5))));
}