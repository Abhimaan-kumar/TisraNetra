// lib/screens/read_anything_screen.dart
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/read_anything_service.dart';
import '../services/tts_service.dart';
import '../utils/image_utils.dart';
import '../widgets/volume_button_mixin.dart';

// Sharpness (Laplacian variance) is now computed in a background isolate.
// See lib/utils/image_utils.dart

enum _ScanState { idle, scanning, processing, reading, done }

extension _Label on _ScanState {
  String get label => ['Idle','Scanning','Processing','Reading','Done'][index];
}

class ReadAnythingScreen extends StatefulWidget {
  const ReadAnythingScreen({super.key});
  @override State<ReadAnythingScreen> createState() => _ReadAnythingScreenState();
}

class _ReadAnythingScreenState extends State<ReadAnythingScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin, VolumeButtonMixin {

  final ReadAnythingService _service   = ReadAnythingService();
  final TtsService          _ttsService = TtsService();

  CameraController? _cam;
  bool _camReady = false;

  _ScanState _state = _ScanState.idle;
  String _status = 'Point camera at text';

  double _sharpness = 0;
  int    _stableFrames = 0;
  static const int    _stableNeeded  = 3;
  static const double _sharpThresh   = 120.0;

  Timer? _scanTimer;
  String _extractedText = '';
  List<TextSegment> _segments = [];
  bool _isSpeaking = false;
  int  _captures   = 0;

  late final AnimationController _sharpAnim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));

  static const _green  = Color(0xFF00E676);
  static const _amber  = Color(0xFFFFD740);
  static const _cyan   = Color(0xFF18FFFF);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _initCamera();
    _ttsService.speakLocalized(
        'Read text screen. Point your camera at any text and I will read it automatically.',
        'टेक्स्ट पढ़ने वाली स्क्रीन। अपना कैमरा किसी भी टेक्स्ट की ओर करें और मैं उसे स्वचालित रूप से पढ़ूँगा।');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) { _stopScan(); _cam?.dispose(); }
    else if (state == AppLifecycleState.resumed) _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopScan(); _cam?.dispose(); _sharpAnim.dispose();
    _ttsService.stop(); _service.dispose();
    super.dispose();
  }

  // ── VolumeButtonMixin ──────────────────────────────────────────────────────

  @override
  Future<void> onVolumeUp() async => _scanAgain();

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final isHindi = lang == 'hi';

    final isScan   = cmd.contains('scan')   || cmd.contains('dubara') ||
                     cmd.contains('again')  || cmd.contains('kro')    ||
                     cmd.contains('padhna') || cmd.contains('scan again');
    final isRepeat = cmd.contains('repeat') || cmd.contains('phir')   ||
                     cmd.contains('padho')  || cmd.contains('replay') ||
                     cmd.contains('read again');
    final isStop   = cmd.contains('stop')   || cmd.contains('ruko')   ||
                     cmd.contains('band');

    if (isStop) {
      _stopScan(); _ttsService.stop();
      await _ttsService.speak(isHindi ? 'रुक गया।' : 'Stopped.');
    } else if (isScan) {
      _scanAgain();
      await _ttsService.speak(isHindi ? 'फिर से स्कैन कर रहा हूँ।' : 'Scanning again.');
    } else if (isRepeat) {
      await _ttsService.speak(isHindi ? 'दोबारा पढ़ रहा हूँ।' : 'Repeating.');
      await _repeatText();
    } else {
      await _ttsService.speak(isHindi
          ? 'कमांड समझ नहीं आई। "दोबारा पढ़ो" या "स्कैन करो" बोलें।'
          : 'Command not understood. Say "repeat" or "scan again".');
    }
  }

  // ── Camera ─────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) { _setStatus('No camera found'); return; }
      final ctrl = CameraController(cams.first, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() { _cam = ctrl; _camReady = true; });
      _startScan();
    } catch (e) { _setStatus('Camera error: $e'); }
  }

  // ── Scan loop ───────────────────────────────────────────────────────────────

  void _startScan() {
    if (_state == _ScanState.reading) return;
    _setState(_ScanState.scanning);
    _stableFrames = 0;
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => _checkFrame());
  }

  void _stopScan() { _scanTimer?.cancel(); _scanTimer = null; }

  Future<void> _checkFrame() async {
    if (_cam == null || !_camReady || _state != _ScanState.scanning) return;
    try {
      final photo = await _cam!.takePicture();
      final bytes = await photo.readAsBytes();
      final sharp = await computeLaplacianVariance(bytes);
      if (!mounted) return;
      setState(() {
        _sharpness = sharp;
      });
      _sharpAnim.animateTo((sharp / 400.0).clamp(0.0, 1.0), curve: Curves.easeOut);
      if (sharp >= _sharpThresh) {
        _stableFrames++;
        _setStatus('Sharp — hold still ($_stableFrames/$_stableNeeded)');
        if (_stableFrames >= _stableNeeded) {
          _stopScan();
          await _captureAndRead(photo.path);
        }
      } else {
        _stableFrames = 0;
        _setStatus(sharp < 30 ? 'No text visible — point camera at text' : 'Move closer or hold steady');
      }
    } catch (e) { print('Frame check: $e'); }
  }

  Future<void> _captureAndRead(String path) async {
    _captures++;
    _setState(_ScanState.processing);
    _setStatus('Reading text…');
    final result = await _service.extractText(path);
    if (!mounted) return;
    if (!result.hasText || result.text.isEmpty) {
      _setStatus('No text found — scanning again');
      await _ttsService.speakLocalized('No text found. Scanning again.', 'कोई टेक्स्ट नहीं मिला। फिर से स्कैन कर रहा हूँ।');
      await Future.delayed(const Duration(seconds: 1));
      _startScan();
      return;
    }
    setState(() { _extractedText = result.text; _segments = result.segments; });
    _setState(_ScanState.reading);
    _setStatus('Reading aloud…');
    setState(() => _isSpeaking = true);
    await _ttsService.speakSegments(result.segments);
    if (mounted) {
      setState(() => _isSpeaking = false);
      _setState(_ScanState.done);
      _setStatus('Done — press volume up to scan again');
    }
  }

  Future<void> _repeatText() async {
    if (_segments.isEmpty) { await _ttsService.speakLocalized('Nothing read yet.', 'अभी तक कुछ नहीं पढ़ा गया।'); return; }
    await _ttsService.speakSegments(_segments);
  }

  void _scanAgain() {
    _ttsService.stop();
    setState(() { _extractedText = ''; _segments = []; _stableFrames = 0; _sharpness = 0; });
    _sharpAnim.animateTo(0);
    _startScan();
  }

  void _setState(_ScanState s) { if (mounted) setState(() => _state = s); }
  void _setStatus(String m)    { if (mounted) setState(() => _status = m); }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () { _stopScan(); Navigator.pop(context); },
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Read Text',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          Text('Captures: $_captures  |  ${_state.label}  ${isMixinListening ? "🎤" : ""}',
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
        actions: [
          if (_extractedText.isNotEmpty)
            IconButton(
              icon: Icon(Icons.volume_up, color: _isSpeaking ? _cyan : Colors.white),
              onPressed: _repeatText,
            ),
        ],
      ),
      body: Column(children: [
        Expanded(flex: 5, child: _buildCamera()),
        _buildSharpBar(),
        _buildStatus(),
        if (_extractedText.isNotEmpty) _buildTextPanel(),
        _buildControls(),
      ]),
    );
  }

  Widget _buildCamera() {
    if (!_camReady || _cam == null) return const Center(
        child: CircularProgressIndicator(color: Colors.white));

    final borderColor = _sharpness >= _sharpThresh ? _green : _amber;
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_cam!),
      if (_state == _ScanState.scanning)
        _AnimBorder(color: borderColor),
      if (_state == _ScanState.processing)
        Container(color: Colors.black54,
          child: const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
            SizedBox(height: 16),
            Text('Extracting text…', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          ]))),
      if (_state == _ScanState.scanning)
        Center(child: _ViewfinderGuide(isSharp: _sharpness >= _sharpThresh)),
      if (_state == _ScanState.done || _state == _ScanState.reading)
        Positioned(top: 16, left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: const Color(0xCC000000),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _green.withOpacity(0.7))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_isSpeaking ? Icons.volume_up : Icons.check_circle, color: _green, size: 16),
              const SizedBox(width: 6),
              Text(_isSpeaking ? 'Reading aloud' : 'Text captured',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          )),
      if (isMixinListening)
        Positioned(bottom: 14, left: 0, right: 0,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _cyan.withOpacity(0.6))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _PulseDot(color: _cyan),
              const SizedBox(width: 8),
              const Text('Listening for command…', style: TextStyle(color: Colors.white, fontSize: 13)),
            ]),
          ))),
    ]);
  }

  Widget _buildSharpBar() => AnimatedBuilder(
    animation: _sharpAnim,
    builder: (_, __) {
      final v = _sharpAnim.value;
      final c = v > 0.4 ? _green : v > 0.15 ? _amber : Colors.redAccent;
      return Container(height: 4, color: Colors.grey[900],
        child: FractionallySizedBox(widthFactor: v, alignment: Alignment.centerLeft,
          child: Container(color: c)));
    });

  Widget _buildStatus() => Container(
    width: double.infinity, color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Row(children: [
      if (_state == _ScanState.scanning) _PulseDot(
          color: _sharpness >= _sharpThresh ? _green : _amber),
      if (_state == _ScanState.reading) const Icon(Icons.volume_up, color: Colors.white70, size: 14),
      if (_state == _ScanState.done)    const Icon(Icons.check, color: Colors.green, size: 14),
      const SizedBox(width: 8),
      Expanded(child: Text(_status, style: TextStyle(
        color: _state == _ScanState.scanning
            ? (_sharpness >= _sharpThresh ? _green : _amber) : Colors.white70,
        fontSize: 12))),
    ]));

  Widget _buildTextPanel() => Container(
    constraints: const BoxConstraints(maxHeight: 160),
    color: const Color(0xFF1A1A2E),
    padding: const EdgeInsets.all(14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.text_fields, color: Colors.white54, size: 14),
        const SizedBox(width: 6),
        const Text('EXTRACTED TEXT', style: TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const Spacer(),
        GestureDetector(onTap: _repeatText, child: Row(children: [
          Icon(Icons.replay, color: _isSpeaking ? _cyan : Colors.white54, size: 14),
          const SizedBox(width: 4),
          Text('Repeat', style: TextStyle(color: _isSpeaking ? _cyan : Colors.white54, fontSize: 11)),
        ])),
      ]),
      const SizedBox(height: 8),
      Expanded(child: SingleChildScrollView(
        child: Text(_extractedText, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5)))),
    ]));

  Widget _buildControls() => Container(
    color: Colors.black,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    child: Row(children: [
      Expanded(flex: 2, child: ElevatedButton.icon(
        onPressed: _camReady ? (_state == _ScanState.scanning ? _stopScan : _scanAgain) : null,
        icon: Icon(_state == _ScanState.scanning ? Icons.stop_circle_outlined : Icons.document_scanner_outlined, size: 22),
        label: Text(_state == _ScanState.scanning ? 'Stop' : 'Scan Again',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _state == _ScanState.scanning ? Colors.orange : _cyan,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
      const SizedBox(width: 10),
      Expanded(child: ElevatedButton.icon(
        onPressed: _extractedText.isNotEmpty ? _repeatText : null,
        icon: Icon(_isSpeaking ? Icons.volume_up : Icons.replay, size: 20),
        label: const Text('Repeat', style: TextStyle(fontSize: 14)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey[800], foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey[900],
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      )),
    ]));
}

// ── Helpers ────────────────────────────────────────────────────────────────────

class _ViewfinderGuide extends StatelessWidget {
  final bool isSharp;
  const _ViewfinderGuide({required this.isSharp});
  @override
  Widget build(BuildContext context) {
    final color = isSharp ? const Color(0xFF00E676) : const Color(0xFFFFD740);
    return SizedBox(width: 220, height: 220,
        child: CustomPaint(painter: _CornerPainter(color: color)));
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  const _CornerPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round;
    const l = 28.0;
    final tl = Offset.zero; final tr = Offset(size.width, 0);
    final bl = Offset(0, size.height); final br = Offset(size.width, size.height);
    canvas.drawLine(tl, tl+Offset(l,0), p); canvas.drawLine(tl, tl+Offset(0,l), p);
    canvas.drawLine(tr, tr+Offset(-l,0), p); canvas.drawLine(tr, tr+Offset(0,l), p);
    canvas.drawLine(bl, bl+Offset(l,0), p); canvas.drawLine(bl, bl+Offset(0,-l), p);
    canvas.drawLine(br, br+Offset(-l,0), p); canvas.drawLine(br, br+Offset(0,-l), p);
  }
  @override bool shouldRepaint(_CornerPainter o) => o.color != color;
}

class _AnimBorder extends StatefulWidget {
  final Color color;
  const _AnimBorder({required this.color});
  @override State<_AnimBorder> createState() => _AnimBorderState();
}
class _AnimBorderState extends State<_AnimBorder> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  late final Animation<double> _a = Tween(begin: 0.3, end: 0.9).animate(_c);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: _a,
      builder: (_, __) => IgnorePointer(child: Container(decoration: BoxDecoration(
          border: Border.all(color: widget.color.withOpacity(_a.value), width: 2.5)))));
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override State<_PulseDot> createState() => _PulseDotState();
}
class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: _c,
      builder: (_, __) => Container(width: 10, height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle,
              color: widget.color.withOpacity(0.4 + 0.6 * _c.value))));
}