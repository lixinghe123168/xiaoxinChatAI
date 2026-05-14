import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class MemoryEntry {
  final int? id;
  final String content;
  final String source;
  final double score;
  final DateTime createdAt;
  final DateTime? expireAt;
  final String contentHash;

  const MemoryEntry({
    this.id,
    required this.content,
    required this.source,
    required this.score,
    required this.createdAt,
    this.expireAt,
    required this.contentHash,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'content': content,
        'source': source,
        'score': score,
        'created_at': createdAt.toIso8601String(),
        'expire_at': expireAt?.toIso8601String(),
        'content_hash': contentHash,
      };

  factory MemoryEntry.fromMap(Map<String, dynamic> map) {
    return MemoryEntry(
      id: map['id'],
      content: map['content'],
      source: map['source'] ?? '',
      score: (map['score'] ?? 0).toDouble(),
      createdAt: DateTime.parse(map['created_at']),
      expireAt: map['expire_at'] != null
          ? DateTime.parse(map['expire_at'])
          : null,
      contentHash: map['content_hash'] ?? '',
    );
  }
}

class MemoryService {
  static Database? _database;
  static const String _tableName = 'long_term_memory';
  static bool _fts5Available = false;

  static List<MemoryEntry>? _memoryCache;
  static DateTime? _cacheTimestamp;
  static const Duration _cacheExpiry = Duration(minutes: 5);

  static const int _defaultMaxMemories = 2000;
  static const int _defaultExpireDays = 90;
  static const double _defaultMinScore = 0.2;

  Future<Database> get database async {
    if (_database != null) return _database!;

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'xiaoxinchat_memory.db');

    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            source TEXT DEFAULT '',
            score REAL DEFAULT 0.0,
            created_at TEXT NOT NULL,
            expire_at TEXT,
            content_hash TEXT NOT NULL UNIQUE
          )
        ''');

        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_${_tableName}_score ON $_tableName(score DESC)
        ''');

        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_${_tableName}_created ON $_tableName(created_at DESC)
        ''');

        _fts5Available = await _checkFts5Available(db);

        if (_fts5Available) {
          try {
            await db.execute('''
              CREATE VIRTUAL TABLE IF NOT EXISTS ${_tableName}_fts USING fts5(
                content,
                content=$_tableName,
                content_rowid=id
              )
            ''');

            await db.execute('''
              CREATE TRIGGER IF NOT EXISTS ${_tableName}_ai AFTER INSERT ON $_tableName BEGIN
                INSERT INTO ${_tableName}_fts(rowid, content) VALUES (new.id, new.content);
              END
            ''');

            await db.execute('''
              CREATE TRIGGER IF NOT EXISTS ${_tableName}_ad AFTER DELETE ON $_tableName BEGIN
                INSERT INTO ${_tableName}_fts(${_tableName}_fts, rowid, content) VALUES('delete', old.id, old.content);
              END
            ''');

            await db.execute('''
              CREATE TRIGGER IF NOT EXISTS ${_tableName}_au AFTER UPDATE ON $_tableName BEGIN
                INSERT INTO ${_tableName}_fts(${_tableName}_fts, rowid, content) VALUES('delete', old.id, old.content);
                INSERT INTO ${_tableName}_fts(rowid, content) VALUES (new.id, new.content);
              END
            ''');
          } catch (e) {
            _fts5Available = false;
          }
        }
      },
    );

    return _database!;
  }

  static Future<bool> _checkFts5Available(Database db) async {
    try {
      await db.rawQuery('SELECT fts5(*)');
      return true;
    } catch (e) {
      return false;
    }
  }

  void _invalidateCache() {
    _memoryCache = null;
    _cacheTimestamp = null;
  }

  Future<List<MemoryEntry>> _getCachedMemories() async {
    final now = DateTime.now();

    if (_memoryCache != null &&
        _cacheTimestamp != null &&
        now.difference(_cacheTimestamp!) < _cacheExpiry) {
      return _memoryCache!;
    }

    final db = await database;
    final results = await db.query(
      _tableName,
      where: 'expire_at IS NULL OR expire_at > ?',
      whereArgs: [now.toIso8601String()],
      orderBy: 'score DESC, created_at DESC',
    );

    _memoryCache = results.map((m) => MemoryEntry.fromMap(m)).toList();
    _cacheTimestamp = now;

    return _memoryCache!;
  }

  String _generateHash(String content) {
    var hash = 0;
    for (var i = 0; i < content.length; i++) {
      hash = ((hash << 5) - hash + content.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<int> addMemory({
    required String content,
    String source = 'conversation',
    double score = 1.0,
    int expireDays = _defaultExpireDays,
  }) async {
    final db = await database;
    final now = DateTime.now();
    final hash = _generateHash(content);

    final existing = await db.query(
      _tableName,
      where: 'content_hash = ?',
      whereArgs: [hash],
    );

    if (existing.isNotEmpty) {
      final result = await db.update(
        _tableName,
        {
          'score': score,
          'created_at': now.toIso8601String(),
          'expire_at': now.add(Duration(days: expireDays)).toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      _invalidateCache();
      return result;
    }

    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $_tableName'),
    ) ?? 0;

    if (count >= _defaultMaxMemories) {
      await db.rawDelete(
        'DELETE FROM $_tableName WHERE id IN (SELECT id FROM $_tableName ORDER BY score ASC, created_at ASC LIMIT 10)',
      );
    }

    final result = await db.insert(_tableName, MemoryEntry(
      content: content,
      source: source,
      score: score,
      createdAt: now,
      expireAt: now.add(Duration(days: expireDays)),
      contentHash: hash,
    ).toMap());
    _invalidateCache();
    return result;
  }

  static double _freshnessMultiplier(DateTime createdAt) {
    final days = DateTime.now().difference(createdAt).inDays;
    if (days < 7) return 1.0;
    if (days < 30) return 0.8;
    return 0.6;
  }

  Future<List<MemoryEntry>> searchMemories({
    required String query,
    int topK = 5,
    double minScore = _defaultMinScore,
  }) async {
    final words = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return [];

    if (_fts5Available) {
      final matchExpr = words.map((w) => '$w*').join(' OR ');

      try {
        final db = await database;
        final results = await db.rawQuery('''
          SELECT m.*, rank
          FROM ${_tableName} m
          JOIN ${_tableName}_fts f ON m.id = f.rowid
          WHERE ${_tableName}_fts MATCH ?
          ORDER BY rank ASC, m.score DESC, m.created_at DESC
          LIMIT ?
        ''', [matchExpr, topK * 3]);

        final scored = results.map((m) => MemoryEntry.fromMap(m)).where((m) => m.score >= minScore).map((m) {
          final freshness = _freshnessMultiplier(m.createdAt);
          return _ScoredMemory(m, m.score * freshness);
        }).toList();
        scored.sort((a, b) => b.score.compareTo(a.score));
        return scored.take(topK).map((sm) => sm.memory).toList();
      } catch (e) {
        _fts5Available = false;
      }
    }

    final allMemories = await _getCachedMemories();

    final scoredResults = <_ScoredMemory>[];

    for (final memory in allMemories) {
      if (memory.score < minScore) continue;

      final freshness = _freshnessMultiplier(memory.createdAt);
      final contentLower = memory.content.toLowerCase();
      double relevanceScore = 0.0;

      for (final word in words) {
        final wordLower = word.toLowerCase();

        if (contentLower.contains(wordLower)) {
          int count = 0;
          int pos = 0;
          while ((pos = contentLower.indexOf(wordLower, pos)) != -1) {
            count++;
            pos += wordLower.length;
          }

          double wordWeight = 1.0;
          if (contentLower.startsWith(wordLower)) {
            wordWeight = 2.0;
          } else if (contentLower.contains(' $wordLower ') ||
                     contentLower.contains(' $wordLower，') ||
                     contentLower.contains(' $wordLower。')) {
            wordWeight = 1.5;
          }

          final exactMatchBonus = word.length > 2 ? count * 0.2 : 0;
          relevanceScore += (count * wordWeight) + exactMatchBonus;
        }
      }

      if (relevanceScore > 0) {
        final combinedScore = ((relevanceScore * 0.6) + (memory.score * 0.4)) * freshness;
        scoredResults.add(_ScoredMemory(memory, combinedScore));
      }
    }

    scoredResults.sort((a, b) => b.score.compareTo(a.score));

    return scoredResults
        .take(topK)
        .map((sm) => sm.memory)
        .toList();
  }

  Future<List<MemoryEntry>> getAllMemories({int limit = 50}) async {
    final db = await database;
    final results = await db.query(
      _tableName,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return results.map((m) => MemoryEntry.fromMap(m)).toList();
  }

  Future<int> getMemoryCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $_tableName'),
    ) ?? 0;
  }

  Future<void> deleteMemory(int id) async {
    final db = await database;
    await db.delete(_tableName, where: 'id = ?', whereArgs: [id]);
    _invalidateCache();
  }

  Future<void> clearExpiredMemories() async {
    final db = await database;
    await db.delete(
      _tableName,
      where: 'expire_at IS NOT NULL AND expire_at < ?',
      whereArgs: [DateTime.now().toIso8601String()],
    );
    _invalidateCache();
  }

  Future<void> clearAllMemories() async {
    final db = await database;
    await db.delete(_tableName);
    _invalidateCache();
  }

  Future<Map<String, dynamic>> getStats() async {
    final db = await database;
    final count = await getMemoryCount();

    final todayResult = await db.rawQuery(
      "SELECT COUNT(*) as count FROM $_tableName WHERE created_at > ?",
      [DateTime.now().subtract(const Duration(days: 1)).toIso8601String()],
    );

    final weekResult = await db.rawQuery(
      "SELECT COUNT(*) as count FROM $_tableName WHERE created_at > ?",
      [DateTime.now().subtract(const Duration(days: 7)).toIso8601String()],
    );

    return {
      'total_count': count,
      'today_count': todayResult.first['count'] ?? 0,
      'week_count': weekResult.first['count'] ?? 0,
      'max_capacity': _defaultMaxMemories,
    };
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
    _memoryCache = null;
    _cacheTimestamp = null;
  }
}

class _ScoredMemory {
  final MemoryEntry memory;
  final double score;

  const _ScoredMemory(this.memory, this.score);
}
