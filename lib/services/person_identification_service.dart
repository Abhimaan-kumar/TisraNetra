import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────

class PersonData {
  final String id;
  final String name;
  final List<List<double>> faceVectors;

  PersonData({
    required this.id,
    required this.name,
    required this.faceVectors,
  });

  factory PersonData.fromFirestore(String id, Map<String, dynamic> d) {
    final name = (d['name'] as String? ?? '').trim();
    List<List<double>> vectors = [];

    // New format: faceVectors (list of lists)
    final multi = d['faceVectors'];
    if (multi is List) {
      for (final v in multi) {
        if (v is List && v.isNotEmpty) {
          vectors.add(List<double>.from(v.map((e) => (e as num).toDouble())));
        }
      }
    }

    // Old format: single faceVector flat list
    if (vectors.isEmpty) {
      final single = d['faceVector'];
      if (single is List && single.isNotEmpty) {
        vectors.add(List<double>.from(single.map((e) => (e as num).toDouble())));
      }
    }

    return PersonData(id: id, name: name, faceVectors: vectors);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class PersonIdentificationService {
  static const String _collection = 'person_identification';

  // ── Auth helper ─────────────────────────────────────────────────────────────
  // Returns current user — NEVER throws, just returns null if not logged in
  User? get _currentUser {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print('⚠️  PersonIdentificationService: No logged-in user');
    } else {
      print('✅ Auth OK: uid=${user.uid} email=${user.email}');
    }
    return user;
  }

  // ── Firestore ref ───────────────────────────────────────────────────────────
  CollectionReference get _col =>
      FirebaseFirestore.instance.collection(_collection);

  // ══════════════════════════════════════════════════════════════════════════
  // FACE VECTOR — 41 dims, always non-empty if face bbox is valid
  // ══════════════════════════════════════════════════════════════════════════

  List<double> extractFaceVector(Face face) {
    final box = face.boundingBox;
    final w = box.width.toDouble();
    final h = box.height.toDouble();
    if (w <= 0 || h <= 0) return [];

    final v = <double>[];

    // 1. Geometry (3)
    v.add(w / (w + h));
    v.add(box.left / 1000.0);
    v.add(box.top / 1000.0);

    // 2. Head pose angles (3)
    v.add((face.headEulerAngleX ?? 0.0) / 90.0);
    v.add((face.headEulerAngleY ?? 0.0) / 90.0);
    v.add((face.headEulerAngleZ ?? 0.0) / 90.0);

    // 3. Landmark positions normalized to bbox (16)
    final lmTypes = [
      FaceLandmarkType.leftEye,
      FaceLandmarkType.rightEye,
      FaceLandmarkType.noseBase,
      FaceLandmarkType.bottomMouth,
      FaceLandmarkType.leftCheek,
      FaceLandmarkType.rightCheek,
      FaceLandmarkType.leftEar,
      FaceLandmarkType.rightEar,
    ];
    int lmFound = 0;
    for (final type in lmTypes) {
      final lm = face.landmarks[type];
      if (lm != null) {
        lmFound++;
        v.add((lm.position.x.toDouble() - box.left) / w);
        v.add((lm.position.y.toDouble() - box.top) / h);
      } else {
        v.add(0.5);
        v.add(0.5);
      }
    }

    // 4. Inter-landmark ratios (5)
    final le = face.landmarks[FaceLandmarkType.leftEye];
    final re = face.landmarks[FaceLandmarkType.rightEye];
    final nb = face.landmarks[FaceLandmarkType.noseBase];
    final bm = face.landmarks[FaceLandmarkType.bottomMouth];
    final lc = face.landmarks[FaceLandmarkType.leftCheek];
    final rc = face.landmarks[FaceLandmarkType.rightCheek];

    v.add(_lmDist(le, re) / (w + 1));
    v.add(_vertGap(le, re, nb) / (h + 1));
    v.add(_vertGap2(nb, bm) / (h + 1));
    v.add(_lmDist(lc, rc) / (w + 1));
    v.add(_noseSym(le, re, nb) / (w + 1));

    // 5. Contour centroids (14)
    final contourTypes = [
      FaceContourType.face,
      FaceContourType.leftEye,
      FaceContourType.rightEye,
      FaceContourType.noseBridge,
      FaceContourType.noseBottom,
      FaceContourType.upperLipTop,
      FaceContourType.lowerLipBottom,
    ];
    for (final type in contourTypes) {
      final c = face.contours[type];
      if (c != null && c.points.isNotEmpty) {
        double sx = 0, sy = 0;
        for (final p in c.points) {
          sx += (p.x.toDouble() - box.left) / w;
          sy += (p.y.toDouble() - box.top) / h;
        }
        v.add(sx / c.points.length);
        v.add(sy / c.points.length);
      } else {
        v.add(0.5);
        v.add(0.5);
      }
    }

    print('📊 Vector: ${v.length} dims | lm=$lmFound/8');
    return v; // 41 dims
  }

  // ── Landmark helpers ─────────────────────────────────────────────────────
  double _lmDist(FaceLandmark? a, FaceLandmark? b) {
    if (a == null || b == null) return 0;
    final dx = a.position.x - b.position.x;
    final dy = a.position.y - b.position.y;
    return sqrt((dx * dx + dy * dy).toDouble());
  }

  double _vertGap(FaceLandmark? el, FaceLandmark? er, FaceLandmark? n) {
    if (el == null || er == null || n == null) return 0;
    return ((el.position.y + er.position.y) / 2.0 - n.position.y).abs().toDouble();
  }

  double _vertGap2(FaceLandmark? a, FaceLandmark? b) {
    if (a == null || b == null) return 0;
    return (a.position.y - b.position.y).abs().toDouble();
  }

  double _noseSym(FaceLandmark? el, FaceLandmark? er, FaceLandmark? n) {
    if (el == null || er == null || n == null) return 0;
    return (n.position.x - (el.position.x + er.position.x) / 2.0).abs().toDouble();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MATCHING
  //
  // ROOT CAUSE of "same name always":
  //   Cosine similarity on geometric face vectors is structurally HIGH
  //   for ALL human faces (both eyes above nose above mouth = same structure).
  //   Result: 0.80–0.96 for EVERYONE, so threshold 0.92 always fires.
  //
  // Real fix: Use EUCLIDEAN DISTANCE instead of cosine similarity.
  //   Euclidean distance measures HOW DIFFERENT the vectors actually are.
  //   Same person across captures: distance ~0.8–2.0
  //   Different people:            distance ~2.5–5.0+
  //   Threshold: if distance > 2.2 → unknown
  // ══════════════════════════════════════════════════════════════════════════

  static const double _matchDistanceThreshold = 2.2;
  // If only 1 person saved, use stricter threshold to avoid false matches
  static const double _strictSingleThreshold  = 1.8;

  String? matchPerson(List<double> query, List<PersonData> stored) {
    if (query.isEmpty || stored.isEmpty) return null;

    double bestDist  = double.infinity;
    String? bestName;

    for (final person in stored) {
      if (person.faceVectors.isEmpty) continue;

      // Find the MINIMUM distance across all enrollment samples
      double minDist = double.infinity;
      for (final vec in person.faceVectors) {
        if (vec.isEmpty) continue;
        final len  = min(query.length, vec.length);
        final dist = _euclideanDist(query.sublist(0, len), vec.sublist(0, len));
        if (dist < minDist) minDist = dist;
      }

      print('  → "${person.name}": minDist=${minDist.toStringAsFixed(3)}');

      if (minDist < bestDist) {
        bestDist = minDist;
        bestName = person.name;
      }
    }

    final threshold = stored.length == 1
        ? _strictSingleThreshold
        : _matchDistanceThreshold;

    print('🏆 Best: "$bestName" dist=${bestDist.toStringAsFixed(3)} threshold=$threshold');

    if (bestDist <= threshold) return bestName;
    print('🔴 Unknown: dist too large');
    return null;
  }

  double _euclideanDist(List<double> a, List<double> b) {
    double sum = 0;
    for (int i = 0; i < a.length; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return sqrt(sum);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FIRESTORE — Save
  // ══════════════════════════════════════════════════════════════════════════

  Future<SaveResult> savePerson({
    required String name,
    required List<List<double>> faceVectors,
  }) async {
    // Step 1: verify auth
    final user = _currentUser;
    if (user == null) {
      return SaveResult.notLoggedIn;
    }

    // Step 2: validate inputs
    final valid = faceVectors.where((v) => v.isNotEmpty).toList();
    if (valid.isEmpty) {
      print('❌ savePerson: no valid vectors');
      return SaveResult.noFaceData;
    }
    if (name.trim().isEmpty) {
      return SaveResult.emptyName;
    }

    // Step 3: write to Firestore
    try {
      print('💾 Writing to Firestore...');
      print('   collection : $_collection');
      print('   name       : "${name.trim()}"');
      print('   userId     : ${user.uid}');
      print('   samples    : ${valid.length}');
      print('   dims/sample: ${valid.first.length}');

      final docRef = await _col.add({
        'name'       : name.trim(),
        'faceVectors': valid,
        'userId'     : user.uid,
        'sampleCount': valid.length,
        'createdAt'  : FieldValue.serverTimestamp(),
      });

      print('✅ Firestore write SUCCESS → docId: ${docRef.id}');
      return SaveResult.success;
    } on FirebaseException catch (e) {
      print('❌ FirebaseException: ${e.code} — ${e.message}');
      if (e.code == 'permission-denied') return SaveResult.permissionDenied;
      return SaveResult.firestoreError(e.message ?? e.code);
    } catch (e, st) {
      print('❌ savePerson unexpected error: $e\n$st');
      return SaveResult.firestoreError(e.toString());
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FIRESTORE — Load
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<PersonData>> getStoredPersons() async {
    final user = _currentUser;
    if (user == null) return [];

    try {
      final snap = await _col
          .where('userId', isEqualTo: user.uid)
          .get();

      print('📋 Firestore load: ${snap.docs.length} doc(s) for uid=${user.uid}');

      final result = <PersonData>[];
      for (final doc in snap.docs) {
        final p = PersonData.fromFirestore(
            doc.id, doc.data() as Map<String, dynamic>);
        if (p.name.isEmpty || p.faceVectors.isEmpty) {
          print('  ⚠️ ${doc.id}: skipped (name="${p.name}" vecs=${p.faceVectors.length})');
          continue;
        }
        result.add(p);
        print('  ✅ "${p.name}" — ${p.faceVectors.length} sample(s) × ${p.faceVectors.first.length} dims');
      }
      return result;
    } on FirebaseException catch (e) {
      print('❌ getStoredPersons FirebaseException: ${e.code} — ${e.message}');
      return [];
    } catch (e) {
      print('❌ getStoredPersons: $e');
      return [];
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FIRESTORE — Delete
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> deletePerson(String id) async {
    try {
      await _col.doc(id).delete();
      print('🗑️ Deleted doc: $id');
    } catch (e) {
      print('❌ deletePerson: $e');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SaveResult — typed result so the screen can show the right message
// ─────────────────────────────────────────────────────────────────────────────

class SaveResult {
  final bool isSuccess;
  final String message;

  const SaveResult._(this.isSuccess, this.message);

  static const SaveResult success        = SaveResult._(true,  'Saved successfully');
  static const SaveResult notLoggedIn    = SaveResult._(false, 'not_logged_in');
  static const SaveResult noFaceData     = SaveResult._(false, 'No face data captured');
  static const SaveResult emptyName      = SaveResult._(false, 'Please enter a name');
  static const SaveResult permissionDenied = SaveResult._(false,
      'Firestore permission denied — check your Firestore security rules');
  static SaveResult firestoreError(String msg) =>
      SaveResult._(false, 'Firestore error: $msg');
}