import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

class SavedPerson {
  final String id;
  final String name;
  final String faceBase64; // compressed face crop stored in Firestore
  final String userId;

  SavedPerson({
    required this.id,
    required this.name,
    required this.faceBase64,
    required this.userId,
  });

  factory SavedPerson.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return SavedPerson(
      id: doc.id,
      name: (d['name'] as String? ?? '').trim(),
      faceBase64: d['faceBase64'] as String? ?? '',
      userId: d['userId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'faceBase64': faceBase64,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Result types
// ─────────────────────────────────────────────────────────────────────────────

class IdentifyResult {
  final String? matchedName; // null = unknown
  final bool hasFace;
  final String? error;

  const IdentifyResult({this.matchedName, required this.hasFace, this.error});

  bool get isKnown => matchedName != null;
}

enum SaveStatus { success, notLoggedIn, noFace, permissionDenied, error }

class SavePersonResult {
  final SaveStatus status;
  final String? message;
  const SavePersonResult(this.status, [this.message]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class PersonIdentificationService {
  static const String _collection = 'person_identification';
  static const String _geminiKey  = 'REDACTED_PRIVATE_API_KEY';
  static const String _geminiUrl  =
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-2.5-flash:generateContent?key=$_geminiKey';

  // In-memory cache so we don't reload Firestore on every scan
  List<SavedPerson> _cache = [];

  User? get _user => FirebaseAuth.instance.currentUser;
  CollectionReference get _col =>
      FirebaseFirestore.instance.collection(_collection);

  // ══════════════════════════════════════════════════════════════════════════
  // 1. CAPTURE — take picture and return compressed face JPEG bytes
  //    Returns null if no face-like region found
  // ══════════════════════════════════════════════════════════════════════════

  Future<Uint8List?> captureFaceBytes(XFile photo) async {
    try {
      final bytes = await photo.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      // Resize to max 300px wide to keep Firestore document small (<1 MB)
      final resized = decoded.width > 300
          ? img.copyResize(decoded, width: 300)
          : decoded;

      final jpeg = Uint8List.fromList(img.encodeJpg(resized, quality: 75));
      print('📸 Face bytes: ${jpeg.length} bytes');
      return jpeg;
    } catch (e) {
      print('captureFaceBytes: $e');
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 2. IDENTIFY — send current frame + all saved faces to Gemini
  //    Gemini Vision compares faces directly — no ML Kit vectors needed
  // ══════════════════════════════════════════════════════════════════════════

  Future<IdentifyResult> identifyPerson(Uint8List currentFrame) async {
    // No saved persons → unknown
    if (_cache.isEmpty) {
      return const IdentifyResult(hasFace: false);
    }

    try {
      // Build parts: current image first, then each saved person's image
      final parts = <Map<String, dynamic>>[];

      // Current camera frame
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(currentFrame),
        }
      });

      // Prompt
      final names = _cache.map((p) => '"${p.name}"').join(', ');
      parts.add({
        'text':
            'The first image is a camera frame. '
            'The following images are saved reference photos of known people: $names. '
            'Does the person in the first image match any of the reference photos? '
            'Look at face shape, eyes, nose, mouth, skin tone, and overall facial structure. '
            'Respond with ONLY one of these options:\n'
            '- The exact name if you find a confident match (e.g. "Rahul")\n'
            '- "UNKNOWN" if no match or no face in the frame\n'
            'Do NOT explain. Just the name or UNKNOWN.',
      });

      // Add each saved person's reference image
      for (final person in _cache) {
        if (person.faceBase64.isEmpty) continue;
        parts.add({
          'inline_data': {
            'mime_type': 'image/jpeg',
            'data': person.faceBase64,
          }
        });
      }

      final body = jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': 0.0,
          'maxOutputTokens': 20,
        },
      });

      print('📡 Gemini identify: ${_cache.length} reference(s)');
      final resp = await http
          .post(Uri.parse(_geminiUrl),
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 20));

      print('Gemini status: ${resp.statusCode}');

      if (resp.statusCode != 200) {
        final err = jsonDecode(resp.body);
        final msg = err['error']?['message'] ?? 'HTTP ${resp.statusCode}';
        print('Gemini error: $msg');
        return IdentifyResult(hasFace: false, error: msg);
      }

      final json    = jsonDecode(resp.body);
      final rawText = _extractText(json).trim();
      print('Gemini raw: "$rawText"');

      if (rawText.toUpperCase() == 'UNKNOWN' || rawText.isEmpty) {
        return const IdentifyResult(hasFace: true, matchedName: null);
      }

      // Check if the returned name matches any saved person (case-insensitive)
      final lower = rawText.toLowerCase();
      for (final p in _cache) {
        if (lower.contains(p.name.toLowerCase())) {
          print('Matched: "${p.name}"');
          return IdentifyResult(hasFace: true, matchedName: p.name);
        }
      }

      // Gemini returned something but it doesn't match saved names
      return const IdentifyResult(hasFace: true, matchedName: null);
    } catch (e, st) {
      print('identifyPerson: $e\n$st');
      return IdentifyResult(hasFace: false, error: e.toString());
    }
  }

  String _extractText(Map<String, dynamic> json) {
    try {
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return '';
      final parts = candidates[0]['content']['parts'] as List?;
      if (parts == null || parts.isEmpty) return '';
      return parts.map((p) => p['text'] ?? '').join(' ').trim();
    } catch (_) {
      return '';
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 3. SAVE — store name + face image in Firestore
  // ══════════════════════════════════════════════════════════════════════════

  Future<SavePersonResult> savePerson({
    required String name,
    required Uint8List faceBytes,
  }) async {
    final user = _user;

    print('savePerson called');
    print('   user  : ${user?.uid ?? "NULL — NOT LOGGED IN"}');
    print('   name  : "$name"');
    print('   bytes : ${faceBytes.length}');

    if (user == null) {
      return const SavePersonResult(SaveStatus.notLoggedIn,
          'You are not logged in. Please log in first.');
    }
    if (name.trim().isEmpty) {
      return const SavePersonResult(SaveStatus.error, 'Name cannot be empty');
    }
    if (faceBytes.isEmpty) {
      return const SavePersonResult(SaveStatus.noFace, 'No face image captured');
    }

    // Firestore documents have a 1 MB limit.
    // Our compressed JPEG is ~15–50 KB so it fits easily.
    final base64Face = base64Encode(faceBytes);

    try {
      print('Writing to Firestore collection "$_collection"...');
      final docRef = await _col.add({
        'name'       : name.trim(),
        'faceBase64' : base64Face,
        'userId'     : user.uid,
        'createdAt'  : FieldValue.serverTimestamp(),
      });
      print('Firestore write OK → ${docRef.id}');

      // Update cache immediately
      _cache.add(SavedPerson(
        id: docRef.id,
        name: name.trim(),
        faceBase64: base64Face,
        userId: user.uid,
      ));

      return const SavePersonResult(SaveStatus.success);
    } on FirebaseException catch (e) {
      print('FirebaseException: ${e.code} — ${e.message}');
      if (e.code == 'permission-denied') {
        return const SavePersonResult(SaveStatus.permissionDenied,
            'Firestore permission denied. Update security rules.');
      }
      return SavePersonResult(SaveStatus.error, e.message ?? e.code);
    } catch (e) {
      print('Unexpected: $e');
      return SavePersonResult(SaveStatus.error, e.toString());
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 4. LOAD — fetch all saved persons for current user
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<SavedPerson>> loadPersons() async {
    final user = _user;
    if (user == null) {
      print('loadPersons: not logged in');
      _cache = [];
      return [];
    }

    try {
      print('Loading persons for uid=${user.uid}');
      final snap = await _col
          .where('userId', isEqualTo: user.uid)
          .get();

      _cache = snap.docs
          .map((d) => SavedPerson.fromDoc(d))
          .where((p) => p.name.isNotEmpty && p.faceBase64.isNotEmpty)
          .toList();

      print('Loaded ${_cache.length} person(s)');
      for (final p in _cache) {
        print('   → "${p.name}" (${p.faceBase64.length} base64 chars)');
      }
      return _cache;
    } catch (e) {
      print('loadPersons: $e');
      _cache = [];
      return [];
    }
  }

  Future<void> deletePerson(String id) async {
    try {
      await _col.doc(id).delete();
      _cache.removeWhere((p) => p.id == id);
      print('Deleted $id');
    } catch (e) {
      print('deletePerson: $e');
    }
  }

  List<SavedPerson> get cachedPersons => List.unmodifiable(_cache);
}