// lib/state/project_state.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';

import '../constants.dart';
import '../models/story_node.dart';
import '../models/authorial_constraint.dart';
import '../models/compiled_manuscript.dart';

/// Outcome of a project file operation.
///
/// Disk errors used to disappear into a debugPrint. In a writing application a
/// silent save failure is indistinguishable from a successful save, so every
/// file entry point now reports back and the UI is expected to say so.
class ProjectIoResult {
  const ProjectIoResult.ok(this.path)
      : error = null,
        cancelled = false;
  const ProjectIoResult.failed(this.error)
      : path = null,
        cancelled = false;
  const ProjectIoResult.cancelled()
      : path = null,
        error = null,
        cancelled = true;

  final String? path;
  final String? error;
  final bool cancelled;

  bool get succeeded => error == null && !cancelled;
}

/// How a compiled manuscript is assembled from the graph.
///
/// Ollama wants scene headings for orientation. A manuscript export usually
/// does not. The same compiler serves both, so the shape is a parameter rather
/// than a hard-coded convention.
class CompileOptions {
  const CompileOptions({
    this.includeTitles = true,
    this.includeSeparators = true,
  });

  final bool includeTitles;
  final bool includeSeparators;

  String get cacheKey => '${includeTitles ? 1 : 0}${includeSeparators ? 1 : 0}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompileOptions &&
          other.includeTitles == includeTitles &&
          other.includeSeparators == includeSeparators;

  @override
  int get hashCode => Object.hash(includeTitles, includeSeparators);
}

class ProjectState extends ChangeNotifier {
  final Map<String, StoryNode> _nodes = {};
  String _projectName = "Untitled";
  String? _activeFilePath;
  String _unitLabel = "Scene";

  /// Export shape. Ollama input always keeps headings so the model can see the
  /// structure; only author-facing compilation follows these.
  bool _exportTitles = true;
  bool _exportSeparators = true;

  bool _dirty = false;

  final TransformationController canvasController = TransformationController();
  final GlobalKey canvasKey = GlobalKey();
  Set<String> _selectedNodeIds = {};
  String? _previewNodeId;
  Rect? _lassoRect;
  Offset? _lassoStart;

  String? _draggingWireSourceId;
  Offset? _draggingWireHead;
  String? _hoveredTargetId;
  String? _hoveredSwapTargetId;
  int? _hoveredMergePortIndex;

  String? _hoveredWireSourceId;
  int _hoveredWireIndex = -1;
  bool _isInvalidCycle = false;
  String? _clipboardData;

  final Map<String, List<String>> _mergePorts = {};
  final Map<String, int> _nodeSequence = {};
  Set<String> _activePathIds = {};

  /// Compiled output is derived from the whole reachable graph, so it used to
  /// be rebuilt on every notifyListeners, including every frame of a node
  /// drag. It is cached here and invalidated by the mutators that can change
  /// it.
  final Map<String, CompiledManuscript> _compileCache = {};

  /// Bumped whenever compiled output could have changed. Panels that derive
  /// expensive things from the graph memoize against this instead of rebuilding
  /// on every notification.
  int _revision = 0;

  final List<String> _undoStack = [];
  static const int _maxUndo = 100;
  static const Duration _undoIdleGap = Duration(milliseconds: 900);
  static const Duration _undoMaxGroup = Duration(seconds: 8);
  Timer? _undoDebounceTimer;
  bool _undoGroupOpen = false;
  DateTime? _undoGroupStarted;

  int _droppedConstraints = 0;

  /// Incremented by every change that dirties the document.
  ///
  /// The session layer cannot listen for edits: updateNodeContent deliberately
  /// does not call notifyListeners, because the TextField already owns the text
  /// it displays, so typing is invisible to a listener. This counter and the
  /// onEdit callback below are the signal instead.
  int _editSerial = 0;

  /// Fired whenever the document is dirtied. The session layer debounces this
  /// into an autosave snapshot. Kept as a callback rather than a listener so
  /// that silent content edits still reach it.
  void Function()? onEdit;

  /// Fired when the document reaches a state that matches disk: a successful
  /// save, a successful open, or a new empty project. Carries the file path
  /// when there is one, so the session layer can remember what to reopen.
  void Function(String? path)? onProjectSettled;

  ProjectState() {
    newProject();
  }

  Map<String, StoryNode> get nodes => _nodes;
  String get projectName => _projectName;
  String? get activeFilePath => _activeFilePath;
  String get unitLabel => _unitLabel;
  bool get isDirty => _dirty;
  bool get exportTitles => _exportTitles;
  bool get exportSeparators => _exportSeparators;
  Set<String> get selectedNodeIds => _selectedNodeIds;
  Rect? get lassoRect => _lassoRect;
  String? get previewNodeId => _previewNodeId;
  String? get draggingWireSourceId => _draggingWireSourceId;
  Offset? get draggingWireHead => _draggingWireHead;
  String? get hoveredTargetId => _hoveredTargetId;
  String? get hoveredSwapTargetId => _hoveredSwapTargetId;
  int? get hoveredMergePortIndex => _hoveredMergePortIndex;
  String? get hoveredWireSourceId => _hoveredWireSourceId;
  int get hoveredWireIndex => _hoveredWireIndex;
  bool get isInvalidCycle => _isInvalidCycle;
  Set<String> get activePathIds => _activePathIds;
  int getNodeIndex(String id) => _nodeSequence[id] ?? -1;
  int get revision => _revision;
  int get editSerial => _editSerial;

  void _invalidateCompiled() {
    _compileCache.clear();
    _revision++;
  }

  CompileOptions get exportOptions => CompileOptions(
        includeTitles: _exportTitles,
        includeSeparators: _exportSeparators,
      );

  /// Locks that were discarded because an edit overwrote the characters they
  /// protected. The editor reads and clears this so it can tell the author,
  /// rather than moving an authorial lock onto text the author did not write.
  int consumeDroppedConstraintCount() {
    final value = _droppedConstraints;
    _droppedConstraints = 0;
    return value;
  }

  @override
  void dispose() {
    _undoDebounceTimer?.cancel();
    canvasController.dispose();
    super.dispose();
  }

  /// Marks the document as changed and tells the session layer.
  ///
  /// Every path that used to set _dirty directly goes through here. Some of
  /// those changes (a node move, an alignment switch) do not affect compiled
  /// text, which is why this does not invalidate the compile cache; callers
  /// that do change the text use _markDirty.
  void _touch() {
    _dirty = true;
    _editSerial++;
    onEdit?.call();
  }

  void _markDirty() {
    _touch();
    _invalidateCompiled();
  }

  void setUnitLabel(String label) {
    if (_unitLabel == label) return;
    recordUndo();
    _unitLabel = label;
    _markDirty();
    notifyListeners();
  }

  void setExportShape({bool? includeTitles, bool? includeSeparators}) {
    final nextTitles = includeTitles ?? _exportTitles;
    final nextSeparators = includeSeparators ?? _exportSeparators;
    if (nextTitles == _exportTitles && nextSeparators == _exportSeparators) {
      return;
    }
    _exportTitles = nextTitles;
    _exportSeparators = nextSeparators;
    _markDirty();
    notifyListeners();
  }

  void newProject() {
    _nodes.clear();
    _undoStack.clear();
    _mergePorts.clear();
    _invalidateCompiled();
    _projectName = "Untitled";
    _activeFilePath = null;
    _selectedNodeIds.clear();
    _clipboardData = null;
    _previewNodeId = null;
    _exportTitles = true;
    _exportSeparators = true;

    canvasController.value = Matrix4.identity()
      ..translate(-kWorldSize / 2 + 600, -kWorldSize / 2 + 350);

    final sceneId = const Uuid().v4();
    final outputId = const Uuid().v4();

    _nodes[sceneId] = StoryNode(
      id: sceneId,
      position: const Offset(kWorldSize / 2, kWorldSize / 2),
      title: "$_unitLabel 1",
      content: "The story starts here...",
      nextNodeIds: [outputId],
    );
    _nodes[outputId] = StoryNode(
      id: outputId,
      type: NodeType.output,
      position: const Offset(kWorldSize / 2, kWorldSize / 2 + 250),
      title: "FINAL OUTPUT",
    );

    _selectedNodeIds = {sceneId};
    _recalculateSequence();
    _dirty = false;
    // An empty project is a clean state, so any recovery snapshot from the
    // document that was just discarded should go with it.
    onProjectSettled?.call(null);
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------

  Future<ProjectIoResult> saveProject() async {
    if (_activeFilePath == null) return saveAsProject();
    return _writeToDisk(_activeFilePath!);
  }

  Future<ProjectIoResult> saveAsProject() async {
    String? outputFile;
    try {
      outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Project As',
        fileName: '$_projectName.nw',
        type: FileType.custom,
        allowedExtensions: ['nw'],
      );
    } catch (e) {
      return ProjectIoResult.failed('Could not open the save dialog: $e');
    }
    if (outputFile == null) return const ProjectIoResult.cancelled();
    final String path =
        outputFile.endsWith('.nw') ? outputFile : '$outputFile.nw';

    // Rename before writing, so the name stored inside the file matches the
    // file it is stored in. Rolled back if the write fails.
    final String previousName = _projectName;
    final String? previousPath = _activeFilePath;
    _projectName = path.split(Platform.pathSeparator).last.replaceAll('.nw', '');
    _activeFilePath = path;

    final result = await _writeToDisk(path);
    if (!result.succeeded) {
      _projectName = previousName;
      _activeFilePath = previousPath;
    }
    notifyListeners();
    return result;
  }

  Map<String, dynamic> toJson() => {
        'version': 22,
        'name': _projectName,
        'unit_label': _unitLabel,
        'export_titles': _exportTitles,
        'export_separators': _exportSeparators,
        'nodes': _nodes.values.map((n) => n.toJson()).toList(),
      };

  /// Writes through a temp file and keeps one generation of backup.
  ///
  /// A direct writeAsString truncates the target before the new bytes land, so
  /// a crash or a full disk mid-write destroys the project rather than leaving
  /// the previous version intact.
  Future<ProjectIoResult> _writeToDisk(String path) async {
    final tmp = File('$path.tmp');
    final target = File(path);
    final backup = File('$path.bak');
    try {
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);

      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
      }
      await tmp.rename(path);

      _dirty = false;
      onProjectSettled?.call(path);
      notifyListeners();
      return ProjectIoResult.ok(path);
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return ProjectIoResult.failed('Could not save to $path: $e');
    }
  }

  Future<ProjectIoResult> loadProject() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: ['nw']);
    } catch (e) {
      return ProjectIoResult.failed('Could not open the file dialog: $e');
    }
    final path = result?.files.single.path;
    if (path == null) return const ProjectIoResult.cancelled();
    return openProjectAtPath(path);
  }

  /// Opens a known file without a picker.
  ///
  /// Reopening the last project on launch and the file dialog share this, so
  /// there is one definition of what opening a project does to live state.
  Future<ProjectIoResult> openProjectAtPath(String path) async {
    try {
      final String jsonStr = await File(path).readAsString();
      applyProjectJson(jsonStr);
      _activeFilePath = path;
      _dirty = false;
      onProjectSettled?.call(path);
      notifyListeners();
      return ProjectIoResult.ok(path);
    } catch (e) {
      return ProjectIoResult.failed('Could not open $path: $e');
    }
  }

  /// Adopts a recovery snapshot.
  ///
  /// The document deliberately comes back dirty: the snapshot is work that
  /// never reached disk, and the unsaved marker is the honest description of
  /// it until the author saves. [filePath] is the .nw the work belonged to, so
  /// Ctrl+S goes back to the right file instead of opening Save As.
  ProjectIoResult restoreFromSnapshot(String projectJson, {String? filePath}) {
    try {
      applyProjectJson(projectJson);
      _activeFilePath = filePath;
      if (filePath != null) {
        _projectName =
            filePath.split(Platform.pathSeparator).last.replaceAll('.nw', '');
      }
      _dirty = true;
      notifyListeners();
      return ProjectIoResult.ok(filePath ?? '');
    } catch (e) {
      return ProjectIoResult.failed('Could not restore the recovered work: $e');
    }
  }

  /// Parses fully into local structures before touching live state.
  ///
  /// The previous version cleared the node map first, so a malformed or older
  /// file left the author with an empty canvas and no explanation. Throws on
  /// bad input; the current project is untouched when it does.
  void applyProjectJson(String jsonStr, {bool resetHistory = true}) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Not a Node Writer project file.');
    }
    final rawNodes = decoded['nodes'];
    if (rawNodes is! List) {
      throw const FormatException('Project file has no node list.');
    }

    final parsed = <String, StoryNode>{};
    for (final entry in rawNodes) {
      if (entry is! Map) {
        throw const FormatException('Project file contains a malformed node.');
      }
      final node = StoryNode.fromJson(Map<String, dynamic>.from(entry));
      parsed[node.id] = node;
    }

    // Drop edges that point at nodes the file does not contain, so a truncated
    // file opens as a valid smaller graph instead of a crashing one.
    for (final node in parsed.values) {
      node.nextNodeIds.removeWhere((id) => !parsed.containsKey(id));
    }

    _nodes
      ..clear()
      ..addAll(parsed);
    // Undo replays snapshots through this same path, and must not erase the
    // history it is walking.
    if (resetHistory) _undoStack.clear();
    _mergePorts.clear();
    _invalidateCompiled();
    _projectName = decoded['name']?.toString() ?? 'Untitled';
    _unitLabel = decoded['unit_label']?.toString() ?? 'Scene';
    _exportTitles = decoded['export_titles'] as bool? ?? true;
    _exportSeparators = decoded['export_separators'] as bool? ?? true;
    _selectedNodeIds.clear();
    _previewNodeId = null;

    canvasController.value = Matrix4.identity()
      ..translate(-kWorldSize / 2 + 600, -kWorldSize / 2 + 350);

    _recalculateSequence();
  }

  // ---------------------------------------------------------------------
  // Graph editing
  // ---------------------------------------------------------------------

  void addNode(Offset centerPos, [NodeType type = NodeType.scene]) {
    recordUndo();
    final id = const Uuid().v4();
    String title = type == NodeType.scene ? "New $_unitLabel" : "MERGE";
    if (type == NodeType.output) title = "FINAL OUTPUT";
    if (type == NodeType.ollama) title = "OLLAMA OUTPUT";

    _nodes[id] = StoryNode(
      id: id,
      type: type,
      position: centerPos - const Offset(kNodeWidth / 2, kNodeHeight / 2),
      title: title,
    );
    _selectedNodeIds = {id};
    _markDirty();
    notifyListeners();
  }

  void deleteSelected() {
    if (_selectedNodeIds.isEmpty) return;
    final toDelete = _selectedNodeIds
        .where((id) => _nodes[id]?.type != NodeType.output)
        .toList();
    if (toDelete.isEmpty) return;
    recordUndo();
    for (var id in toDelete) {
      _nodes.remove(id);
      _mergePorts.remove(id);
      for (var node in _nodes.values) {
        node.nextNodeIds.remove(id);
      }
      for (final ports in _mergePorts.values) {
        for (var i = 0; i < ports.length; i++) {
          if (ports[i] == id) ports[i] = "";
        }
      }
    }
    _selectedNodeIds.clear();
    _previewNodeId = null;
    _recalculateSequence();
    _markDirty();
    notifyListeners();
  }

  void updateNodePosition(String id, Offset delta) {
    requestUndoSnapshot();
    if (_selectedNodeIds.contains(id)) {
      for (var selId in _selectedNodeIds) {
        if (_nodes.containsKey(selId)) _nodes[selId]!.position += delta;
      }
    } else {
      if (_nodes.containsKey(id)) _nodes[id]!.position += delta;
    }
    if (_selectedNodeIds.length == 1) _checkWireHover(id);
    _touch();
    notifyListeners();
  }

  void _checkWireHover(String nodeId) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    _hoveredWireSourceId = null;
    _hoveredWireIndex = -1;

    if (isShift && _nodes.containsKey(nodeId)) {
      final nodeCenter = _nodes[nodeId]!.position +
          Offset(kNodeWidth / 2, _nodes[nodeId]!.currentHeight / 2);
      for (var source in _nodes.values) {
        if (source.id == nodeId) continue;
        for (int i = 0; i < source.nextNodeIds.length; i++) {
          final targetId = source.nextNodeIds[i];
          if (targetId == nodeId || !_nodes.containsKey(targetId)) continue;
          // Splicing into this wire would make the dragged node both a child
          // of source and a parent of target. Reject the hover if either half
          // closes a loop.
          if (_detectCycle(source.id, nodeId) ||
              _detectCycle(nodeId, targetId)) {
            continue;
          }
          if (_distanceToLineSegment(
                nodeCenter,
                getOutputPortGlobal(source.id),
                getInputPortGlobal(targetId, source.id),
              ) <
              50) {
            _hoveredWireSourceId = source.id;
            _hoveredWireIndex = i;
            return;
          }
        }
      }
    }
  }

  void onNodeDragEnd(String id) {
    if (_hoveredWireSourceId != null && _hoveredWireIndex != -1) {
      final source = _nodes[_hoveredWireSourceId];
      if (source != null && _hoveredWireIndex < source.nextNodeIds.length) {
        final targetId = source.nextNodeIds[_hoveredWireIndex];
        if (!_detectCycle(source.id, id) && !_detectCycle(id, targetId)) {
          recordUndo();
          source.nextNodeIds[_hoveredWireIndex] = id;
          if (!_nodes[id]!.nextNodeIds.contains(targetId)) {
            _nodes[id]!.nextNodeIds = [targetId];
          }
          _markDirty();
        }
      }
      _hoveredWireSourceId = null;
      _hoveredWireIndex = -1;
    }
    // Ordering at a merge and among siblings follows x position, so a drop can
    // change compiled order even when no wire changed.
    _recalculateSequence();
    _invalidateCompiled();
    notifyListeners();
  }

  void selectNode(String id, {bool additive = false}) {
    // Any explicit canvas selection leaves temporary preview mode.
    _previewNodeId = null;
    if (additive) {
      if (_selectedNodeIds.contains(id)) {
        _selectedNodeIds.remove(id);
      } else {
        _selectedNodeIds.add(id);
      }
    } else {
      if (!_selectedNodeIds.contains(id)) _selectedNodeIds = {id};
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedNodeIds.isNotEmpty) {
      _selectedNodeIds.clear();
      notifyListeners();
    }
  }

  void startLasso(Offset screenPos) {
    _lassoStart = screenToCanvas(screenPos);
    _lassoRect = Rect.fromPoints(_lassoStart!, _lassoStart!);
    _selectedNodeIds.clear();
    notifyListeners();
  }

  void updateLasso(Offset screenPos) {
    if (_lassoStart == null) return;
    _lassoRect = Rect.fromPoints(_lassoStart!, screenToCanvas(screenPos));
    _selectedNodeIds = _nodes.values
        .where((n) => _lassoRect!.overlaps(n.rect))
        .map((n) => n.id)
        .toSet();
    notifyListeners();
  }

  void endLasso() {
    _lassoRect = null;
    _lassoStart = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Port routing
  // ---------------------------------------------------------------------

  List<String> getMergePorts(String targetId) {
    if (!_mergePorts.containsKey(targetId)) {
      List<String> incoming = [];
      for (var node in _nodes.values) {
        if (node.nextNodeIds.contains(targetId)) incoming.add(node.id);
      }
      incoming
          .sort((a, b) => _nodes[a]!.position.dx.compareTo(_nodes[b]!.position.dx));
      _mergePorts[targetId] = [
        incoming.isNotEmpty ? incoming[0] : "",
        incoming.length > 1 ? incoming[1] : "",
        incoming.length > 2 ? incoming[2] : "",
      ];
    }

    List<String> ports = _mergePorts[targetId]!;
    for (int i = 0; i < 3; i++) {
      if (ports[i].isNotEmpty) {
        if (_nodes[ports[i]] == null ||
            !_nodes[ports[i]]!.nextNodeIds.contains(targetId)) {
          ports[i] = "";
        }
      }
    }
    return ports;
  }

  Offset getInputPortGlobal(String targetId, String? sourceId,
      {int? forcePortIndex}) {
    final target = _nodes[targetId];
    if (target == null) return Offset.zero;
    if (target.type != NodeType.merge) return target.inputPortGlobal;

    double spacing = kNodeWidth / 3;
    int portIndex = -1;

    if (forcePortIndex != null) {
      portIndex = forcePortIndex;
    } else if (sourceId != null) {
      List<String> ports = getMergePorts(targetId);
      portIndex = ports.indexOf(sourceId);
    }

    if (portIndex == -1) {
      List<String> ports = getMergePorts(targetId);
      portIndex = ports.indexOf("");
      if (portIndex == -1) portIndex = 2;
    }

    double offsetX = (spacing / 2) + (portIndex * spacing);
    return target.position + Offset(offsetX, 0);
  }

  Offset getOutputPortGlobal(String nodeId) {
    final node = _nodes[nodeId];
    if (node == null) return Offset.zero;
    return node.position + Offset(kNodeWidth / 2, node.currentHeight);
  }

  void startWireDrag(String sourceId) {
    final source = _nodes[sourceId];
    if (source == null ||
        source.type == NodeType.output ||
        source.type == NodeType.ollama) {
      return;
    }
    _draggingWireSourceId = sourceId;
    _draggingWireHead = getOutputPortGlobal(sourceId);
    notifyListeners();
  }

  void updateWireDrag(Offset screenPos) {
    _draggingWireHead = screenToCanvas(screenPos);
    _hoveredTargetId = null;
    _hoveredSwapTargetId = null;
    _hoveredMergePortIndex = null;
    _isInvalidCycle = false;

    for (var node in _nodes.values) {
      if (node.id == _draggingWireSourceId) continue;

      if (node.type == NodeType.merge) {
        bool foundHit = false;
        for (int i = 0; i < 3; i++) {
          double spacing = kNodeWidth / 3;
          double offsetX = (spacing / 2) + (i * spacing);
          Offset exactPortLocation = node.position + Offset(offsetX, 0);

          if ((_draggingWireHead! - exactPortLocation).distance < 60) {
            _hoveredTargetId = node.id;
            _hoveredMergePortIndex = i;
            foundHit = true;
            break;
          }
        }
        if (foundHit) {
          if (_detectCycle(_draggingWireSourceId!, node.id) ||
              _causesCrossContamination(
                  _draggingWireSourceId!, node.id, _hoveredMergePortIndex)) {
            _isInvalidCycle = true;
          }
          break;
        }
      } else {
        Offset targetPort = getInputPortGlobal(node.id, _draggingWireSourceId);
        if ((_draggingWireHead! - targetPort).distance < 60) {
          _hoveredTargetId = node.id;
          if (_detectCycle(_draggingWireSourceId!, node.id) ||
              _causesCrossContamination(_draggingWireSourceId!, node.id, null)) {
            _isInvalidCycle = true;
          }
          break;
        }
      }

      Offset outPort = getOutputPortGlobal(node.id);
      if (node.type != NodeType.output &&
          node.type != NodeType.ollama &&
          (_draggingWireHead! - outPort).distance < 60) {
        _hoveredSwapTargetId = node.id;
        // A swap hands the target's children to the source. If any of them
        // reaches back to the source, that is a loop, and an unguarded loop
        // makes topological compilation recurse forever.
        if (_swapCreatesCycle(_draggingWireSourceId!, node.id) ||
            _causesCrossContamination(_draggingWireSourceId!, node.id, null)) {
          _isInvalidCycle = true;
        }
        break;
      }
    }
    notifyListeners();
  }

  bool _swapCreatesCycle(String sourceId, String swapTargetId) {
    final target = _nodes[swapTargetId];
    if (target == null) return true;
    for (final childId in target.nextNodeIds) {
      if (_detectCycle(sourceId, childId)) return true;
    }
    return false;
  }

  void endWireDrag() {
    if (_draggingWireSourceId != null && !_isInvalidCycle) {
      if (_hoveredTargetId != null) {
        recordUndo();
        _connectNode(_draggingWireSourceId!, _hoveredTargetId!,
            portIndex: _hoveredMergePortIndex);
        _markDirty();
      } else if (_hoveredSwapTargetId != null) {
        final source = _nodes[_draggingWireSourceId]!;
        final target = _nodes[_hoveredSwapTargetId]!;
        recordUndo();
        source.nextNodeIds = List.from(target.nextNodeIds);
        target.nextNodeIds.clear();
        _recalculateSequence();
        _markDirty();
      }
    }
    _draggingWireSourceId = null;
    _draggingWireHead = null;
    _hoveredTargetId = null;
    _hoveredSwapTargetId = null;
    _hoveredMergePortIndex = null;
    _isInvalidCycle = false;
    notifyListeners();
  }

  void _connectNode(String sourceId, String targetId, {int? portIndex}) {
    final source = _nodes[sourceId];
    final target = _nodes[targetId];
    if (source == null || target == null) return;
    if (_detectCycle(sourceId, targetId)) return;

    if (target.type == NodeType.merge) {
      List<String> ports = getMergePorts(targetId);
      int oldIndex = ports.indexOf(sourceId);
      if (oldIndex != -1) ports[oldIndex] = "";

      int targetPort = portIndex ?? ports.indexOf("");
      if (targetPort == -1) targetPort = 2;

      if (ports[targetPort].isNotEmpty) {
        String nodeToDisconnect = ports[targetPort];
        _nodes[nodeToDisconnect]?.nextNodeIds.remove(targetId);
      }
      ports[targetPort] = sourceId;
      _mergePorts[targetId] = ports;
    } else {
      for (var n in _nodes.values) {
        if (n.nextNodeIds.contains(targetId)) n.nextNodeIds.remove(targetId);
      }
    }
    if (!source.nextNodeIds.contains(targetId)) {
      source.nextNodeIds.add(targetId);
    }
    _recalculateSequence();
  }

  bool _causesCrossContamination(
      String sourceId, String targetId, int? targetPortIndex) {
    final Map<String, Set<(String, int)>> destinations = {};
    for (var node in _nodes.values) {
      destinations[node.id] = <(String, int)>{};
    }

    final Map<String, List<String>> incoming = {};
    for (var n in _nodes.values) {
      for (var child in n.nextNodeIds) {
        incoming.putIfAbsent(child, () => []).add(n.id);
      }
    }

    for (var mergeNode in _nodes.values.where((n) => n.type == NodeType.merge)) {
      var ports = getMergePorts(mergeNode.id);
      for (int p = 0; p < ports.length; p++) {
        String rootId = ports[p];
        if (rootId.isEmpty || !_nodes.containsKey(rootId)) continue;

        Set<String> visited = {};
        List<String> queue = [rootId];

        while (queue.isNotEmpty) {
          String curr = queue.removeLast();
          if (visited.add(curr)) {
            destinations[curr]!.add((mergeNode.id, p));
            if (incoming.containsKey(curr)) queue.addAll(incoming[curr]!);
          }
        }
      }
    }

    final Set<(String, int)> sourceDests = {...?destinations[sourceId]};
    final Set<(String, int)> targetDests = {};

    if (_nodes[targetId]?.type == NodeType.merge) {
      if (targetPortIndex != null) targetDests.add((targetId, targetPortIndex));
    } else {
      targetDests.addAll(destinations[targetId] ?? const <(String, int)>{});
    }

    final Map<String, Set<int>> mergeToPorts = {};
    for (final dest in <(String, int)>{...sourceDests, ...targetDests}) {
      mergeToPorts.putIfAbsent(dest.$1, () => <int>{}).add(dest.$2);
      if (mergeToPorts[dest.$1]!.length > 1) return true;
    }
    return false;
  }

  void disconnectNode(String id) {
    if (_nodes[id] == null || _nodes[id]!.nextNodeIds.isEmpty) return;
    recordUndo();
    _nodes[id]!.nextNodeIds.clear();
    _recalculateSequence();
    _markDirty();
    notifyListeners();
  }

  void popNodeOut(String id) {
    if (!_nodes.containsKey(id)) return;
    recordUndo();
    final nodeToPop = _nodes[id]!;
    final childrenIds = List<String>.from(nodeToPop.nextNodeIds);
    for (var node in _nodes.values) {
      if (node.nextNodeIds.contains(id)) {
        node.nextNodeIds.remove(id);
        for (var childId in childrenIds) {
          if (!node.nextNodeIds.contains(childId)) {
            node.nextNodeIds.add(childId);
          }
        }
      }
    }
    nodeToPop.nextNodeIds.clear();
    _recalculateSequence();
    _markDirty();
    notifyListeners();
  }

  void panCanvas(Offset delta) {
    canvasController.value = canvasController.value.clone()
      ..translate(delta.dx, delta.dy);
  }

  Offset screenToCanvas(Offset screenPos) {
    final matrix = canvasController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    return Offset((screenPos.dx - translation.x) / scale,
        (screenPos.dy - translation.y) / scale);
  }

  double _distanceToLineSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a - b).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) /
        l2;
    t = math.max(0, math.min(1, t));
    return (p - (a + (b - a) * t)).distance;
  }

  // ---------------------------------------------------------------------
  // Undo
  // ---------------------------------------------------------------------

  /// Opens or extends an undo group for a continuous gesture.
  ///
  /// The group closes after [_undoIdleGap] of inactivity, and is force-closed
  /// after [_undoMaxGroup] regardless. Without that ceiling, ordinary typing
  /// rhythm keeps resetting the idle timer and an entire writing session
  /// collapses into a single undo step.
  void requestUndoSnapshot() {
    final now = DateTime.now();
    final bool expired = _undoGroupStarted == null ||
        now.difference(_undoGroupStarted!) >= _undoMaxGroup;

    if (!_undoGroupOpen || expired) {
      recordUndo();
      _undoGroupOpen = true;
      _undoGroupStarted = now;
    }
    _undoDebounceTimer?.cancel();
    _undoDebounceTimer = Timer(_undoIdleGap, () => _undoGroupOpen = false);
  }

  void recordUndo() {
    final state = jsonEncode(toJson());
    if (_undoStack.isNotEmpty && _undoStack.last == state) return;
    _undoStack.add(state);
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  bool get canUndo => _undoStack.isNotEmpty;

  void undo() {
    if (_undoStack.isEmpty) return;
    _undoDebounceTimer?.cancel();
    _undoGroupOpen = false;
    final previousJson = _undoStack.removeLast();
    try {
      final selection = Set<String>.from(_selectedNodeIds);
      final preview = _previewNodeId;
      final transform = canvasController.value.clone();
      final path = _activeFilePath;

      applyProjectJson(previousJson, resetHistory: false);

      // Undo restores the document, not the camera or the cursor.
      canvasController.value = transform;
      _activeFilePath = path;
      _selectedNodeIds = selection.where(_nodes.containsKey).toSet();
      _previewNodeId = _nodes.containsKey(preview) ? preview : null;
      _touch();
      notifyListeners();
    } catch (e) {
      debugPrint("Undo Error: $e");
    }
  }

  void copySelection() {
    if (_selectedNodeIds.isEmpty) return;
    final id = _selectedNodeIds.first;
    if (_nodes.containsKey(id)) {
      _clipboardData = jsonEncode(_nodes[id]!.toJson());
    }
  }

  bool get hasClipboard => _clipboardData != null;

  void paste() {
    if (_clipboardData == null) return;
    try {
      final data = jsonDecode(_clipboardData!) as Map<String, dynamic>;
      recordUndo();
      final newId = const Uuid().v4();
      final source = StoryNode.fromJson(data);
      final newPos = source.position + const Offset(kNodeWidth + 50, 0);

      // A pasted node inherits structure, never terminal ownership: it does not
      // adopt links into Output or Ollama sinks.
      final nextIds = <String>[];
      for (final id in source.nextNodeIds) {
        final target = _nodes[id];
        if (target == null) continue;
        if (target.type == NodeType.output || target.type == NodeType.ollama) {
          continue;
        }
        nextIds.add(id);
      }

      final newNode = StoryNode(
        id: newId,
        type: source.type,
        title: source.title,
        content: source.content,
        textAlign: source.textAlign,
        fontFamily: source.fontFamily,
        position: newPos,
        nextNodeIds: source.type == NodeType.ollama ? <String>[] : nextIds,
        ollamaPrompt: source.ollamaPrompt,
        authorConstraints: source.authorConstraints
            .map((c) => AuthorConstraint(
                  id: const Uuid().v4(),
                  type: c.type,
                  start: c.start,
                  end: c.end,
                ))
            .toList(),
      );
      _nodes[newId] = newNode;
      _selectedNodeIds = {newId};
      _recalculateSequence();
      _markDirty();
      notifyListeners();
    } catch (e) {
      debugPrint("Paste Error: $e");
    }
  }

  // ---------------------------------------------------------------------
  // Graph traversal
  // ---------------------------------------------------------------------

  bool _detectCycle(String sourceId, String targetId) {
    if (sourceId == targetId) return true;
    Set<String> visited = {};
    List<String> stack = [targetId];
    while (stack.isNotEmpty) {
      final curr = stack.removeLast();
      if (curr == sourceId) return true;
      if (!visited.add(curr)) continue;
      if (_nodes.containsKey(curr)) stack.addAll(_nodes[curr]!.nextNodeIds);
    }
    return false;
  }

  /// True when any edge in the graph closes a loop. Used by tests and as a
  /// cheap assertion after file load.
  bool get hasCycle {
    for (final node in _nodes.values) {
      for (final child in node.nextNodeIds) {
        if (child == node.id || _detectCycle(node.id, child)) return true;
      }
    }
    return false;
  }

  /// Parents first, depth first, deterministic.
  ///
  /// The in-progress set is what keeps a malformed or hand-edited graph from
  /// recursing forever: without it, A to B to A is unbounded recursion rather
  /// than a merely wrong ordering.
  List<String> _getTopologicalPath(String targetId) {
    final List<String> result = [];
    final Set<String> visited = {};
    final Set<String> inProgress = {};

    void visit(String nodeId) {
      if (visited.contains(nodeId)) return;
      if (!inProgress.add(nodeId)) return; // cycle: stop descending

      final node = _nodes[nodeId];
      if (node != null) {
        if (node.type == NodeType.merge) {
          final ports = getMergePorts(nodeId);
          for (String parentId in ports) {
            if (parentId.isNotEmpty) visit(parentId);
          }
        } else {
          List<String> parents = [];
          for (var n in _nodes.values) {
            if (n.nextNodeIds.contains(nodeId)) parents.add(n.id);
          }
          parents.sort(
              (a, b) => _nodes[a]!.position.dx.compareTo(_nodes[b]!.position.dx));
          for (String parentId in parents) {
            visit(parentId);
          }
        }
      }
      inProgress.remove(nodeId);
      visited.add(nodeId);
      result.add(nodeId);
    }

    visit(targetId);
    return result;
  }

  void _recalculateSequence() {
    _nodeSequence.clear();
    _activePathIds.clear();
    _invalidateCompiled();

    final targets =
        _nodes.values.where((n) => n.type == NodeType.output).toList()
          ..sort((a, b) => a.position.dx.compareTo(b.position.dx));
    if (targets.isEmpty) return;

    int counter = 1;
    for (var target in targets) {
      final path = _getTopologicalPath(target.id);
      _activePathIds.addAll(path);
      for (var id in path) {
        // Numbering is document-wide. A scene shared by two outputs keeps the
        // number it was first given rather than being renumbered per target.
        if (_nodes[id]?.type == NodeType.scene &&
            !_nodeSequence.containsKey(id)) {
          _nodeSequence[id] = counter++;
        }
      }
    }
  }

  List<StoryNode> getCompiledNodes([String? targetId]) {
    String? curr = targetId ?? _previewNodeId;
    if (curr == null) {
      try {
        curr = _nodes.values.firstWhere((n) => n.type == NodeType.output).id;
      } catch (_) {
        return [];
      }
    }
    if (!_nodes.containsKey(curr)) return [];
    final pathIds = _getTopologicalPath(curr);
    return pathIds
        .map((id) => _nodes[id])
        .whereType<StoryNode>()
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------
  // Node content
  // ---------------------------------------------------------------------

  void updateNodeContent(String id, String content) {
    final node = _nodes[id];
    if (node == null || node.content == content) return;
    requestUndoSnapshot();
    if (node.type == NodeType.scene && node.authorConstraints.isNotEmpty) {
      _droppedConstraints +=
          remapAuthorConstraints(node.authorConstraints, node.content, content);
    }
    node.content = content;
    _touch();
    _invalidateCompiled();
  }

  void addAuthorConstraint(
    String nodeId,
    int start,
    int end,
    AuthorConstraintType type,
  ) {
    final node = _nodes[nodeId];
    if (node == null || node.type != NodeType.scene) return;
    final a = start.clamp(0, node.content.length).toInt();
    final z = end.clamp(0, node.content.length).toInt();
    if (a >= z) return;
    recordUndo();
    // One authorial rule owns a character span at a time. Re-protecting a
    // selection replaces any overlapping rule instead of creating ambiguous
    // nested constraints.
    node.authorConstraints.removeWhere((c) => c.overlaps(a, z));
    node.authorConstraints.add(
      AuthorConstraint(id: const Uuid().v4(), type: type, start: a, end: z),
    );
    node.authorConstraints.sort((x, y) => x.start.compareTo(y.start));
    _markDirty();
    notifyListeners();
  }

  void removeAuthorConstraints(String nodeId, int start, int end) {
    final node = _nodes[nodeId];
    if (node == null || node.type != NodeType.scene) return;
    final a = start.clamp(0, node.content.length).toInt();
    final z = end.clamp(0, node.content.length).toInt();
    if (a >= z) return;
    if (!node.authorConstraints.any((c) => c.overlaps(a, z))) return;
    recordUndo();
    node.authorConstraints.removeWhere((c) => c.overlaps(a, z));
    _markDirty();
    notifyListeners();
  }

  /// Moves locks across an edit, and drops any lock the edit touched.
  ///
  /// Returns the number dropped. An exact lock is a claim about specific
  /// characters. If an edit overwrites part of the protected span, those
  /// characters are gone, and silently re-anchoring the lock onto whatever
  /// replaced them would let text pasted from an Ollama result inherit an
  /// authorship guarantee it never earned.
  @visibleForTesting
  static int remapAuthorConstraints(
    List<AuthorConstraint> constraints,
    String oldText,
    String newText,
  ) {
    int prefix = 0;
    final minLength = math.min(oldText.length, newText.length);
    while (prefix < minLength &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }

    int oldSuffix = oldText.length;
    int newSuffix = newText.length;
    while (oldSuffix > prefix &&
        newSuffix > prefix &&
        oldText.codeUnitAt(oldSuffix - 1) == newText.codeUnitAt(newSuffix - 1)) {
      oldSuffix--;
      newSuffix--;
    }

    final delta = newSuffix - oldSuffix;
    final before = constraints.length;

    constraints.removeWhere((c) => c.start < oldSuffix && c.end > prefix);
    for (final constraint in constraints) {
      if (constraint.start >= oldSuffix) {
        constraint.start += delta;
        constraint.end += delta;
      }
      constraint.start = constraint.start.clamp(0, newText.length).toInt();
      constraint.end = constraint.end.clamp(0, newText.length).toInt();
    }
    constraints.removeWhere((c) => c.start >= c.end);
    constraints.sort((a, b) => a.start.compareTo(b.start));
    return before - constraints.length;
  }

  void setOllamaResult(String id, String content) {
    final node = _nodes[id];
    if (node == null ||
        node.type != NodeType.ollama ||
        node.content == content) {
      return;
    }
    recordUndo();
    node.content = content;
    _markDirty();
    notifyListeners();
  }

  void updateNodeTitle(String id, String title) {
    final node = _nodes[id];
    if (node == null || node.title == title) return;
    requestUndoSnapshot();
    node.title = title;
    _markDirty();
    notifyListeners();
  }

  void updateNodeAlignment(String id, TextAlign align) {
    final node = _nodes[id];
    if (node == null || node.textAlign == align) return;
    requestUndoSnapshot();
    node.textAlign = align;
    _touch();
    notifyListeners();
  }

  void updateNodeFont(String id, String font) {
    final node = _nodes[id];
    if (node == null || node.fontFamily == font) return;
    requestUndoSnapshot();
    node.fontFamily = font;
    _touch();
    notifyListeners();
  }

  void updateOllamaPrompt(String id, String prompt) {
    final node = _nodes[id];
    if (node == null ||
        node.type != NodeType.ollama ||
        node.ollamaPrompt == prompt) {
      return;
    }
    requestUndoSnapshot();
    node.ollamaPrompt = prompt;
    _touch();
  }

  // ---------------------------------------------------------------------
  // Compilation
  // ---------------------------------------------------------------------

  /// Compile the manuscript that reaches [targetId], preserving a map from
  /// Scene-local authorial constraints into compiled-document offsets.
  CompiledManuscript getCompiledManuscript(
    String? targetId, {
    CompileOptions options = const CompileOptions(),
  }) {
    final key = '${targetId ?? _previewNodeId ?? ''}|${options.cacheKey}';
    final cached = _compileCache[key];
    if (cached != null) return cached;

    final nodes = getCompiledNodes(targetId);
    final buffer = StringBuffer();
    final pending = <({
      AuthorConstraint constraint,
      StoryNode node,
      int start,
      int end,
      int lineStart,
      int lineEnd
    })>[];

    for (final node in nodes) {
      if (node.type != NodeType.scene) continue;
      if (options.includeTitles && node.title.trim().isNotEmpty) {
        buffer.writeln(node.title.trim().toUpperCase());
      }
      final contentStart = buffer.length;
      buffer.writeln(node.content);
      for (final constraint in node.authorConstraints) {
        final a = constraint.start.clamp(0, node.content.length).toInt();
        final z = constraint.end.clamp(0, node.content.length).toInt();
        if (a >= z) continue;
        int sceneLineAt(int offset) {
          var line = 1;
          final limit = offset.clamp(0, node.content.length).toInt();
          for (var i = 0; i < limit; i++) {
            if (node.content.codeUnitAt(i) == 10) line++;
          }
          return line;
        }

        pending.add((
          constraint: constraint,
          node: node,
          start: contentStart + a,
          end: contentStart + z,
          lineStart: sceneLineAt(a),
          lineEnd: sceneLineAt(math.max(a, z - 1).toInt()),
        ));
      }
      buffer.writeln(options.includeSeparators ? '\n---\n' : '');
    }

    final text = buffer.toString();

    final constraints = pending.map((item) {
      return CompiledConstraint(
        id: item.constraint.id,
        nodeId: item.node.id,
        nodeTitle: item.node.title,
        type: item.constraint.type,
        start: item.start,
        end: item.end,
        text: text.substring(item.start, item.end),
        lineStart: item.lineStart,
        lineEnd: item.lineEnd,
      );
    }).toList(growable: false);

    final manuscript =
        CompiledManuscript(text: text, constraints: constraints);
    _compileCache[key] = manuscript;
    return manuscript;
  }

  /// The exact manuscript snapshot an Ollama output or spell check sees.
  /// Headings are always present here: the model is reading structure, not
  /// producing a finished document.
  CompiledManuscript getModelInput(String? targetId) =>
      getCompiledManuscript(targetId);

  /// Author-facing compilation, shaped by Settings, Formatting.
  CompiledManuscript getExportManuscript([String? targetId]) =>
      getCompiledManuscript(targetId, options: exportOptions);

  String getCompiledText([String? targetId]) =>
      getExportManuscript(targetId).text;

  void setPreviewNode(String? id) {
    if (_previewNodeId == id) return;
    _previewNodeId = id;
    notifyListeners();
  }

  void jumpToNode(String id) {
    if (!_nodes.containsKey(id)) return;

    _selectedNodeIds = {id};
    _previewNodeId = null;

    final nodePos = _nodes[id]!.position;
    final currentScale = canvasController.value.getMaxScaleOnAxis();

    double viewWidth = 800.0, viewHeight = 600.0;

    final ctx = canvasKey.currentContext;
    if (ctx != null) {
      final renderBox = ctx.findRenderObject();
      if (renderBox is RenderBox && renderBox.hasSize) {
        viewWidth = renderBox.size.width;
        viewHeight = renderBox.size.height;
      }
    }

    final targetX = (viewWidth / 2 / currentScale) - (nodePos.dx + (kNodeWidth / 2));
    final targetY = (viewHeight / 2 / currentScale) -
        (nodePos.dy + (_nodes[id]!.currentHeight / 2));

    canvasController.value = Matrix4.identity()
      ..scale(currentScale)
      ..translate(targetX, targetY);
    notifyListeners();
  }
}