import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/sms_message.dart';

class DbService {
  static final DbService _instance = DbService._internal();
  factory DbService() => _instance;
  DbService._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    // Initialize DB if first time
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'sms_messages.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            address TEXT,
            body TEXT,
            date INTEGER
          )
        ''');
      },
    );
  }

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

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}