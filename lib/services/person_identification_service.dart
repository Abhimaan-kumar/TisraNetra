import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

// ── Data Model ─────────────────────────────────────────────────

class PersonData {
  final String id;
  final String name;
  final String faceImageBase64;
  final String description;
  final DateTime createdAt;

  PersonData({
    required this.id,
    required this.name,
    required this.faceImageBase64,
    required this.description,
    required this.createdAt,
  });

  factory PersonData.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return PersonData(
      id: doc.id,
      name: data['name'] ?? '',
      faceImageBase64: data['faceImageBase64'] ?? '',
      description: data['description'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

// ── Service ────────────────────────────────────────────────────

class PersonIdentificationService {
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY';

  static const List<String> _models = [
    'gemini-2.5-flash-lite',
    'gemini-2.5-flash',
  ];

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  String? _workingModel;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ── Firestore helpers ──────────────────────────────────────

  CollectionReference? _getCollection() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return _firestore
        .collection('users')
        .doc(user.uid)
        .collection('known_persons');
  }

  /// Fetch all stored known persons (max 15 most recent)
  Future<List<PersonData>> getStoredPersons() async {
    final col = _getCollection();
    if (col == null) return [];

    final snap =
        await col.orderBy('createdAt', descending: true).limit(15).get();
    return snap.docs.map((d) => PersonData.fromFirestore(d)).toList();
  }

  /// Save a new person with a compressed face image
  Future<void> savePerson({
    required String name,
    required Uint8List imageBytes,
    required String description,
  }) async {
    final col = _getCollection();
    if (col == null) throw Exception('Not logged in');

    // Compress for Firestore storage (< 1 MB doc limit)
    final compressed = _compressImage(imageBytes);
    final base64Image = base64Encode(compressed);

    await col.add({
      'name': name,
      'faceImageBase64': base64Image,
      'description': description,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Delete a stored person
  Future<void> deletePerson(String personId) async {
    final col = _getCollection();
    if (col == null) return;
    await col.doc(personId).delete();
  }

  // ── Image compression ──────────────────────────────────────

  Uint8List _compressImage(Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return imageBytes;

      // Resize to max 300 px on the longest side
      final resized = img.copyResize(
        decoded,
        width: decoded.width > decoded.height ? 300 : null,
        height: decoded.height >= decoded.width ? 300 : null,
      );

      return Uint8List.fromList(img.encodeJpg(resized, quality: 65));
    } catch (e) {
      print('Compression failed, using original: $e');
      return imageBytes;
    }
  }

  // ── Gemini: describe a face ────────────────────────────────

  /// Returns a short text description of the person's face, or null.
  Future<String?> describeFace(Uint8List imageBytes) async {
    const prompt =
        'Describe this person\'s appearance briefly: '
        'hair color/style, glasses or not, facial hair, approximate age range, '
        'gender, ethnicity if obvious, any notable features. '
        'Keep it under 25 words. Start directly with the description.';

    return await _callGeminiSingle(imageBytes, prompt);
  }

  // ── Gemini: identify against stored persons ────────────────

  /// Compare a new face image against stored persons.
  /// Returns the matched person's name, or null if no match.
  Future<String?> identifyPerson({
    required Uint8List newFaceBytes,
    required List<PersonData> storedPersons,
  }) async {
    if (storedPersons.isEmpty) return null;

    // Build multi-part request: [instruction, stored1, name1, stored2, name2, …, target]
    final parts = <Map<String, dynamic>>[];

    parts.add({
      'text':
          'You are a face recognition assistant helping a visually impaired person. '
          'I will show you images of known people, then a target image. '
          'Determine if the target person matches any known person.\n\n'
          'Known people:',
    });

    for (int i = 0; i < storedPersons.length; i++) {
      final p = storedPersons[i];
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': p.faceImageBase64,
        },
      });
      parts.add({
        'text': 'Person ${i + 1}: "${p.name}" — ${p.description}',
      });
    }

    // Add the new target image
    parts.add({'text': '\nTarget person to identify:'});
    parts.add({
      'inline_data': {
        'mime_type': 'image/jpeg',
        'data': base64Encode(newFaceBytes),
      },
    });
    parts.add({
      'text':
          '\nCompare the target person with all known people above. '
          'If the target clearly matches a known person, respond with ONLY: '
          'MATCH:<exact name>\n'
          'If no match or uncertain, respond with ONLY: UNKNOWN\n'
          'Be confident before matching.',
    });

    final response = await _callGeminiMultiPart(parts);
    if (response == null) return null;

    final trimmed = response.trim();
    if (trimmed.toUpperCase().startsWith('MATCH:')) {
      return trimmed.substring(6).trim();
    }
    return null;
  }

  // ── Gemini API plumbing ────────────────────────────────────

  Future<String?> _callGeminiSingle(
      Uint8List imageBytes, String prompt) async {
    final parts = <Map<String, dynamic>>[
      {
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(imageBytes),
        },
      },
      {'text': prompt},
    ];
    return await _callGeminiMultiPart(parts);
  }

  Future<String?> _callGeminiMultiPart(
      List<Map<String, dynamic>> parts) async {
    // Try cached working model first
    if (_workingModel != null) {
      try {
        return await _postToModel(_workingModel!, parts);
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('quota') ||
            msg.contains('429') ||
            msg.contains('rate')) {
          _workingModel = null;
        } else {
          rethrow;
        }
      }
    }

    // Fallback: try each model
    for (final model in _models) {
      try {
        print('Trying model: $model');
        final result = await _postToModel(model, parts);
        if (result != null) {
          _workingModel = model;
          print('Using model: $model');
          return result;
        }
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('quota') ||
            msg.contains('429') ||
            msg.contains('rate')) {
          continue;
        }
        rethrow;
      }
    }

    throw Exception('All models failed or quota exceeded');
  }

  Future<String?> _postToModel(
      String model, List<Map<String, dynamic>> parts) async {
    final body = jsonEncode({
      'contents': [
        {'parts': parts}
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 100,
      },
    });

    final url = Uri.parse('$_baseUrl/$model:generateContent?key=$_apiKey');

    final response = await http
        .post(url,
            headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 429 ||
        (response.statusCode != 200 &&
            response.body.toLowerCase().contains('quota'))) {
      throw Exception('Quota exceeded for $model');
    }

    if (response.statusCode == 404 || response.statusCode == 403) {
      throw Exception('Model not available: $model');
    }

    if (response.statusCode != 200) {
      final err = jsonDecode(response.body);
      throw Exception(
          err['error']?['message'] ?? 'HTTP ${response.statusCode}');
    }

    final json = jsonDecode(response.body);
    final candidates = json['candidates'];
    if (candidates == null || candidates is! List || candidates.isEmpty) {
      return null;
    }

    final respParts = candidates[0]?['content']?['parts'];
    if (respParts == null || respParts is! List || respParts.isEmpty) {
      return null;
    }

    return respParts
        .where((p) => p != null && p['text'] != null)
        .map((p) => p['text'].toString())
        .join(' ')
        .trim();
  }
}
