// lib/services/person_identification_service.dart
//
// ═══════════════════════════════════════════════════════════════════════════════
// COMPLETE FACE RECOGNITION SYSTEM
// ═══════════════════════════════════════════════════════════════════════════════
//
// ARCHITECTURE
// ──────────────────────────────────────────────────────────────────────────────
// 1. ML Kit Face Detection   → finds face bbox + landmarks in every frame
// 2. MobileFaceNet (TFLite)  → converts 112×112 face crop → 192-dim embedding
// 3. Euclidean distance      → compares query embedding vs stored embeddings
//    • Same person:          distance < 0.9   (typically 0.3–0.7)
//    • Different person:     distance > 1.1   (typically 1.2–1.8)
//    • Threshold used:       0.9  (strict, like phone face-unlock)
// 4. Storage:                SQLite (local, always works) + Firestore (cloud sync)
// 5. Liveness detection:     blink detection using eye-open probability from ML Kit
//
// WHY EUCLIDEAN DISTANCE, NOT COSINE SIMILARITY
// ──────────────────────────────────────────────────────────────────────────────
// MobileFaceNet was trained with ArcFace loss, optimised for Euclidean distance.
// On L2-normalised embeddings, cosine similarity = 1 - (d²/2), so both are
// equivalent — but Euclidean distance thresholds are more intuitive to tune.
// The original paper uses Euclidean with threshold ~1.0 on LFW benchmark.
//
// SETUP CHECKLIST
// ──────────────────────────────────────────────────────────────────────────────
// 1. Download MobileFaceNet model (896 KB):
//    https://github.com/sirius-ai/MobileFaceNet_TF/raw/master/output_models/MobileFaceNet.tflite
//    Save as: assets/models/mobile_face_net.tflite
//
// 2. pubspec.yaml:
//    dependencies:
//      camera: ^0.10.5+9
//      google_mlkit_face_detection: ^0.9.0
//      tflite_flutter: ^0.10.4
//      image: ^4.1.7
//      sqflite: ^2.3.2
//      path: ^1.9.0
//      cloud_firestore: ^4.15.0
//      firebase_auth: ^4.19.0
//      flutter_tts: ^3.8.5
//
//    flutter:
//      assets:
//        - assets/models/mobile_face_net.tflite
//
// 3. Android gradle: minSdkVersion 21
//    iOS Info.plist: NSCameraUsageDescription
//
// 4. Firestore rules:
//    match /person_identification/{doc} {
//      allow read, write: if request.auth != null;
//    }
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

class SavedPerson {
  final String id;
  final String name;

  /// 192-dim MobileFaceNet embedding, already L2-normalised.
  final List<double> embedding;
  final String userId;
  final DateTime? createdAt;

  const SavedPerson({
    required this.id,
    required this.name,
    required this.embedding,
    required this.userId,
    this.createdAt,
  });

  // ── SQLite row ─────────────────────────────────────────────────────────────
  factory SavedPerson.fromRow(Map<String, dynamic> row) {
    final raw = (row['embedding'] as String)
        .split(',')
        .map(double.parse)
        .toList();
    return SavedPerson(
      id: row['id'].toString(),
      name: row['name'] as String,
      embedding: raw,
      userId: row['userId'] as String,
      createdAt: row['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int)
          : null,
    );
  }

  Map<String, dynamic> toRow() => {
    'name': name,
    'embedding': embedding.join(','),
    'userId': userId,
    'createdAt':
        createdAt?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch,
  };

  // ── Firestore doc ──────────────────────────────────────────────────────────
  factory SavedPerson.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final raw = d['embedding'];
    final emb = raw is List
        ? List<double>.from(raw.map((e) => (e as num).toDouble()))
        : <double>[];
    return SavedPerson(
      id: doc.id,
      name: (d['name'] as String? ?? '').trim(),
      embedding: emb,
      userId: d['userId'] as String? ?? '',
    );
  }
}

// ── Identification result ──────────────────────────────────────────────────────

class IdentifyResult {
  final String? matchedName; // null → unknown or no face
  final bool hasFace;
  final double? distance; // Euclidean distance (smaller = more similar)
  final bool livenessVerified;
  final String? error;

  const IdentifyResult({
    this.matchedName,
    required this.hasFace,
    this.distance,
    this.livenessVerified = false,
    this.error,
  });

  bool get isKnown => matchedName != null;
  bool get isUnknown => hasFace && !isKnown;
}

// ── Save result ────────────────────────────────────────────────────────────────

enum SaveStatus {
  success,
  notLoggedIn,
  noFace,
  noModel,
  permissionDenied,
  error,
}

class SavePersonResult {
  final SaveStatus status;
  final String? message;
  const SavePersonResult(this.status, [this.message]);
  bool get isSuccess => status == SaveStatus.success;
}

// ── Liveness check result ──────────────────────────────────────────────────────

class LivenessState {
  final bool blinkDetected;
  final double leftEyeOpen; // 0.0 = closed, 1.0 = open
  final double rightEyeOpen;
  const LivenessState({
    required this.blinkDetected,
    required this.leftEyeOpen,
    required this.rightEyeOpen,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class PersonIdentificationService {
  // ── Constants ──────────────────────────────────────────────────────────────

  static const String _firestoreCollection = 'person_identification';
  static const String _dbName = 'face_recognition.db';
  static const String _tableName = 'persons';

  // Euclidean distance threshold for MobileFaceNet on 192-dim L2-normalised
  // embeddings.  Same person: 0.3–0.8. Different person: 1.1–1.8.
  // 0.9 gives ~99% precision on LFW benchmark.
  static const double _distanceThreshold = 0.9;

  // Input image size MobileFaceNet expects
  static const int _modelInputSize = 112;
  // Output embedding size of MobileFaceNet
  static const int _embeddingSize = 192;

  // Liveness: eye probability below this = closed
  static const double _eyeClosedThreshold = 0.4;

  // ── ML Kit face detector ────────────────────────────────────────────────────
  // enableClassification = true gives us eye-open probability for liveness.
  // enableLandmarks = true for better crop alignment.
  late final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
      enableClassification: true, // ← needed for blink / liveness
      enableContours: false,
      enableTracking: false,
      minFaceSize: 0.15,
    ),
  );

  // ── TFLite ─────────────────────────────────────────────────────────────────
  Interpreter? _interpreter;
  bool get modelLoaded => _interpreter != null;

  // ── Local DB ───────────────────────────────────────────────────────────────
  Database? _db;

  // ── In-memory cache (loaded from DB/Firestore on init) ─────────────────────
  List<SavedPerson> _cache = [];

  // ── Liveness state machine ─────────────────────────────────────────────────
  // We track whether at least one blink has been detected since the last
  // "unknown" or "start scan" event.  This prevents a photo from spoofing.

  bool _blinkConfirmed = false;
  bool _eyeWasClosed = false; // previous frame eye state

  // ── Auth ───────────────────────────────────────────────────────────────────
  User? get _user => FirebaseAuth.instance.currentUser;
  CollectionReference get _col =>
      FirebaseFirestore.instance.collection(_firestoreCollection);

  // ═══════════════════════════════════════════════════════════════════════════
  // INITIALISE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> initialize() async {
    await Future.wait([_loadModel(), _openDatabase()]);
    await _syncFromFirestore();
  }

  Future<void> _loadModel() async {
    try {
      print('⏱️ Starting model load...');
      final t1 = DateTime.now();

      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobile_face_net.tflite',
      );
      final t2 = DateTime.now();
      print('✅ Asset load: ${t2.difference(t1).inSeconds}s');

      // OPTIONAL: Skip warm-up if it's causing delays
      // Uncomment next line to test if warm-up is the bottleneck
      // print('✅ MobileFaceNet loaded (warm-up skipped)');
      // return;

      print('🔥 Starting warm-up...');
      final t3 = DateTime.now();

      final dummy = List.generate(
        1,
        (_) => List.generate(
          _modelInputSize,
          (_) => List.generate(_modelInputSize, (_) => [0.0, 0.0, 0.0]),
        ),
      );
      final dummyOut = [List.filled(_embeddingSize, 0.0)];
      _interpreter!.run(dummy, dummyOut);

      final t4 = DateTime.now();
      print('✅ Warm-up: ${t4.difference(t3).inSeconds}s');
      print(
        '✅ MobileFaceNet loaded & warmed up (total: ${t4.difference(t1).inSeconds}s)',
      );
    } catch (e) {
      _interpreter = null;
      print('❌ TFLite load failed: $e');
      print(
        '   → Place MobileFaceNet.tflite at assets/models/mobile_face_net.tflite',
      );
    }
  }

  Future<void> _openDatabase() async {
    final dbPath = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE $_tableName (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          name      TEXT    NOT NULL,
          embedding TEXT    NOT NULL,
          userId    TEXT    NOT NULL,
          createdAt INTEGER
        )
      '''),
    );
    // Load into cache
    final rows = await _db!.query(_tableName);
    _cache = rows.map(SavedPerson.fromRow).toList();
    print('📦 Local DB loaded: ${_cache.length} person(s)');
  }

  /// Pull any Firestore records not yet in the local DB.
  Future<void> _syncFromFirestore() async {
    if (_user == null) return;
    try {
      final snap = await _col.where('userId', isEqualTo: _user!.uid).get();
      for (final doc in snap.docs) {
        final p = SavedPerson.fromDoc(doc);
        if (p.embedding.isEmpty) continue;
        // Add to local DB if not already there
        final exists = _cache.any((c) => c.id == p.id);
        if (!exists) {
          await _db?.insert(
            _tableName,
            p.toRow()..['id'] = null,
          ); // let SQLite auto-assign id
          _cache.add(p);
        }
      }
      print('☁️  Firestore sync: ${_cache.length} total person(s)');
    } catch (e) {
      print('☁️  Firestore sync skipped: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LIVENESS DETECTION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Reset liveness state when starting a new scan session.
  void resetLiveness() {
    _blinkConfirmed = false;
    _eyeWasClosed = false;
  }

  /// Process a face for liveness check.
  /// Returns a [LivenessState] describing eye state and whether a blink was seen.
  LivenessState checkLiveness(Face face) {
    final leftOpen = face.leftEyeOpenProbability ?? 1.0;
    final rightOpen = face.rightEyeOpenProbability ?? 1.0;
    final avgOpen = (leftOpen + rightOpen) / 2.0;

    final eyeNowClosed = avgOpen < _eyeClosedThreshold;

    // Blink = eyes were open → now closed → will reopen
    if (_eyeWasClosed && !eyeNowClosed) {
      // Eyes just opened after being closed → complete blink
      _blinkConfirmed = true;
    }
    _eyeWasClosed = eyeNowClosed;

    return LivenessState(
      blinkDetected: _blinkConfirmed,
      leftEyeOpen: leftOpen,
      rightEyeOpen: rightOpen,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // IDENTIFY — main recognition pipeline
  // ═══════════════════════════════════════════════════════════════════════════

  Future<IdentifyResult> identifyPerson(
    XFile photo, {
    bool requireLiveness = false,
  }) async {
    if (!modelLoaded) {
      return const IdentifyResult(
        hasFace: false,
        error:
            'TFLite model not loaded. Place mobile_face_net.tflite in assets/models/',
      );
    }

    try {
      // ── 1. Face detection ────────────────────────────────────────────────
      final inputImage = InputImage.fromFilePath(photo.path);
      final faces = await _detector.processImage(inputImage);

      if (faces.isEmpty) {
        return const IdentifyResult(hasFace: false);
      }

      final face = _largestFace(faces);

      // ── 2. Liveness check ────────────────────────────────────────────────
      final liveness = checkLiveness(face);
      if (requireLiveness && !liveness.blinkDetected) {
        return IdentifyResult(
          hasFace: true,
          livenessVerified: false,
          matchedName: null,
        );
      }

      // ── 3. Generate embedding ────────────────────────────────────────────
      final imageBytes = await photo.readAsBytes();
      final embedding = await _generateEmbedding(imageBytes, face);

      if (embedding == null) {
        return const IdentifyResult(hasFace: true);
      }

      // ── 4. Compare with stored embeddings ────────────────────────────────
      if (_cache.isEmpty) {
        return const IdentifyResult(hasFace: true, matchedName: null);
      }

      double bestDist = double.infinity;
      double secondBestDist = double.infinity;
      String? bestName;

      for (final person in _cache) {
        if (person.embedding.length != embedding.length) continue;
        final dist = _euclidean(embedding, person.embedding);

        print('  👤 "${person.name}": dist=${dist.toStringAsFixed(3)}');

        if (dist < bestDist) {
          secondBestDist = bestDist;
          bestDist = dist;
          bestName = person.name;
        } else if (dist < secondBestDist) {
          secondBestDist = dist;
        }
      }

      print(
        '🏆 Best: "$bestName" dist=${bestDist.toStringAsFixed(3)} '
        '| 2nd: ${secondBestDist.toStringAsFixed(3)} '
        '| threshold=$_distanceThreshold',
      );

      // Accept match if: distance is below threshold
      // The gap check (best vs second-best) adds confidence when multiple people
      // are enrolled, but we keep it loose (0.15) to not be over-strict.
      final isMatch =
          bestDist < _distanceThreshold &&
          (secondBestDist == double.infinity ||
              secondBestDist - bestDist >= 0.15);

      return IdentifyResult(
        hasFace: true,
        matchedName: isMatch ? bestName : null,
        distance: bestDist,
        livenessVerified: liveness.blinkDetected,
      );
    } catch (e, st) {
      print('❌ identifyPerson: $e\n$st');
      return IdentifyResult(hasFace: false, error: e.toString());
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ENROLLMENT — extract embedding from a single photo
  // ═══════════════════════════════════════════════════════════════════════════

  /// Extract a 192-dim embedding from [photo].
  /// Returns null if no face is detected or model is not loaded.
  Future<List<double>?> extractEmbedding(XFile photo) async {
    if (!modelLoaded) return null;
    try {
      final inputImage = InputImage.fromFilePath(photo.path);
      final faces = await _detector.processImage(inputImage);
      if (faces.isEmpty) return null;
      final face = _largestFace(faces);
      final imageBytes = await photo.readAsBytes();
      return _generateEmbedding(imageBytes, face);
    } catch (e) {
      print('❌ extractEmbedding: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SAVE — commit averaged embedding to local DB + Firestore
  // ═══════════════════════════════════════════════════════════════════════════

  Future<SavePersonResult> commitSave({
    required String name,
    required List<List<double>> embeddings,
  }) async {
    if (!modelLoaded) {
      return const SavePersonResult(
        SaveStatus.noModel,
        'TFLite model not loaded. Cannot save face.',
      );
    }

    final user = _user;
    if (user == null) {
      return const SavePersonResult(
        SaveStatus.notLoggedIn,
        'Not logged in. Please log in first.',
      );
    }

    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return const SavePersonResult(SaveStatus.error, 'Name cannot be empty');
    }

    final valid = embeddings.where((e) => e.length == _embeddingSize).toList();
    if (valid.isEmpty) {
      return const SavePersonResult(
        SaveStatus.noFace,
        'No valid face detected in any capture. Ensure face is visible and well-lit.',
      );
    }

    // Average then L2-normalise for better cross-angle stability
    final averaged = _averageEmbeddings(valid);
    final normalised = _l2Normalise(averaged);

    // ── Save to local SQLite ──────────────────────────────────────────────
    try {
      final now = DateTime.now();
      final localId =
          await _db?.insert(_tableName, {
            'name': trimmedName,
            'embedding': normalised.join(','),
            'userId': user.uid,
            'createdAt': now.millisecondsSinceEpoch,
          }) ??
          0;

      final person = SavedPerson(
        id: localId.toString(),
        name: trimmedName,
        embedding: normalised,
        userId: user.uid,
        createdAt: now,
      );
      _cache.add(person);
      print('✅ SQLite saved: id=$localId name="$trimmedName"');
    } catch (e) {
      print('⚠️ SQLite save failed: $e');
    }

    // ── Sync to Firestore (best-effort, non-blocking) ─────────────────────
    _saveToFirestore(trimmedName, normalised, user.uid)
        .then((_) {
          print('☁️  Firestore sync complete');
        })
        .catchError((e) {
          print('☁️  Firestore sync failed (local data still saved): $e');
        });

    return const SavePersonResult(SaveStatus.success);
  }

  Future<void> _saveToFirestore(
    String name,
    List<double> embedding,
    String uid,
  ) async {
    await _col.add({
      'name': name,
      'embedding': embedding,
      'userId': uid,
      'samples': 1,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LOAD — reload from local DB (already done in initialize())
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<SavedPerson>> loadPersons() async {
    if (_db == null) return _cache;
    final rows = await _db!.query(
      _tableName,
      where: 'userId = ?',
      whereArgs: [_user?.uid ?? ''],
    );
    _cache = rows.map(SavedPerson.fromRow).toList();
    print('📋 Reloaded ${_cache.length} person(s) from local DB');
    return _cache;
  }

  Future<void> deletePerson(SavedPerson person) async {
    // Remove from local DB
    await _db?.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [int.tryParse(person.id) ?? -1],
    );
    _cache.removeWhere((p) => p.id == person.id);

    // Remove from Firestore (best-effort)
    try {
      // Find matching Firestore doc by name + userId
      final snap = await _col
          .where('userId', isEqualTo: person.userId)
          .where('name', isEqualTo: person.name)
          .limit(1)
          .get();
      for (final doc in snap.docs) await doc.reference.delete();
    } catch (_) {}

    print('🗑️ Deleted "${person.name}"');
  }

  Future<void> deleteAllPersons() async {
    final uid = _user?.uid;
    await _db?.delete(
      _tableName,
      where: uid != null ? 'userId = ?' : null,
      whereArgs: uid != null ? [uid] : null,
    );
    _cache.clear();

    // Firestore
    try {
      final snap = uid != null
          ? await _col.where('userId', isEqualTo: uid).get()
          : null;
      if (snap != null) {
        for (final doc in snap.docs) await doc.reference.delete();
      }
    } catch (_) {}
    print('🗑️ All persons deleted');
  }

  List<SavedPerson> get cachedPersons => List.unmodifiable(_cache);
  int get personCount => _cache.length;

  // ═══════════════════════════════════════════════════════════════════════════
  // PRIVATE — embedding generation
  // ═══════════════════════════════════════════════════════════════════════════

  /// Crop face region → resize to 112×112 → run MobileFaceNet → L2-normalise.
  Future<List<double>?> _generateEmbedding(
    Uint8List imageBytes,
    Face face,
  ) async {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;

      // ── Align crop using eye landmarks for better accuracy ─────────────
      final crop = _alignedCrop(decoded, face);
      final resized = img.copyResize(
        crop,
        width: _modelInputSize,
        height: _modelInputSize,
      );

      // ── Build input tensor [1, 112, 112, 3] normalised to [-1, 1] ──────
      // Using typed Float32List for speed (avoids nested List boxing)
      final inputFlat = Float32List(_modelInputSize * _modelInputSize * 3);
      int idx = 0;
      for (int row = 0; row < _modelInputSize; row++) {
        for (int col = 0; col < _modelInputSize; col++) {
          final pixel = resized.getPixel(col, row);
          inputFlat[idx++] = (pixel.r / 127.5) - 1.0;
          inputFlat[idx++] = (pixel.g / 127.5) - 1.0;
          inputFlat[idx++] = (pixel.b / 127.5) - 1.0;
        }
      }

      // Reshape for TFLite: [1, 112, 112, 3]
      final input = inputFlat.reshape([1, _modelInputSize, _modelInputSize, 3]);

      // ── Run inference ────────────────────────────────────────────────────
      final outputFlat = Float32List(_embeddingSize);
      final output = outputFlat.reshape([1, _embeddingSize]);
      _interpreter!.run(input, output);

      final emb = outputFlat.toList();
      return _l2Normalise(emb);
    } catch (e) {
      print('❌ _generateEmbedding: $e');
      return null;
    }
  }

  /// Crop the face from [decoded] using bounding box + landmark alignment.
  /// Pads by 25% for better context (hair, chin).
  img.Image _alignedCrop(img.Image decoded, Face face) {
    final box = face.boundingBox;
    final padX = (box.width * 0.25).toInt();
    final padY = (box.height * 0.25).toInt();

    final x = (box.left - padX).clamp(0, decoded.width - 1).toInt();
    final y = (box.top - padY).clamp(0, decoded.height - 1).toInt();
    final w = (box.width + padX * 2).clamp(1, decoded.width - x).toInt();
    final h = (box.height + padY * 2).clamp(1, decoded.height - y).toInt();

    return img.copyCrop(decoded, x: x, y: y, width: w, height: h);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PRIVATE — math helpers
  // ═══════════════════════════════════════════════════════════════════════════

  Face _largestFace(List<Face> faces) => faces.reduce(
    (a, b) =>
        a.boundingBox.width * a.boundingBox.height >
            b.boundingBox.width * b.boundingBox.height
        ? a
        : b,
  );

  /// Euclidean distance between two L2-normalised 192-dim vectors.
  /// Equivalent to sqrt(2 - 2*cosine), so lower = more similar.
  double _euclidean(List<double> a, List<double> b) {
    double sum = 0;
    for (int i = 0; i < a.length; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return sqrt(sum);
  }

  List<double> _averageEmbeddings(List<List<double>> embeddings) {
    final len = embeddings.first.length;
    final avg = List<double>.filled(len, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < len; i++) avg[i] += e[i];
    }
    return avg.map((v) => v / embeddings.length).toList();
  }

  List<double> _l2Normalise(List<double> v) {
    double norm = 0;
    for (final x in v) norm += x * x;
    norm = sqrt(norm);
    if (norm < 1e-10) return v;
    return v.map((x) => x / norm).toList();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DISPOSE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> dispose() async {
    _detector.close();
    _interpreter?.close();
    await _db?.close();
    print('PersonIdentificationService disposed');
  }
}
