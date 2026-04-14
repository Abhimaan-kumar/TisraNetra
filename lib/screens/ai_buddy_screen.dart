import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter/services.dart';
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
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _loading = false;
  bool _listening = false;
  bool _isSpeaking = false;
  String _recognizedText = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupVolumeListener();
    _initializeGemini();
    _initializeTTS();
    _initializeSpeechRecognition().then((_) {
      if (mounted) _startListening();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }


  void _initializeGemini() {
  const String apiKey = 'REDACTED_PRIVATE_API_KEY';

  const String systemPrompt = '''
You are a helpful personal buddy named Life Lens that will be used by blinds people.

Your personality:
- Friendly and concise
- no any text editing, no bold, no italic, no underline, no bullet points, no numbered list, no emojis, no special characters, no markdown formatting
- You speak in a warm but efficient tone
- You remember context within the conversation

Your capabilities:
- Answer questions clearly and accurately
- If you don't know something, say so honestly

Rules:
- Always respond in the same language the user writes in
- If user say in hindi, make sure you give response in hindi text
- If user asks for location, provide the location
- Keep responses concise unless the user asks for detail
- Never make up facts or hallucinate information
- 
''';

  _model = GenerativeModel(
    model: 'gemini-3-flash-preview',
    apiKey: apiKey,
    // ✅ System instruction for global persona/behavior
    systemInstruction: Content.system(systemPrompt),
    // ✅ Optional: tune generation behavior
    generationConfig: GenerationConfig(
      temperature: 0.7,       // 0.0 = deterministic, 1.0 = creative
      maxOutputTokens: 1024,
      topP: 0.9,
    ),
    // ✅ Optional: add safety settings
    safetySettings: [
      SafetySetting(HarmCategory.harassment, HarmBlockThreshold.medium),
      SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.medium),
    ],
  );

  // ✅ Optional: seed the chat with a pre-conversation for extra context
  _chatSession = _model.startChat(
    history: [
      Content.model([
        TextPart("Hello! I'm Life Lens, your personal assistant. How can I help you today?")
      ]),
    ],
  );
}

  void _initializeTTS() {
    _tts = FlutterTts();
    _tts.setLanguage("en-US");
    _tts.setSpeechRate(0.5);
    _tts.setCompletionHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = false);
        _startListening();
      }
    });
  }

  Future<void> _initializeSpeechRecognition() async {
    _speech = stt.SpeechToText();
    await _speech.initialize();
  }

  void _startListening() async {
    if (!_listening && mounted) {
      _recognizedText = '';
      if (await _speech.initialize()) {
        setState(() => _listening = true);
        _speech.listen(onResult: (result) {
          if (mounted) {
            setState(() {
              _recognizedText = result.recognizedWords;
            });
            if (result.finalResult) {
              _textController.text = result.recognizedWords;
              setState(() => _listening = false);
              if (_textController.text.trim().isNotEmpty) {
                _sendMessage();
              }
            }
          }
        });
      }
    } else if (mounted) {
      _speech.stop();
      setState(() => _listening = false);
    }
  }

  void _speak(String text) async {
    if (_listening) {
      _speech.stop();
      if (mounted) setState(() => _listening = false);
    }
    if (mounted) setState(() => _isSpeaking = true);
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

    if (mounted) {
      setState(() {
        _loading = true;
        _messages.add(Message(text: text, fromUser: true));
        _textController.clear();
        _recognizedText = '';
      });
      _scrollToBottom();
    }

    try {
      final response = await _chatSession.sendMessage(Content.text(text));
      final responseText = response.text ?? 'No response';
      if (mounted) {
        setState(() {
          _messages.add(Message(text: responseText, fromUser: false));
        });
        _scrollToBottom();
      }
      _speak(responseText);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _speech.stop();
    _tts.stop();
    _volumeService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (KeyEvent event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
            if (!_listening && !_loading) {
              _startListening();
            }
          } else if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
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
                    controller: _scrollController,
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
    )
    );
  }
}

class Message {
  final String text;
  final bool fromUser;

  Message({required this.text, required this.fromUser});
}
