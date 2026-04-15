import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:google_fonts/google_fonts.dart';
import '../services/tts_service.dart';
import '../services/volume_button_service.dart';
import '../theme/app_theme.dart';
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
        _speech.listen(
          onResult: (result) {
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
          },
        );
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
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
        body: Container(
          decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
          child: SafeArea(
            child: Column(
              children: [
                // ── Premium Header ─────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: AppTheme.cardBorder),
                          ),
                          child: const Icon(Icons.arrow_back_ios_new,
                              color: AppTheme.textSecondary, size: 18),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF7D8C2E),
                              Color(0xFF566420),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.chat_outlined,
                            color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Time pass with AI buddy',
                                style: GoogleFonts.inter(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                )),
                            Text(
                              _listening ? '🎤 Listening…' : 'Voice-enabled chat',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          final user =
                              FirebaseAuth.instance.currentUser;
                          if (user == null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const RegistrationScreen(),
                              ),
                            );
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const ProfileScreen()),
                          );
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: AppTheme.cardBorder),
                          ),
                          child: const Icon(
                              Icons.person_outline_rounded,
                              color: AppTheme.textSecondary,
                              size: 22),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Chat Messages ─────────────────────────────────
                Expanded(
                  child: _messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  color: AppTheme.accent
                                      .withOpacity(0.1),
                                  borderRadius:
                                      BorderRadius.circular(24),
                                  border: Border.all(
                                    color: AppTheme.accent
                                        .withOpacity(0.2),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.chat_outlined,
                                  size: 40,
                                  color: AppTheme.accent,
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Start a conversation',
                                style: GoogleFonts.inter(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Speak or type your message',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final msg = _messages[index];
                            return Align(
                              alignment: msg.fromUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(
                                        vertical: 4),
                                padding:
                                    const EdgeInsets.all(14),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context)
                                              .size
                                              .width *
                                          0.78,
                                ),
                                decoration: BoxDecoration(
                                  gradient: msg.fromUser
                                      ? AppTheme.accentGradient
                                      : null,
                                  color: msg.fromUser
                                      ? null
                                      : AppTheme.card,
                                  borderRadius:
                                      BorderRadius.only(
                                    topLeft:
                                        const Radius.circular(
                                            18),
                                    topRight:
                                        const Radius.circular(
                                            18),
                                    bottomLeft: Radius.circular(
                                        msg.fromUser
                                            ? 18
                                            : 4),
                                    bottomRight:
                                        Radius.circular(
                                            msg.fromUser
                                                ? 4
                                                : 18),
                                  ),
                                  border: msg.fromUser
                                      ? null
                                      : Border.all(
                                          color: AppTheme
                                              .cardBorder
                                              .withOpacity(
                                                  0.5)),
                                ),
                                child: Text(
                                  msg.text,
                                  style: GoogleFonts.inter(
                                    color: msg.fromUser
                                        ? Colors.white
                                        : AppTheme
                                            .textPrimary,
                                    fontSize: 14,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),

                // ── Input Area ─────────────────────────────────────
                Container(
                  padding: const EdgeInsets.fromLTRB(
                      16, 10, 16, 16),
                  decoration: BoxDecoration(
                    color: AppTheme.surface.withOpacity(0.8),
                    border: Border(
                      top: BorderSide(
                        color: AppTheme.divider,
                        width: 1,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      if (_recognizedText.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          margin:
                              const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.accent
                                .withOpacity(0.1),
                            borderRadius:
                                BorderRadius.circular(12),
                            border: Border.all(
                              color: AppTheme.accent
                                  .withOpacity(0.3),
                            ),
                          ),
                          child: Text(
                            'Heard: $_recognizedText',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: AppTheme.accentLight,
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppTheme.card,
                                borderRadius:
                                    BorderRadius.circular(24),
                                border: Border.all(
                                    color: AppTheme.cardBorder),
                              ),
                              child: TextField(
                                controller: _textController,
                                style: GoogleFonts.inter(
                                    color:
                                        AppTheme.textPrimary),
                                decoration: InputDecoration(
                                  hintText:
                                      'Type or speak...',
                                  hintStyle: GoogleFonts.inter(
                                      color: AppTheme
                                          .textSecondary),
                                  border: InputBorder.none,
                                  enabledBorder:
                                      InputBorder.none,
                                  focusedBorder:
                                      InputBorder.none,
                                  contentPadding:
                                      const EdgeInsets
                                          .symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Mic button
                          GestureDetector(
                            onTap: _loading
                                ? null
                                : _startListening,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: _listening
                                    ? AppTheme.red
                                        .withOpacity(0.15)
                                    : AppTheme.surface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _listening
                                      ? AppTheme.red
                                      : AppTheme.cardBorder,
                                ),
                              ),
                              child: Icon(
                                _listening
                                    ? Icons.mic
                                    : Icons.mic_none,
                                color: _listening
                                    ? AppTheme.red
                                    : AppTheme.textSecondary,
                                size: 22,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Send button
                          GestureDetector(
                            onTap: _loading
                                ? null
                                : _sendMessage,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                gradient:
                                    AppTheme.accentGradient,
                                shape: BoxShape.circle,
                                boxShadow:
                                    AppTheme.glowShadow(
                                  AppTheme.accent,
                                  blur: 10,
                                ),
                              ),
                              child: _loading
                                  ? const Padding(
                                      padding:
                                          EdgeInsets.all(12),
                                      child:
                                          CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.send,
                                      color: Colors.white,
                                      size: 20),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Message {
  final String text;
  final bool fromUser;

  Message({required this.text, required this.fromUser});
}
