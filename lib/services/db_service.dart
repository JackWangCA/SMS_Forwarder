import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/sms_message.dart';

/// Lightweight DTO for queued emails.
/// You can move this to your models/ directory if you prefer.
class QueuedEmail {
  final int id;
  final String address;
  final String body;
  final DateTime date;

  QueuedEmail({
    required this.id,
    required this.address,
    required this.body,
    required this.date,
  });

  static QueuedEmail fromMap(Map<String, dynamic> m) => QueuedEmail(
        id: m['id'] as int,
        address: m['address'] as String,
        body: m['body'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(m['date'] as int),
      );
}

class DbService {
  static final DbService _instance = DbService._internal();
  factory DbService() => _instance;
  DbService._internal();

  static Database? _database;

  // === Public singleton access (UI/main isolate) ============================
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _openOrCreateDb(singleInstance: true);
    return _database!;
  }

  // === Background isolate helpers ==========================================
  // Use these from headless callbacks (e.g., Telephony onBackgroundSms).
  // They open/close their own connection with singleInstance: false.

  static Future<void> enqueueFromBackground({
    required String address,
    required String body,
    required DateTime date,
  }) async {
    final db = await _openOrCreateDb(singleInstance: false);
    try {
      await db.insert('email_queue', {
        'address': address,
        'body': body,
        'date': date.millisecondsSinceEpoch,
      });
    } finally {
      await db.close();
    }
  }

  static Future<void> bgInsertMessage(SmsMessageModel message) async {
    final db = await _openOrCreateDb(singleInstance: false);
    try {
      await db.insert('messages', message.toMap());
    } finally {
      await db.close();
    }
  }

  // === Schema / open helpers ===============================================

  static const int _dbVersion = 2; // bump from 1 -> 2 to add email_queue

  static Future<String> _dbFilePath() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, 'sms_messages.db');
  }

  static Future<Database> _openOrCreateDb({required bool singleInstance}) async {
    final path = await _dbFilePath();
    return openDatabase(
      path,
      version: _dbVersion,
      singleInstance: singleInstance,
      onCreate: (db, version) async {
        // v1 schema
        await db.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            address TEXT,
            body TEXT,
            date INTEGER
          )
        ''');

        // v2 additions
        await _createEmailQueue(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createEmailQueue(db);
        }
      },
    );
  }

  static Future<void> _createEmailQueue(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS email_queue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT NOT NULL,
        body TEXT NOT NULL,
        date INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_email_queue_date ON email_queue(date)');
  }

  // === Messages API (unchanged) ============================================

  Future<int> insertMessage(SmsMessageModel message) async {
    final db = await database;
    return db.insert('messages', message.toMap());
  }

  Future<List<SmsMessageModel>> getMessages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      orderBy: 'date DESC',
    );
    return List.generate(maps.length, (i) => SmsMessageModel.fromMap(maps[i]));
  }

  // === Email queue API (new) ===============================================

  /// Enqueue an outgoing email (called from main isolate on new SMS or simulation).
  Future<int> enqueueEmail({
    required String address,
    required String body,
    required DateTime date,
  }) async {
    final db = await database;
    return db.insert('email_queue', {
      'address': address,
      'body': body,
      'date': date.millisecondsSinceEpoch,
    });
  }

  /// Fetch a batch of queued emails (oldest first).
  Future<List<QueuedEmail>> fetchEmailQueue({int limit = 20}) async {
    final db = await database;
    final maps = await db.query(
      'email_queue',
      orderBy: 'date ASC, id ASC',
      limit: limit,
    );
    return maps.map(QueuedEmail.fromMap).toList();
  }

  /// Mark a queued email as sent (removes it from the outbox).
  Future<int> markQueuedAsSent(int id) async {
    final db = await database;
    return db.delete('email_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}