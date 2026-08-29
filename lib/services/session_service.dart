// lib/services/session_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/project_state.dart';

/// A recovery snapshot found on disk at startup.
class RecoverySnapshot {
  const RecoverySnapshot({
    required this.savedAt,
    required this.projectName,
    required this.projectPath,
    required this.projectJson,
  });

  final DateTime savedAt;
  final String projectName;

  /// The .nw file this work belonged to, or null if it was never saved.
  final String? projectPath;

  /// The project payload, encoded for ProjectState.applyProjectJson.
  final String projectJson;

  Duration get age => DateTime.now().difference(savedAt);

  String get ageDescription {
    final d = age;
    if (d.inSeconds < 90) return '${d.inSeconds} seconds ago';
    if (d.inMinutes < 90) return '${d.inMinutes} minutes ago';
    if (d.inHours < 36) return '${d.inHours} hours ago';
    return '${d.inDays} days ago';
  }
}

/// Everything that outlives a single project: which file to reopen on launch,
/// and the crash recovery snapshot.
///
/// This is deliberately the only place that knows about SharedPreferences or
/// about where snapshots live on disk. ProjectState reports edits and clean
/// states through two callbacks and stays ignorant of both.
class SessionService extends ChangeNotifier {
  static const String _restoreKey = 'session_restore_last_project';
  static const String _autosaveKey = 'session_autosave_enabled';
  static const String _lastPathKey = 'session_last_project_path';

  static const String _dirName = 'autosave';
  static const String _currentName = 'current.nwauto';
  static const String _historyDirName = 'history';
  static const String _snapshotKind = 'node_writer_autosave';

  /// Quiet period after the last edit before a snapshot is written.
  static const Duration _debounce = Duration(seconds: 2);

  /// Continuous typing keeps resetting the debounce, so a snapshot is forced
  /// this long after the first unsaved edit regardless.
  static const Duration _maxLatency = Duration(seconds: 20);

  /// How much history is kept behind the current snapshot.
  static const Duration _historyWindow = Duration(minutes: 2);

  /// Minimum spacing between retained history entries. Without this, a burst
  /// of two second flushes would fill the window with near identical files.
  static const Duration _historyStride = Duration(seconds: 15);

  ProjectState? _state;
  SharedPreferences? _prefs;
  Directory? _dir;

  bool _restoreLastProject = true;
  bool _autosaveEnabled = true;
  String? _lastProjectPath;

  /// True when the portable directory was not writable and snapshots landed in
  /// the platform application support directory instead.
  bool _usingFallbackDir = false;

  Timer? _debounceTimer;
  Timer? _maxLatencyTimer;
  bool _writing = false;
  bool _writeAgain = false;
  DateTime? _lastSnapshotAt;
  String? _lastError;

  bool get restoreLastProject => _restoreLastProject;
  bool get autosaveEnabled => _autosaveEnabled;
  String? get lastProjectPath => _lastProjectPath;
  bool get usingFallbackDir => _usingFallbackDir;
  DateTime? get lastSnapshotAt => _lastSnapshotAt;
  String? get lastError => _lastError;
  String get snapshotDirectory => _dir?.path ?? '(not resolved yet)';

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  Future<void> attach(ProjectState state) async {
    _state = state;
    _prefs = await SharedPreferences.getInstance();
    _restoreLastProject = _prefs?.getBool(_restoreKey) ?? true;
    _autosaveEnabled = _prefs?.getBool(_autosaveKey) ?? true;
    _lastProjectPath = _prefs?.getString(_lastPathKey);
    await _resolveDir();

    state.onEdit = _onEdit;
    state.onProjectSettled = _onProjectSettled;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _maxLatencyTimer?.cancel();
    final state = _state;
    if (state != null) {
      state.onEdit = null;
      state.onProjectSettled = null;
    }
    super.dispose();
  }

  Future<void> setRestoreLastProject(bool value) async {
    if (_restoreLastProject == value) return;
    _restoreLastProject = value;
    await _prefs?.setBool(_restoreKey, value);
    notifyListeners();
  }

  Future<void> setAutosaveEnabled(bool value) async {
    if (_autosaveEnabled == value) return;
    _autosaveEnabled = value;
    await _prefs?.setBool(_autosaveKey, value);
    if (!value) {
      _debounceTimer?.cancel();
      _maxLatencyTimer?.cancel();
      await clearSnapshots();
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Snapshot location
  // ---------------------------------------------------------------------

  /// The portable directory: beside the executable for a shipped build, or the
  /// project directory when running from source, since a dev build puts the
  /// executable under build/ inside the project.
  ///
  /// Falls back to application support when that directory cannot be written,
  /// which is what happens for a system wide install under /opt or Program
  /// Files. A writing tool should not lose its recovery snapshot over a
  /// permissions detail the author never chose.
  Future<Directory> _resolveDir() async {
    final existing = _dir;
    if (existing != null) return existing;

    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String cwd = Directory.current.path;
    final String portableRoot = p.isWithin(cwd, exeDir) ? cwd : exeDir;

    final Directory preferred = Directory(p.join(portableRoot, _dirName));
    if (await _isUsable(preferred)) {
      _usingFallbackDir = false;
      _dir = preferred;
      return preferred;
    }

    final Directory support = Directory(
      p.join((await getApplicationSupportDirectory()).path, _dirName),
    );
    await support.create(recursive: true);
    _usingFallbackDir = true;
    _dir = support;
    return support;
  }

  Future<bool> _isUsable(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<File> _currentFile() async =>
      File(p.join((await _resolveDir()).path, _currentName));

  Future<Directory> _historyDir() async =>
      Directory(p.join((await _resolveDir()).path, _historyDirName));

  // ---------------------------------------------------------------------
  // Autosave
  // ---------------------------------------------------------------------

  void _onEdit() {
    if (!_autosaveEnabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _flush);
    _maxLatencyTimer ??= Timer(_maxLatency, _flush);
  }

  void _onProjectSettled(String? path) {
    _debounceTimer?.cancel();
    _maxLatencyTimer?.cancel();
    _debounceTimer = null;
    _maxLatencyTimer = null;
    if (path != null) {
      _lastProjectPath = path;
      _prefs?.setString(_lastPathKey, path);
    }
    // The document now matches something on disk, so any recovery snapshot
    // describes a state the author no longer needs recovering.
    unawaited(clearSnapshots());
    notifyListeners();
  }

  /// Writes a snapshot immediately. Safe to call at any time.
  Future<void> flushNow() => _flush();

  Future<void> _flush() async {
    _debounceTimer?.cancel();
    _maxLatencyTimer?.cancel();
    _debounceTimer = null;
    _maxLatencyTimer = null;

    final state = _state;
    if (state == null || !_autosaveEnabled) return;
    if (!state.isDirty) return;

    // A flush already in progress: remember to run once more afterwards rather
    // than interleaving two writes over the same file.
    if (_writing) {
      _writeAgain = true;
      return;
    }
    _writing = true;

    try {
      final String payload = jsonEncode(<String, dynamic>{
        'kind': _snapshotKind,
        'version': 1,
        'saved_at': DateTime.now().toIso8601String(),
        'project_name': state.projectName,
        'project_path': state.activeFilePath,
        'project': state.toJson(),
      });

      final File current = await _currentFile();
      await _rotateIntoHistory(current);
      await _writeAtomic(current, payload);
      await _pruneHistory();

      _lastSnapshotAt = DateTime.now();
      _lastError = null;
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _writing = false;
      notifyListeners();
      if (_writeAgain) {
        _writeAgain = false;
        unawaited(_flush());
      }
    }
  }

  /// Moves the outgoing snapshot into history, but only once per stride, so a
  /// long writing session leaves a readable ladder of states instead of one
  /// file every two seconds.
  Future<void> _rotateIntoHistory(File current) async {
    if (!await current.exists()) return;
    final FileStat stat = await current.stat();
    final Directory history = await _historyDir();
    await history.create(recursive: true);

    final DateTime? newest = await _newestHistoryTime(history);
    if (newest != null && stat.modified.difference(newest) < _historyStride) {
      return;
    }
    final String name = '${stat.modified.millisecondsSinceEpoch}.nwauto';
    await current.copy(p.join(history.path, name));
  }

  Future<DateTime?> _newestHistoryTime(Directory history) async {
    DateTime? newest;
    for (final int stamp in await _historyStamps(history)) {
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(stamp);
      if (newest == null || t.isAfter(newest)) newest = t;
    }
    return newest;
  }

  /// History filenames are epoch milliseconds, so the name is the timestamp and
  /// no extra index file has to be kept in sync with the directory.
  Future<List<int>> _historyStamps(Directory history) async {
    if (!await history.exists()) return const <int>[];
    final stamps = <int>[];
    await for (final entity in history.list(followLinks: false)) {
      if (entity is! File) continue;
      final String base = p.basenameWithoutExtension(entity.path);
      final int? stamp = int.tryParse(base);
      if (stamp != null) stamps.add(stamp);
    }
    stamps.sort();
    return stamps;
  }

  Future<void> _pruneHistory() async {
    final Directory history = await _historyDir();
    final List<int> stamps = await _historyStamps(history);
    if (stamps.length <= 1) return;

    final int cutoff =
        DateTime.now().subtract(_historyWindow).millisecondsSinceEpoch;
    // Always keep the newest entry even when it has aged out, so there is a
    // step back available after a long pause.
    for (final int stamp in stamps.sublist(0, stamps.length - 1)) {
      if (stamp >= cutoff) continue;
      try {
        await File(p.join(history.path, '$stamp.nwauto')).delete();
      } catch (_) {}
    }
  }

  /// Temp file plus rename, so a crash mid write cannot leave a half encoded
  /// snapshot where a whole one used to be. The delete before rename is for
  /// Windows, where renaming onto an existing file fails; the history copy
  /// covers the brief window that opens.
  Future<void> _writeAtomic(File target, String contents) async {
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
  }

  // ---------------------------------------------------------------------
  // Recovery
  // ---------------------------------------------------------------------

  /// Reads the snapshot left by a previous session, or null when there is
  /// nothing worth offering.
  Future<RecoverySnapshot?> findRecovery() async {
    if (!_autosaveEnabled) return null;
    try {
      final File current = await _currentFile();
      if (!await current.exists()) return null;

      final decoded = jsonDecode(await current.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != _snapshotKind) return null;

      final project = decoded['project'];
      if (project is! Map<String, dynamic>) return null;

      final DateTime savedAt =
          DateTime.tryParse(decoded['saved_at']?.toString() ?? '') ??
              (await current.stat()).modified;
      final String? projectPath = decoded['project_path']?.toString();

      // The project file may have been saved after this snapshot was taken,
      // by this app on a later run or by anything else. Recovering then would
      // hand back older work than what is already on disk.
      if (projectPath != null && projectPath.isNotEmpty) {
        final File onDisk = File(projectPath);
        if (await onDisk.exists()) {
          final DateTime modified = (await onDisk.stat()).modified;
          if (modified.isAfter(savedAt)) {
            await clearSnapshots();
            return null;
          }
        }
      }

      return RecoverySnapshot(
        savedAt: savedAt,
        projectName: decoded['project_name']?.toString() ?? 'Untitled',
        projectPath: (projectPath == null || projectPath.isEmpty)
            ? null
            : projectPath,
        projectJson: jsonEncode(project),
      );
    } catch (e) {
      _lastError = e.toString();
      return null;
    }
  }

  /// The .nw file to reopen on launch, or null when the setting is off, no
  /// project was ever saved, or the file has since moved.
  Future<String?> resolveStartupProject() async {
    if (!_restoreLastProject) return null;
    final String? path = _lastProjectPath;
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  Future<void> forgetLastProject() async {
    _lastProjectPath = null;
    await _prefs?.remove(_lastPathKey);
    notifyListeners();
  }

  Future<void> clearSnapshots() async {
    try {
      final File current = await _currentFile();
      if (await current.exists()) await current.delete();
      final Directory history = await _historyDir();
      if (await history.exists()) await history.delete(recursive: true);
      _lastSnapshotAt = null;
    } catch (e) {
      _lastError = e.toString();
    }
  }
}