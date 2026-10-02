// lib/screens/scene_captioning_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/scene_captioning_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';

class SceneCaptioningScreen extends StatefulWidget {
  const SceneCaptioningScreen({super.key});
  @override State<SceneCaptioningScreen> createState() => _SceneCaptioningScreenState();
}

class _SceneCaptioningScreenState extends State<SceneCaptioningScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {

  final SceneCaptioningService _svc = SceneCaptioningService();
  final TtsService _tts = TtsService();

  CameraController? _cam;
  List<CameraDescription> _cameras = [];
  bool _camReady = false;

  SceneCaptioningResult? _last;
  SceneCaptioningResult? _prev;

  bool _capturing = false, _scanning = false, _isSpeaking = false;
  bool _keepScanning = false;
  String _status = '';
  int _scanNo = 0;

  bool get isHindi => _tts.isHindi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _status = isHindi ? 'आरंभ किया जा रहा है…' : 'Initializing…';
    initVolumeButtonListener();
    _initAll();
  }

  Future<void> _initAll() async {
    _initCamera();
    _tts.speakLocalized(
      'Understand Environment. I will describe what is in front of you.',
      'दृश्य वर्णन। मैं आपके सामने क्या है बताउंगा।',
    );
  }

  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) { _keepScanning = false; _cam?.dispose(); }
    else if (s == AppLifecycleState.resumed) _initCamera();
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keepScanning = false; _cam?.dispose(); _tts.stop();
    super.dispose();
  }

  @override Future<void> onVolumeUp() async {
    if (_scanning) { _stopScan(); } else { _startScan(); }
  }

  @override Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final isRepeat = cmd.contains('repeat') || cmd.contains('phir')   || cmd.contains('batao') || cmd.contains('dobara');
    final isScan   = cmd.contains('scan')   || cmd.contains('again')  || cmd.contains('dubara') || cmd.contains('kro') || cmd.contains('describe');
    final isStop   = cmd.contains('stop')   || cmd.contains('ruko')   || cmd.contains('band');
    if (isStop)    { _stopScan();  await _tts.speak(hi ? 'रुक गया।' : 'Stopped.'); }
    else if (isScan)   { _startScan(); await _tts.speak(hi ? 'दोबारा देख रहा हूँ।' : 'Scanning again.'); }
    else if (isRepeat) {
      if (_last != null) { setState(() => _isSpeaking = true); await _tts.speak(_last!.caption); setState(() => _isSpeaking = false); }
      else await _tts.speak(hi ? 'अभी कुछ नहीं मिला।' : 'Nothing captured yet.');
    } else {
      await _tts.speak(hi ? 'कमांड समझ नहीं आई।' : 'Say "describe again" or "repeat".');
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) { setState(() => _status = isHindi ? 'कोई कैमरा नहीं मिला।' : 'No camera'); return; }
      final ctrl = CameraController(_cameras.first, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      if (!mounted) return;
      setState(() {
        _cam = ctrl;
        _camReady = true;
        _status = isHindi ? '2 सेकंड में शुरू हो रहा है…' : 'Starting in 2 seconds…';
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _startScan();
    } catch (e) { setState(() => _status = isHindi ? 'कैमरा त्रुटि: $e' : 'Camera error: $e'); }
  }

  void _startScan() {
    if (_scanning) return;
    _keepScanning = true;
    setState(() { _scanning = true; _status = isHindi ? 'स्कैन किया जा रहा है…' : 'Scanning…'; });
    _loop();
  }

  void _stopScan() {
    _keepScanning = false;
    setState(() { _scanning = false; _status = isHindi ? 'रुका हुआ।' : 'Paused.'; });
  }

  Future<void> _loop() async {
    while (_keepScanning && mounted) {
      await _capture();
    }
  }

  Future<void> _capture() async {
    if (_capturing || !_camReady || _cam == null) return;
    _scanNo++;
    setState(() { _capturing = true; });
    try {
      final List<Uint8List> frames = [];
      for (int i = 1; i <= 3; i++) {
        if (!_keepScanning || !mounted) return;
        setState(() => _status = isHindi ? 'फ़्रेम $i/3 लिया जा रहा है…' : 'Taking frame $i/3…');
        final photo = await _cam!.takePicture();
        final bytes = await photo.readAsBytes();
        frames.add(bytes);
        if (!_keepScanning || !mounted) return;
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!_keepScanning || !mounted) return;
      setState(() => _status = isHindi ? 'वातावरण का विश्लेषण किया जा रहा है…' : 'Analyzing environment…');

      final result = await _svc.captureSceneCaptioning(frames);
      if (!mounted) return;

      if (result != null && result.caption.isNotEmpty) {
        final isNew = !result.isSimilarTo(_prev);
        setState(() { _prev = _last; _last = result; _status = isHindi ? '✓ वातावरण कैप्चर किया गया' : '✓ Environment captured'; });
        if (isNew) {
          setState(() => _isSpeaking = true);
          await _tts.speak(result.caption, awaitCompletion: true);
          if (mounted) setState(() => _isSpeaking = false);
        }
      } else {
        setState(() => _status = isHindi ? 'वातावरण का वर्णन नहीं किया जा सका।' : 'Could not describe environment.');
      }

      if (_keepScanning && mounted) {
        setState(() => _status = isHindi ? '2 सेकंड प्रतीक्षा की जा रही है…' : 'Waiting 2 seconds…');
        await Future.delayed(const Duration(seconds: 2));
      }
    } catch (e) {
      setState(() => _status = isHindi ? 'त्रुटि: $e' : 'Error: $e');
      if (_keepScanning && mounted) {
        await Future.delayed(const Duration(seconds: 2));
      }
    } finally { if (mounted) setState(() => _capturing = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () { _keepScanning = false; Navigator.pop(context); },
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isHindi ? 'दृश्य वर्णन' : 'Understand Environment', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          Text(isMixinListening ? (isHindi ? '🎤 सुन रहा हूँ…' : '🎤 Listening…') : (isHindi ? 'वॉल्यूम ↑ = स्कैन/रोकें  वॉल्यूम ↓ = होम' : 'Vol↑ = scan/pause  Vol↓ = home'),
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
        actions: [
          if (_last != null) IconButton(
            icon: Icon(Icons.volume_up, color: _isSpeaking ? Colors.tealAccent : Colors.white),
            onPressed: () { if (_last != null) _tts.speak(_last!.caption); },
          ),
        ],
      ),
      body: Column(children: [
        Expanded(flex: 3, child: _buildCamera()),
        _buildStatus(),
        if (_last != null) _buildCaption(),
        _buildControls(),
      ]),
    );
  }

  Widget _buildCamera() {
    if (!_camReady || _cam == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_cam!),
      if (_scanning) Container(decoration: BoxDecoration(border: Border.all(color: Colors.tealAccent.withOpacity(0.6), width: 2.5))),
      if (_capturing) Container(color: Colors.black38, child: const Center(child: CircularProgressIndicator(color: Colors.tealAccent))),
      if (isMixinListening) Positioned(top: 12, left: 12,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(20)),
          child: Text(isHindi ? '🎤 सुन रहा हूँ…' : '🎤 Listening…', style: const TextStyle(color: Colors.tealAccent, fontSize: 12)))),
    ]);
  }

  Widget _buildStatus() => Container(
    width: double.infinity, color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Text(_status, style: TextStyle(color: _scanning ? Colors.tealAccent : Colors.white60, fontSize: 12)));

  Widget _buildCaption() => Container(
    constraints: const BoxConstraints(maxHeight: 120),
    color: Colors.grey[850], padding: const EdgeInsets.all(14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_last!.environmentLabel.toUpperCase(),
          style: const TextStyle(color: Colors.tealAccent, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text(_last!.caption, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4), maxLines: 4, overflow: TextOverflow.ellipsis),
    ]));

  Widget _buildControls() => Container(
    color: Colors.black, padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Row(children: [
      Expanded(flex: 2, child: ElevatedButton.icon(
        onPressed: _camReady ? (_scanning ? _stopScan : _startScan) : null,
        icon: Icon(_scanning ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 26),
        label: Text(_scanning ? (isHindi ? 'रोकें' : 'Pause') : (isHindi ? 'शुरू करें' : 'Resume'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _scanning ? Colors.orange : Colors.tealAccent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
      const SizedBox(width: 12),
      Expanded(child: ElevatedButton.icon(
        onPressed: _last != null ? () => _tts.speak(_last!.caption) : null,
        icon: const Icon(Icons.replay, size: 22),
        label: Text(isHindi ? 'दोहराएं' : 'Repeat', style: const TextStyle(fontSize: 15)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey[800], foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
    ]));
}