import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/tts_service.dart';
import '../services/volume_button_service.dart';
import 'registration.dart';
import 'profile_screen.dart';

class AIBuddyScreen extends StatefulWidget {
  const AIBuddyScreen({super.key});

  @override
  State<AIBuddyScreen> createState() => _AIBuddyScreenState();
}

class _AIBuddyScreenState extends State<AIBuddyScreen>
    with WidgetsBindingObserver {
  late GenerativeModel _model;
  late ChatSession _chatSession;
  late FlutterTts _tts;
  late stt.SpeechToText _speech;
  final VolumeButtonService _volumeService = VolumeButtonService();
  final TtsService _ttsService = TtsService();

  final List<Message> _messages = [];
  final _textController = TextEditingController();
  bool _loading = false;
  bool _listening = false;
  String _recognizedText = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupVolumeListener();
    _initializeGemini();
    _initializeTTS();
    _initializeSpeechRecognition();
  }

  void _initializeGemini() {
    const String apiKey = 'REDACTED_PRIVATE_API_KEY';
    _model = GenerativeModel(model: 'gemini-pro', apiKey: apiKey);
    _chatSession = _model.startChat();
  }

  void _initializeTTS() {
    _tts = FlutterTts();
    _tts.setLanguage("en-US");
    _tts.setSpeechRate(1.0);
  }

  void _initializeSpeechRecognition() async {
    _speech = stt.SpeechToText();
    await _speech.initialize();
  }

  void _startListening() async {
    if (!_listening) {
      _recognizedText = '';
      if (await _speech.initialize()) {
        setState(() => _listening = true);
        _speech.listen(
          onResult: (result) {
            setState(() {
              _recognizedText = result.recognizedWords;
            });
            if (result.finalResult) {
              _textController.text = result.recognizedWords;
              setState(() => _listening = false);
            }
          },
        );
      }
    } else {
      _speech.stop();
      setState(() => _listening = false);
    }
  }

  void _speak(String text) async {
    await _tts.speak(text);
  }

  // ── Volume button listener ──────────────────────────────────────────────

  void _setupVolumeListener() {
    _volumeService.initialize(
      onVolumeUp: _handleVolumeUp,
      onVolumeDown: () async {
        await _ttsService.speak('Going back to home');
        if (mounted) Navigator.pop(context);
      },
    );
  }

  Future<void> _handleVolumeUp() async {
    // Start listening for voice input
    if (!_listening) {
      await _startVoiceInput();
    }
  }

  Future<void> _startVoiceInput() async {
    if (_listening) return;

    setState(() {
      _listening = true;
      _recognizedText = '';
    });
    await _ttsService.speak('Listening...');

    await _speech.listen(
      onResult: (result) {
        setState(() => _recognizedText = result.recognizedWords);
        if (result.finalResult) {
          setState(() => _listening = false);
          if (_recognizedText.isNotEmpty) {
            _textController.text = _recognizedText;
            _sendMessage();
          }
        }
      },
      listenFor: const Duration(seconds: 5),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _speech.stop();
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _loading = true;
      _messages.add(Message(text: text, fromUser: true));
      _textController.clear();
      _recognizedText = '';
    });

    try {
      final response = await _chatSession.sendMessage(Content.text(text));
      final responseText = response.text ?? 'No response';
      setState(() {
        _messages.add(Message(text: responseText, fromUser: false));
      });
      _speak(responseText);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _speech.stop();
    _tts.stop();
    _volumeService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Time pass with AI buddy'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_outlined,
                          size: 64,
                          color: const Color.fromARGB(255, 105, 118, 30),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Start a conversation',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      return Align(
                        alignment: msg.fromUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                          ),
                          decoration: BoxDecoration(
                            color: msg.fromUser
                                ? const Color.fromARGB(255, 3, 251, 40)
                                : Colors.grey[300],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            msg.text,
                            style: TextStyle(
                              color: msg.fromUser ? Colors.black : Colors.black,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (_recognizedText.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Heard: $_recognizedText',
                      style: const TextStyle(fontSize: 14, color: Colors.blue),
                    ),
                  ),
                if (_recognizedText.isNotEmpty) const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: InputDecoration(
                          hintText: 'Type or speak...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton(
                      mini: true,
                      onPressed: _loading ? null : _startListening,
                      backgroundColor: _listening ? Colors.red : Colors.blue,
                      child: Icon(_listening ? Icons.mic : Icons.mic_none),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton(
                      mini: true,
                      onPressed: _loading ? null : _sendMessage,
                      backgroundColor: const Color.fromARGB(255, 3, 251, 40),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(
                                  Colors.black,
                                ),
                              ),
                            )
                          : const Icon(Icons.send, color: Colors.black),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class Message {
  final String text;
  final bool fromUser;

  Message({required this.text, required this.fromUser});
}
