// lib/screens/person_identification_screen.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/person_identification_service.dart';
import '../services/tts_service.dart';
import '../widgets/volume_button_mixin.dart';
import 'registration.dart';
import 'profile_screen.dart';

enum _ScreenState { idle, scanning, capturing, identifying, saving }

class PersonIdentificationScreen extends StatefulWidget {
  const PersonIdentificationScreen({super.key});
  @override
  State<PersonIdentificationScreen> createState() =>
      _PersonIdentificationScreenState();
}

class _PersonIdentificationScreenState extends State<PersonIdentificationScreen>
    with WidgetsBindingObserver, VolumeButtonMixin {
  final _svc = PersonIdentificationService();
  final _tts = TtsService();
  final _stt = stt.SpeechToText();
  final _name = TextEditingController();

  CameraController? _cam;
  bool _camReady = false;

  _ScreenState _state = _ScreenState.idle;
  String _status = 'Initializing…';
  bool _isSpeaking = false, _sttReady = false;

  bool _looping = false;
  int _scanNo = 0;

  String? _knownName;
  bool _showSaveUI = false;
  Uint8List? _capturedBytes;

  List<SavedPerson> _persons = [];

  DateTime? _lastUnknownSpoken;
  String? _lastKnownAnnounced;
  static const _unknownCooldown = Duration(seconds: 20);

  static const _accent = Color(0xFFBB86FC);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initVolumeButtonListener();
    _stt.initialize().then((v) => _sttReady = v);
    _initCam();
    _loadPersons();
    _tts.speak(
      'Person identification. Point camera at someone to identify them.',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) {
      _looping = false;
      _cam?.dispose();
    } else if (s == AppLifecycleState.resumed)
      _initCam();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _looping = false;
    _cam?.dispose();
    _tts.dispose();
    _name.dispose();
    _stt.cancel();
    super.dispose();
  }

  // ── VolumeButtonMixin ────────────────────────────────────────────────────
  @override
  Future<void> onVolumeUp() async {
    if (_looping) {
      _stopLoop();
    } else {
      _startLoop();
    }
  }

  @override
  Future<void> handleFeatureVoiceCommand(String cmd, String lang) async {
    final hi = lang == 'hi';
    final isRepeat =
        cmd.contains('repeat') ||
        cmd.contains('phir') ||
        cmd.contains('kaun') ||
        cmd.contains('batao');
    final isScan =
        cmd.contains('scan') ||
        cmd.contains('again') ||
        cmd.contains('dubara') ||
        cmd.contains('kro') ||
        cmd.contains('start');
    final isStop =
        cmd.contains('stop') || cmd.contains('ruko') || cmd.contains('band');
    final isSave =
        cmd.contains('save') ||
        cmd.contains('add') ||
        cmd.contains('jodo') ||
        cmd.contains('bachao');
    if (isStop) {
      _stopLoop();
      await _tts.speak(hi ? 'रुक गया।' : 'Stopped.');
    } else if (isScan) {
      if (_looping)
        _stopLoop();
      else
        _startLoop();
    } else if (isSave) {
      _openSaveDialog();
    } else if (isRepeat) {
      if (_knownName != null)
        await _tts.speak(hi ? 'यह ${_knownName} हैं।' : 'This is $_knownName');
      else if (_showSaveUI)
        await _tts.speak(
          hi
              ? 'अज्ञात व्यक्ति। सेव करें।'
              : 'Unknown person. Tap save to add them.',
        );
      else
        await _tts.speak(hi ? 'अभी कोई नहीं मिला।' : 'No person detected yet.');
    } else {
      await _tts.speak(
        hi ? 'कमांड समझ नहीं आई।' : 'Say "scan", "repeat", "stop", or "save".',
      );
    }
  }

  Future<void> _initCam() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus('No camera found');
        return;
      }
      final ctrl = CameraController(
        cams.first,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() {
        _cam = ctrl;
        _camReady = true;
      });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _startLoop();
    } catch (e) {
      _setStatus('Camera error: $e');
    }
  }

  Future<void> _loadPersons() async {
    final list = await _svc.loadPersons();
    if (mounted) setState(() => _persons = list);
  }

  void _startLoop() {
    if (_looping) return;
    _looping = true;
    setState(() {
      _state = _ScreenState.scanning;
      _status = 'Scanning…';
    });
    _tts.speak('Scanning started.');
    _loop();
  }

  void _stopLoop() {
    _looping = false;
    setState(() {
      _state = _ScreenState.idle;
      _status = 'Paused.';
    });
  }

  Future<void> _loop() async {
    while (_looping && mounted) {
      await _scanOnce();
      if (_looping && mounted) await Future.delayed(const Duration(seconds: 4));
    }
  }

  Future<void> _scanOnce() async {
    if (!_camReady || _cam == null || _state == _ScreenState.saving) return;
    _scanNo++;
    setState(() {
      _state = _ScreenState.capturing;
      _status = 'Scan #$_scanNo — capturing…';
    });
    try {
      final photo = await _cam!.takePicture();
      final bytes = await _svc.captureFaceBytes(photo);
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _state = _ScreenState.scanning;
          _status = 'Could not read frame';
        });
        return;
      }
      if (mounted) setState(() => _capturedBytes = bytes);
      if (_persons.isEmpty) {
        setState(() {
          _knownName = null;
          _showSaveUI = true;
          _state = _ScreenState.scanning;
          _status = 'No saved persons — tap Save to add someone';
        });
        _speakUnknown();
        return;
      }
      setState(() {
        _state = _ScreenState.identifying;
        _status = 'Identifying…';
      });
      final result = await _svc.identifyPerson(bytes);
      if (!mounted) return;
      if (result.error != null) {
        _handleGeminiError(result.error!);
        _setState(_ScreenState.scanning);
        return;
      }
      if (result.isKnown) {
        final name = result.matchedName!;
        setState(() {
          _knownName = name;
          _showSaveUI = false;
          _status = '✓ Identified: $name';
        });
        if (_lastKnownAnnounced != name) {
          _lastKnownAnnounced = name;
          setState(() => _isSpeaking = true);
          await _tts.speak('This is $name');
          if (mounted) setState(() => _isSpeaking = false);
        }
      } else {
        setState(() {
          _knownName = null;
          _showSaveUI = true;
          _status = 'Unknown person — tap Save This Person';
        });
        _speakUnknown();
      }
      setState(() => _state = _ScreenState.scanning);
    } catch (e, st) {
      print('❌ _scanOnce: $e\n$st');
      _setStatus('Error — retrying…');
      setState(() => _state = _ScreenState.scanning);
      await Future.delayed(const Duration(seconds: 3));
    }
  }

  void _speakUnknown() {
    final now = DateTime.now();
    if (_lastUnknownSpoken == null ||
        now.difference(_lastUnknownSpoken!) > _unknownCooldown) {
      _lastUnknownSpoken = now;
      _tts.speak('Unknown person detected. Tap save this person to add them.');
    }
  }

  void _handleGeminiError(String err) {
    final l = err.toLowerCase();
    if (l.contains('quota') || l.contains('429'))
      _setStatus('API quota reached — waiting…');
    else
      _setStatus('API error — retrying…');
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _setState(_ScreenState s) {
    if (mounted) setState(() => _state = s);
  }

  void _openSaveDialog() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('Not logged in — tap the person icon to login', isError: true);
      _tts.speak('Not logged in. Please login first.');
      return;
    }
    if (_capturedBytes == null || _capturedBytes!.isEmpty) {
      _showSnack(
        'No face captured yet. Point camera at person.',
        isError: true,
      );
      _tts.speak('No face captured. Point camera at the person.');
      return;
    }
    _name.clear();
    _looping = false;
    setState(() => _state = _ScreenState.saving);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _SaveSheet(
        nameCtrl: _name,
        faceBytes: _capturedBytes!,
        sttReady: _sttReady,
        speechToText: _stt,
        onSave: _doSave,
        onCancel: () {
          Navigator.pop(context);
          _startLoop();
        },
      ),
    );
  }

  Future<void> _doSave(String name, Uint8List bytes) async {
    if (Navigator.canPop(context)) Navigator.pop(context);
    _setState(_ScreenState.saving);
    _setStatus('Saving $name…');
    final result = await _svc.savePerson(name: name.trim(), faceBytes: bytes);
    if (!mounted) return;
    switch (result.status) {
      case SaveStatus.success:
        await _loadPersons();
        setState(() {
          _knownName = name.trim();
          _showSaveUI = false;
          _status = '✅ ${name.trim()} saved!';
        });
        _showSnack('${name.trim()} saved ✅', backgroundColor: Colors.green);
        await _tts.speak(
          '${name.trim()} saved. I will recognise them next time.',
        );
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) _startLoop();
        break;
      case SaveStatus.notLoggedIn:
        _showSnack(
          'Not logged in. Tap person icon (top-right) to login.',
          isError: true,
        );
        _tts.speak('Not logged in. Please login first.');
        _startLoop();
        break;
      case SaveStatus.permissionDenied:
        _showSnack(
          'Firestore permission denied. Check security rules.',
          isError: true,
        );
        _tts.speak('Permission denied.');
        _startLoop();
        break;
      default:
        _showSnack('Save failed: ${result.message}', isError: true);
        _tts.speak('Save failed.');
        _startLoop();
    }
    _setState(_ScreenState.scanning);
  }

  void _showSnack(
    String msg, {
    bool isError = false,
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            backgroundColor ?? (isError ? Colors.redAccent : Colors.grey[800]),
        duration: duration,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _looping = false;
            Navigator.pop(context);
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Person ID',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'Scan #$_scanNo  Saved: ${_persons.length}  ${isMixinListening ? "🎤" : ""}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.volume_up,
              color: _isSpeaking ? _accent : Colors.white,
            ),
            onPressed: () {
              if (_knownName != null)
                _tts.speak('This is $_knownName');
              else if (_showSaveUI)
                _tts.speak('Unknown person. Tap save.');
              else
                _tts.speak('No person detected.');
            },
          ),
          StreamBuilder<User?>(
            stream: FirebaseAuth.instance.authStateChanges(),
            builder: (_, snap) => IconButton(
              icon: Icon(
                snap.data != null ? Icons.account_circle : Icons.login,
                color: snap.data != null
                    ? Colors.greenAccent
                    : Colors.redAccent,
              ),
              tooltip: snap.data != null ? 'Profile' : 'Login',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => snap.data != null
                      ? const ProfileScreen()
                      : const RegistrationScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(flex: 4, child: _buildCamera()),
          _buildStatus(),
          _buildResultPanel(),
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
    Color borderColor = _accent;
    if (_state == _ScreenState.identifying) borderColor = Colors.yellowAccent;
    if (_knownName != null) borderColor = Colors.greenAccent;
    if (_showSaveUI && _knownName == null) borderColor = Colors.orange;
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_cam!),
        if (_state != _ScreenState.idle)
          Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: borderColor.withOpacity(0.6),
                width: 2.5,
              ),
            ),
          ),
        if (_state == _ScreenState.identifying)
          Container(
            color: Colors.black45,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.yellowAccent),
                  SizedBox(height: 12),
                  Text(
                    'Identifying…',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_knownName != null || _showSaveUI)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color:
                      (_knownName != null ? Colors.greenAccent : Colors.orange)
                          .withOpacity(0.8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _knownName != null
                        ? Icons.check_circle
                        : Icons.help_outline,
                    color: _knownName != null
                        ? Colors.greenAccent
                        : Colors.orange,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _knownName ?? 'Unknown',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (isMixinListening || _isSpeaking)
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isMixinListening ? Icons.mic : Icons.volume_up,
                    color: Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isMixinListening ? 'Listening…' : 'Speaking',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStatus() => Container(
    width: double.infinity,
    color: Colors.grey[900],
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
    child: Row(
      children: [
        if (_looping) _PulseDot(color: _accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _status,
            style: TextStyle(
              color: _looping ? _accent : Colors.white60,
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildResultPanel() {
    if (_knownName == null && !_showSaveUI) {
      return Container(
        height: 90,
        color: Colors.grey[850],
        child: const Center(
          child: Text(
            'Point camera at a person',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }
    if (_knownName != null) {
      return Container(
        color: Colors.grey[850],
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Colors.green,
              radius: 22,
              child: Icon(Icons.check, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'IDENTIFIED',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'This is $_knownName',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withOpacity(0.5)),
                ),
                child: const Text(
                  'UNKNOWN PERSON',
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const Spacer(),
              StreamBuilder<User?>(
                stream: FirebaseAuth.instance.authStateChanges(),
                builder: (_, s) => Text(
                  s.data != null ? '✅ Logged in' : '⚠️ Not logged in',
                  style: TextStyle(
                    fontSize: 11,
                    color: s.data != null
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Person not in your saved list.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _openSaveDialog,
              icon: const Icon(Icons.person_add_rounded, size: 24),
              label: const Text(
                'Save This Person',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() => Container(
    color: Colors.black,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _camReady ? (_looping ? _stopLoop : _startLoop) : null,
            icon: Icon(
              _looping ? Icons.pause_circle_outline : Icons.play_circle_outline,
              size: 26,
            ),
            label: Text(
              _looping ? 'Pause' : 'Resume',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _looping ? Colors.orange : _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () {
              if (_knownName != null)
                _tts.speak('This is $_knownName');
              else if (_showSaveUI)
                _tts.speak('Unknown person.');
              else
                _tts.speak('No person detected.');
            },
            icon: const Icon(Icons.replay, size: 22),
            label: const Text('Repeat', style: TextStyle(fontSize: 15)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[800],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Save Sheet ────────────────────────────────────────────────────────────────
class _SaveSheet extends StatefulWidget {
  final TextEditingController nameCtrl;
  final Uint8List faceBytes;
  final bool sttReady;
  final stt.SpeechToText speechToText;
  final Future<void> Function(String, Uint8List) onSave;
  final VoidCallback onCancel;
  const _SaveSheet({
    required this.nameCtrl,
    required this.faceBytes,
    required this.sttReady,
    required this.speechToText,
    required this.onSave,
    required this.onCancel,
  });
  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  static const _accent = Color(0xFFBB86FC);
  bool _listening = false, _saving = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                widget.faceBytes,
                width: 120,
                height: 120,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Who is this person?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Enter their name. Photo saved to Firebase.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: widget.nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: Colors.white, fontSize: 17),
              decoration: InputDecoration(
                hintText: 'e.g. Rahul Sharma',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.07),
                prefixIcon: const Icon(Icons.person, color: Colors.white38),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _accent, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                GestureDetector(
                  onTap: () async {
                    if (_listening) {
                      await widget.speechToText.stop();
                      setState(() => _listening = false);
                      return;
                    }
                    if (!widget.sttReady) return;
                    setState(() => _listening = true);
                    await widget.speechToText.listen(
                      onResult: (r) {
                        widget.nameCtrl.text = r.recognizedWords;
                        if (r.finalResult) setState(() => _listening = false);
                      },
                      listenFor: const Duration(seconds: 10),
                      localeId: 'en_IN',
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _listening
                          ? Colors.red.withOpacity(0.15)
                          : _accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _listening
                            ? Colors.red
                            : _accent.withOpacity(0.4),
                      ),
                    ),
                    child: Icon(
                      _listening ? Icons.mic_off : Icons.mic,
                      color: _listening ? Colors.red : _accent,
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _saving
                        ? null
                        : () async {
                            final name = widget.nameCtrl.text.trim();
                            if (name.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Enter a name')),
                              );
                              return;
                            }
                            setState(() => _saving = true);
                            await widget.onSave(name, widget.faceBytes);
                          },
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_rounded, size: 22),
                    label: Text(
                      _saving ? 'Saving…' : 'Save to Firebase',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: widget.onCancel,
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ),
            if (_listening)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '🎤 Listening…',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, __) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withOpacity(0.4 + 0.6 * _c.value),
      ),
    ),
  );
}
