import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'dart:io';
import 'registration.dart';
import 'profile_screen.dart';

class AIBuddyScreen extends StatefulWidget {
  const AIBuddyScreen({super.key});

  @override
  State<AIBuddyScreen> createState() => _AIBuddyScreenState();
}

class _AIBuddyScreenState extends State<AIBuddyScreen> {
  final FlutterTts _tts = FlutterTts();
  final _audioRecorder = AudioRecorder();
  
  bool _isRecording = false;
  bool _isProcessing = false;
  String _transcript = '';
  String _response = '';
  List<Map<String, String>> _chatHistory = [];
  String? _recordingPath;

  // Replace with your Gemini API key from https://ai.google.dev/
  static const String _geminiApiKey = 'YOUR_GEMINI_API_KEY_HERE';

  @override
  void dispose() {
    _audioRecorder.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getTemporaryDirectory();
        _recordingPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        
        await _audioRecorder.start(
          RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000),
          path: _recordingPath!,
        );
        setState(() => _isRecording = true);
      }
    } catch (e) {
      _showSnackBar('Recording failed: $e');
    }
  }

  Future<void> _stopRecordingAndProcess() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      
      if (path != null) {
        setState(() => _isProcessing = true);
        _showSnackBar('Processing audio...');
        
        // Prepare audio file and send to Gemini
        final audioFile = File(path);
        final audioBytes = await audioFile.readAsBytes();
        
        // Send to Gemini with audio
        final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: _geminiApiKey);
        final content = [
          Content.multi([
            TextPart('Listen to this audio and respond conversationally. Be friendly and helpful.'),
            DataPart('audio/m4a', audioBytes),
          ])
        ];
        
        final response = await model.generateContent(content);
        final text = response.text ?? 'No response';
        
        setState(() {
          _response = text;
          _chatHistory.add({'user': 'voice', 'ai': text});
        });
        
        // Speak response
        await _tts.speak(text);
        _showSnackBar('Response ready');
      }
    } catch (e) {
      _showSnackBar('Error: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Buddy Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const RegistrationScreen()));
                return;
              }
              Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_response.isNotEmpty)
                  Card(
                    color: Colors.blue.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('AI Response:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                          const SizedBox(height: 8),
                          Text(_response),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                if (_chatHistory.isEmpty)
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_outlined, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text('Press the mic to start chatting with AI Buddy!', textAlign: TextAlign.center),
                      ],
                    ),
                  )
                else
                  ..._chatHistory.map((msg) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Align(
                          alignment: msg['user'] == 'voice' ? Alignment.centerRight : Alignment.centerLeft,
                          child: Card(
                            color: msg['user'] == 'voice' ? Colors.green.shade100 : Colors.grey.shade200,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(msg['ai'] ?? ''),
                            ),
                          ),
                        ),
                      )),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (_isProcessing)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: CircularProgressIndicator(),
                  ),
                FloatingActionButton.extended(
                  onPressed: _isRecording ? _stopRecordingAndProcess : (_isProcessing ? null : _startRecording),
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  label: Text(_isRecording ? 'Stop' : _isProcessing ? 'Processing...' : 'Tap to talk'),
                  backgroundColor: _isRecording ? Colors.red : Colors.green,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}

