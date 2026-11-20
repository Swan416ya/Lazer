import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

enum CacheBucket { audio, artwork, data }

/// Disposable, bounded files. Failed/partial writes are never cache hits.
class DiskCache {
  DiskCache({
    Future<Directory> Function()? directory,
    this.limits = const {
      CacheBucket.audio: 1024 * 1024 * 1024,
      CacheBucket.artwork: 256 * 1024 * 1024,
      CacheBucket.data: 64 * 1024 * 1024,
    },
  }) : _directory = directory ?? _defaultDirectory;

  static final shared = DiskCache();
  final Future<Directory> Function() _directory;
  final Map<CacheBucket, int> limits;
  Future<Directory?>? _root;
  final _writes = <String, Future<File?>>{};
  // What is on disk, per bucket: size plus the LRU stamp. Pruning walks these
  // records instead of the directory, so evicting one file costs one unlink
  // rather than one `stat` for every file in the bucket. That is what keeps a
  // write proportional to the entries it drops, not to the cache size.
  final _entries = <CacheBucket, Map<String, _CacheEntry>>{};
  final _totals = <CacheBucket, int>{};
  // Folding an older session's files into `_entries` needs one directory
  // listing, so it runs at most once per bucket per process, in the background.
  final _scans = <CacheBucket, Future<void>>{};
  final _maintenance = <CacheBucket, Future<void>>{};
  int _serial = 0;

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationCacheDirectory()).path}/lazer_cache_v1',
  );

  Future<Directory?> _open() => _root ??= () async {
    try {
      return await (await _directory()).create(recursive: true);
    } catch (_) {
      // A missing/unwritable cache must not prevent streaming or API access.
      return null;
    }
  }();

  Future<File?> _path(CacheBucket bucket, String key, String extension) async {
    final root = await _open();
    if (root == null) return null;
    final dir = await Directory(
      '${root.path}/${bucket.name}',
    ).create(recursive: true);
    final hash = sha256.convert(utf8.encode(key));
    return File('${dir.path}/$hash.$extension');
  }

  Future<File?> find(
    CacheBucket bucket,
    String key, {
    String extension = 'bin',
  }) async {
    try {
      final file = await _path(bucket, key, extension);
      if (file == null) return null;
      if (!await file.exists() || await file.length() == 0) {
        // The record outlived the file (manual cleanup, crashed session): drop
        // it so the bucket's running total stays honest.
        _forget(bucket, file.path);
        return null;
      }
      await file.setLastModified(DateTime.now());
      // Pre-existing files are folded in by the background scan, which reads
      // the timestamp written just above; session writes are already recorded.
      _entries[bucket]?[_nameOf(file.path)]?.modified = DateTime.now();
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(
    CacheBucket bucket,
    String key, {
    String extension = 'bin',
  }) async {
    try {
      final file = await _path(bucket, key, extension);
      if (file == null) return;
      if (await file.exists()) await file.delete();
      _forget(bucket, file.path);
    } catch (_) {}
  }

  /// Coalesces concurrent writers, streams to a temporary file, then commits.
  Future<File?> put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source, {
    String extension = 'bin',
    int? expectedLength,
    int? maxBytes,
  }) {
    final identity = '${bucket.name}:$key:$extension';
    final pending = _writes[identity];
    if (pending != null) return pending;
    final future = _put(
      bucket,
      key,
      source,
      extension,
      expectedLength,
      maxBytes,
    );
    _writes[identity] = future;
    unawaited(future.whenComplete(() => _writes.remove(identity)));
    return future;
  }

  Future<File?> _put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source,
    String extension,
    int? expectedLength,
    int? maxBytes,
  ) async {
    File? partial;
    IOSink? sink;
    try {
      final target = await _path(bucket, key, extension);
      if (target == null) return null;
      final budget = limits[bucket] ?? 0;
      final ceiling = maxBytes == null
          ? budget
          : (maxBytes < budget ? maxBytes : budget);
      if (ceiling <= 0 || (expectedLength ?? 0) > ceiling) return null;
      partial = File('${target.path}.${_serial++}.part');
      sink = partial.openWrite();
      // Observe disk failures immediately while the network stream is active.
      final done = sink.done.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      var length = 0;
      await for (final chunk in source()) {
        length += chunk.length;
        if (length > ceiling) {
          throw const FileSystemException('Cache entry too large');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final failure = await done;
      if (failure != null) throw failure;
      if (length == 0 ||
          (expectedLength != null &&
              expectedLength >= 0 &&
              length != expectedLength)) {
        throw const FileSystemException('Incomplete cache entry');
      }
      await partial.rename(target.path);
      partial = null;
      // Record first, then evict. Both steps only walk the in-memory records,
      // so the cost of a write is the number of entries it drops rather than
      // the number of files the bucket holds — and that stays true once the
      // bucket is full, which is the state the old scan ran in all the time.
      final int total = _remember(bucket, target, length);
      unawaited(_scan(bucket));
      if (total > (limits[bucket] ?? 0)) {
        try {
          await _prune(bucket, _nameOf(target.path));
        } catch (_) {
          // A failed eviction must never discard the file just written.
        }
      }
      return target;
    } catch (_) {
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {}
    }
  }

  /// Records a freshly written file and returns the bucket total.
  int _remember(CacheBucket bucket, File target, int size) {
    final entries = _entries.putIfAbsent(bucket, () => <String, _CacheEntry>{});
    final String name = _nameOf(target.path);
    final int replaced = entries[name]?.size ?? 0;
    entries[name] = _CacheEntry(target.path, size, DateTime.now());
    final int total = (_totals[bucket] ?? 0) - replaced + size;
    return _totals[bucket] = total < 0 ? 0 : total;
  }

  void _forget(CacheBucket bucket, String path) {
    final entry = _entries[bucket]?.remove(_nameOf(path));
    if (entry == null) return;
    final int total = (_totals[bucket] ?? 0) - entry.size;
    _totals[bucket] = total < 0 ? 0 : total;
  }

  /// Files are keyed by name: `Directory.list()` and the path a write built can
  /// disagree on separators, and two spellings of the same file would be
  /// counted twice and evicted as two entries.
  static String _nameOf(String path) {
    final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
    return (cut < 0 ? path : path.substring(cut + 1)).toLowerCase();
  }

  /// Folds files left by an earlier session into the records: one directory
  /// listing per bucket per process, never on a write's critical path.
  Future<void> _scan(CacheBucket bucket) =>
      _scans[bucket] ??= _scanBucket(bucket);

  Future<void> _scanBucket(CacheBucket bucket) async {
    try {
      final root = await _open();
      if (root == null) return;
      final entries = _entries.putIfAbsent(
        bucket,
        () => <String, _CacheEntry>{},
      );
      _totals.putIfAbsent(bucket, () => 0);
      await for (final entity in Directory(
        '${root.path}/${bucket.name}',
      ).list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (entity.path.endsWith('.part')) {
          if (DateTime.now().difference(stat.modified) >
              const Duration(days: 1)) {
            await entity.delete();
          }
          continue;
        }
        final String name = _nameOf(entity.path);
        // Already recorded by a write from this session, and already counted.
        if (entries.containsKey(name)) continue;
        entries[name] = _CacheEntry(entity.path, stat.size, stat.modified);
        _totals[bucket] = (_totals[bucket] ?? 0) + stat.size;
      }
      if ((_totals[bucket] ?? 0) > (limits[bucket] ?? 0)) {
        await _prune(bucket, '');
      }
    } catch (_) {}
  }

  /// Serializes eviction per bucket so overlapping writes cannot race on the
  /// same records, then drops the least recently used entries until the bucket
  /// fits its budget again. [keepName] is the entry just written, never evicted.
  Future<void> _prune(CacheBucket bucket, String keep) {
    final previous = _maintenance[bucket] ?? Future<void>.value();
    final next = previous.then((_) => _pruneNow(bucket, keep));
    _maintenance[bucket] = next;
    return next;
  }

  Future<void> _pruneNow(CacheBucket bucket, String keep) async {
    try {
      final entries = _entries[bucket];
      final int limit = limits[bucket] ?? 0;
      if (entries == null || entries.isEmpty || limit <= 0) return;
      int total = _totals[bucket] ?? 0;
      if (total <= limit) return;
      // Trim with headroom. A bucket trimmed back to exactly its limit is over
      // budget again on the very next write, and a full bucket — the normal
      // state of the artwork bucket — would then sort its records on every
      // download. Clearing ~10% costs one or two extra files per pass and buys
      // ~10 writes that walk nothing.
      final int trimTo = limit - limit ~/ 10;
      final candidates = <MapEntry<String, _CacheEntry>>[
        for (final entry in entries.entries)
          if (entry.key != keep) entry,
      ]..sort((a, b) => a.value.modified.compareTo(b.value.modified));
      for (final MapEntry<String, _CacheEntry> candidate in candidates) {
        if (total <= trimTo) break;
        try {
          final file = File(candidate.value.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        entries.remove(candidate.key);
        total -= candidate.value.size;
      }
      _totals[bucket] = total < 0 ? 0 : total;
    } catch (_) {}
  }

  Future<CachedJson?> readJson(String key) async {
    try {
      final file = await find(CacheBucket.data, key, extension: 'json');
      if (file == null) return null;
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return CachedJson(
        value['data'] as Map<String, dynamic>,
        DateTime.fromMillisecondsSinceEpoch(value['savedAt'] as int),
      );
    } catch (_) {
      await remove(CacheBucket.data, key, extension: 'json');
      return null;
    }
  }

  /// Expire a snapshot without losing its offline fallback.
  Future<void> expireJson(String key) async {
    final saved = await readJson(key);
    if (saved != null) {
      await writeJson(
        key,
        saved.data,
        savedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
  }

  Future<void> writeJson(
    String key,
    Map<String, dynamic> data, {
    DateTime? savedAt,
  }) async {
    final bytes = utf8.encode(
      jsonEncode({
        'savedAt': (savedAt ?? DateTime.now()).millisecondsSinceEpoch,
        'data': data,
      }),
    );
    await put(
      CacheBucket.data,
      key,
      () => Stream.value(bytes),
      extension: 'json',
    );
  }
}

class CachedJson {
  const CachedJson(this.data, this.savedAt);
  final Map<String, dynamic> data;
  final DateTime savedAt;
  bool fresh(Duration ttl) => DateTime.now().difference(savedAt) < ttl;
}

/// One file on disk as the cache remembers it: where it lives, how much it
/// costs the bucket budget and how recently it was used.
class _CacheEntry {
  _CacheEntry(this.path, this.size, this.modified);
  final String path;
  final int size;
  DateTime modified;
}
