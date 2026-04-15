// lib/services/face_db_service.dart
//
// Sqflite database for storing person face embeddings.
// Table `persons`:  id (PK), name (TEXT), embeddings (TEXT — JSON list of 192-d vectors)

import 'dart:convert';
import 'package:sqflite/sqflite.dart';

// ── Data class ────────────────────────────────────────────────────────────────

class PersonRecord {
  final int id;
  final String name;
  final List<List<double>> embeddings; // multiple 192-d vectors

  const PersonRecord({
    required this.id,
    required this.name,
    required this.embeddings,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class FaceDBService {
  static FaceDBService? _instance;
  static Database? _db;

  FaceDBService._();

  factory FaceDBService() {
    _instance ??= FaceDBService._();
    return _instance!;
  }

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/faces.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE persons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            embeddings TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  /// Retrieve all saved persons with their embeddings.
  Future<List<PersonRecord>> getAllPersons() async {
    final db = await database;
    final rows = await db.query('persons');
    return rows.map((row) {
      final raw = jsonDecode(row['embeddings'] as String) as List;
      final embs = raw
          .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
          .toList();
      return PersonRecord(
        id: row['id'] as int,
        name: row['name'] as String,
        embeddings: embs,
      );
    }).toList();
  }

  /// Add a new person with their multi-angle embeddings.
  Future<int> addPerson(String name, List<List<double>> embeddings) async {
    final db = await database;
    return db.insert('persons', {
      'name': name,
      'embeddings': jsonEncode(embeddings),
    });
  }

  /// Update embeddings for an existing person.
  Future<void> updatePersonEmbeddings(
      int id, List<List<double>> embeddings) async {
    final db = await database;
    await db.update(
      'persons',
      {'embeddings': jsonEncode(embeddings)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete a person by id.
  Future<void> deletePerson(int id) async {
    final db = await database;
    await db.delete('persons', where: 'id = ?', whereArgs: [id]);
  }
}
