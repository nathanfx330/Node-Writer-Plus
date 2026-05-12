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

class ProjectState extends ChangeNotifier {
  final Map<String, StoryNode> _nodes = {};
  String _projectName = "Untitled";
  String? _activeFilePath;
  String _unitLabel = "Scene"; 

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
  Map<String, int> _nodeSequence = {};
  Set<String> _activePathIds = {};

  final List<String> _undoStack = [];
  static const int _maxUndo = 20; 
  Timer? _undoDebounceTimer;

  ProjectState() { newProject(); }

  Map<String, StoryNode> get nodes => _nodes;
  String get projectName => _projectName;
  String? get activeFilePath => _activeFilePath;
  String get unitLabel => _unitLabel;
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

  void setUnitLabel(String label) {
    _unitLabel = label;
    notifyListeners();
  }

  void newProject() {
    _nodes.clear();
    _undoStack.clear();
    _mergePorts.clear();
    _projectName = "Untitled";
    _activeFilePath = null;
    _selectedNodeIds.clear();
    _clipboardData = null;
    
    canvasController.value = Matrix4.identity()..translate(-kWorldSize / 2 + 600, -kWorldSize / 2 + 350);

    final sceneId = const Uuid().v4();
    final outputId = const Uuid().v4();

    _nodes[sceneId] = StoryNode(id: sceneId, position: const Offset(kWorldSize / 2, kWorldSize / 2), title: "$_unitLabel 1", content: "The story starts here...", nextNodeIds: [outputId]);
    _nodes[outputId] = StoryNode(id: outputId, type: NodeType.output, position: const Offset(kWorldSize / 2, kWorldSize / 2 + 250), title: "FINAL OUTPUT");

    _selectedNodeIds = {sceneId};
    _recalculateSequence();
    notifyListeners();
  }

  Future<void> saveProject() async {
    if (_activeFilePath == null) { await saveAsProject(); return; }
    await _writeToDisk(_activeFilePath!);
  }

  Future<void> saveAsProject() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Project As', fileName: '$_projectName.nw', type: FileType.custom, allowedExtensions: ['nw'],
    );
    if (outputFile == null) return;
    if (!outputFile.endsWith('.nw')) outputFile = '$outputFile.nw';
    _activeFilePath = outputFile;
    _projectName = outputFile.split(Platform.pathSeparator).last.replaceAll('.nw', '');
    await _writeToDisk(_activeFilePath!);
    notifyListeners();
  }

  Future<void> _writeToDisk(String path) async {
    final Map<String, dynamic> projectData = {
      'version': 19, 'name': _projectName, 'unit_label': _unitLabel,
      'nodes': _nodes.values.map((n) => n.toJson()).toList(),
    };
    try {
      await File(path).writeAsString(jsonEncode(projectData));
      debugPrint("Saved to $path");
    } catch (e) { debugPrint("Error saving project: $e"); }
  }

  Future<void> loadProject() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['nw']);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      try {
        final String jsonStr = await File(path).readAsString();
        _loadFromJson(jsonStr);
        _activeFilePath = path;
        notifyListeners();
      } catch (e) { debugPrint("Error loading: $e"); }
    }
  }

  void _loadFromJson(String jsonStr) {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      _nodes.clear(); 
      _undoStack.clear();
      _mergePorts.clear();
      _projectName = data['name'];
      _unitLabel = data['unit_label'] ?? "Scene";
      canvasController.value = Matrix4.identity()..translate(-kWorldSize / 2 + 600, -kWorldSize / 2 + 350);

      for (var n in data['nodes']) {
        final node = StoryNode.fromJson(n);
        _nodes[node.id] = node;
      }
      _selectedNodeIds.clear(); _previewNodeId = null;
      _recalculateSequence();
    } catch (e) { debugPrint("Parse Error: $e"); }
  }

  void addNode(Offset centerPos, [NodeType type = NodeType.scene]) {
    recordUndo();
    final id = const Uuid().v4();
    String title = type == NodeType.scene ? "New $_unitLabel" : "MERGE";
    if (type == NodeType.output) title = "FINAL OUTPUT";

    _nodes[id] = StoryNode(id: id, type: type, position: centerPos - const Offset(kNodeWidth / 2, kNodeHeight / 2), title: title);
    _selectedNodeIds = {id};
    notifyListeners();
  }

  void deleteSelected() {
    if (_selectedNodeIds.isEmpty) return;
    recordUndo();
    final toDelete = _selectedNodeIds.where((id) => _nodes[id]?.type != NodeType.output).toList();
    for (var id in toDelete) {
      _nodes.remove(id);
      for (var node in _nodes.values) node.nextNodeIds.remove(id);
    }
    _selectedNodeIds.clear(); _previewNodeId = null;
    _recalculateSequence();
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
    notifyListeners();
  }

  void _checkWireHover(String nodeId) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
    _hoveredWireSourceId = null; _hoveredWireIndex = -1;

    if (isShift && _nodes.containsKey(nodeId)) {
      final nodeCenter = _nodes[nodeId]!.position + Offset(kNodeWidth / 2, _nodes[nodeId]!.currentHeight / 2);
      for (var source in _nodes.values) {
        if (source.id == nodeId) continue;
        for (int i = 0; i < source.nextNodeIds.length; i++) {
          final targetId = source.nextNodeIds[i];
          if (targetId == nodeId || !_nodes.containsKey(targetId)) continue;
          
          if (_distanceToLineSegment(nodeCenter, getOutputPortGlobal(source.id), getInputPortGlobal(targetId, source.id)) < 50) {
            _hoveredWireSourceId = source.id; _hoveredWireIndex = i; return;
          }
        }
      }
    }
  }

  void onNodeDragEnd(String id) {
    if (_hoveredWireSourceId != null && _hoveredWireIndex != -1) {
      recordUndo();
      final source = _nodes[_hoveredWireSourceId];
      if (source != null && _hoveredWireIndex < source.nextNodeIds.length) {
        final targetId = source.nextNodeIds[_hoveredWireIndex];
        source.nextNodeIds[_hoveredWireIndex] = id;
        if (!_nodes[id]!.nextNodeIds.contains(targetId)) _nodes[id]!.nextNodeIds = [targetId];
      }
      _hoveredWireSourceId = null; _hoveredWireIndex = -1;
      _recalculateSequence();
    }
    notifyListeners();
  }

  void selectNode(String id, {bool additive = false}) {
    if (additive) {
      if (_selectedNodeIds.contains(id)) _selectedNodeIds.remove(id);
      else _selectedNodeIds.add(id);
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
    _selectedNodeIds = _nodes.values.where((n) => _lassoRect!.overlaps(n.rect)).map((n) => n.id).toSet();
    notifyListeners();
  }

  void endLasso() {
    _lassoRect = null; _lassoStart = null;
    notifyListeners();
  }

  // --- PORT ROUTING ---
  
  List<String> getMergePorts(String targetId) {
    if (!_mergePorts.containsKey(targetId)) {
        List<String> incoming = [];
        for (var node in _nodes.values) {
            if (node.nextNodeIds.contains(targetId)) incoming.add(node.id);
        }
        incoming.sort((a, b) => _nodes[a]!.position.dx.compareTo(_nodes[b]!.position.dx));
        _mergePorts[targetId] = [
            incoming.isNotEmpty ? incoming[0] : "",
            incoming.length > 1 ? incoming[1] : "",
            incoming.length > 2 ? incoming[2] : ""
        ];
    }
    
    List<String> ports = _mergePorts[targetId]!;
    for(int i=0; i<3; i++) {
        if (ports[i].isNotEmpty) {
            if (_nodes[ports[i]] == null || !_nodes[ports[i]]!.nextNodeIds.contains(targetId)) {
                ports[i] = "";
            }
        }
    }
    return ports;
  }

  Offset getInputPortGlobal(String targetId, String? sourceId, {int? forcePortIndex}) {
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
    recordUndo();
    _draggingWireSourceId = sourceId;
    _draggingWireHead = getOutputPortGlobal(sourceId);
    notifyListeners();
  }

  void updateWireDrag(Offset screenPos) {
    _draggingWireHead = screenToCanvas(screenPos);
    _hoveredTargetId = null; _hoveredSwapTargetId = null; _hoveredMergePortIndex = null; _isInvalidCycle = false;

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
                  _causesCrossContamination(_draggingWireSourceId!, node.id, _hoveredMergePortIndex)) {
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
      if (node.type != NodeType.output && (_draggingWireHead! - outPort).distance < 60) { 
        _hoveredSwapTargetId = node.id; 
        if (_causesCrossContamination(_draggingWireSourceId!, node.id, null)) {
            _isInvalidCycle = true;
        }
        break; 
      }
    }
    notifyListeners();
  }

  void endWireDrag() {
    if (_draggingWireSourceId != null && !_isInvalidCycle) {
      if (_hoveredTargetId != null) {
        _connectNode(_draggingWireSourceId!, _hoveredTargetId!, portIndex: _hoveredMergePortIndex);
      } else if (_hoveredSwapTargetId != null) {
        final source = _nodes[_draggingWireSourceId]!;
        final target = _nodes[_hoveredSwapTargetId]!;
        source.nextNodeIds = List.from(target.nextNodeIds);
        target.nextNodeIds.clear();
        _recalculateSequence();
      }
    }
    _draggingWireSourceId = null; _draggingWireHead = null;
    _hoveredTargetId = null; _hoveredSwapTargetId = null; _hoveredMergePortIndex = null; _isInvalidCycle = false;
    notifyListeners();
  }

  void _connectNode(String sourceId, String targetId, {int? portIndex}) {
    final source = _nodes[sourceId]!;
    final target = _nodes[targetId];
    if (target == null) return;
    
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
    if (!source.nextNodeIds.contains(targetId)) source.nextNodeIds.add(targetId); 
    _recalculateSequence();
  }

  bool _causesCrossContamination(String sourceId, String targetId, int? targetPortIndex) {
    Map<String, Set<String>> destinations = {};
    for (var node in _nodes.values) destinations[node.id] = {};

    Map<String, List<String>> incoming = {};
    for (var n in _nodes.values) {
      for (var child in n.nextNodeIds) incoming.putIfAbsent(child, () => []).add(n.id);
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
            destinations[curr]!.add("${mergeNode.id}_$p");
            if (incoming.containsKey(curr)) queue.addAll(incoming[curr]!);
          }
        }
      }
    }
    
    Set<String> sourceDests = Set.from(destinations[sourceId] ?? {});
    Set<String> targetDests = {};
    
    if (_nodes[targetId]?.type == NodeType.merge) {
      if (targetPortIndex != null) targetDests.add("${targetId}_$targetPortIndex");
    } else {
      targetDests = Set.from(destinations[targetId] ?? {});
    }

    Set<String> combined = {}..addAll(sourceDests)..addAll(targetDests);
    Map<String, Set<String>> mergeToPorts = {};
    
    for (var dest in combined) {
      var parts = dest.split('_');
      String mId = parts[0];
      String pIdx = parts[1];
      
      mergeToPorts.putIfAbsent(mId, () => {}).add(pIdx);
      if (mergeToPorts[mId]!.length > 1) return true; 
    }
    return false;
  }

  void disconnectNode(String id) {
    recordUndo();
    if (_nodes.containsKey(id)) {
      _nodes[id]!.nextNodeIds.clear();
      _recalculateSequence();
      notifyListeners();
    }
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
          if (!node.nextNodeIds.contains(childId)) node.nextNodeIds.add(childId);
        }
      }
    }
    nodeToPop.nextNodeIds.clear();
    _recalculateSequence();
    notifyListeners();
  }

  void panCanvas(Offset delta) {
    canvasController.value = canvasController.value.clone()..translate(delta.dx, delta.dy);
  }

  Offset screenToCanvas(Offset screenPos) {
    final matrix = canvasController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    return Offset((screenPos.dx - translation.x) / scale, (screenPos.dy - translation.y) / scale);
  }

  double _distanceToLineSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a - b).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = math.max(0, math.min(1, t));
    return (p - (a + (b - a) * t)).distance;
  }

  void requestUndoSnapshot() {
    if (_undoDebounceTimer == null || !_undoDebounceTimer!.isActive) recordUndo();
    _undoDebounceTimer?.cancel();
    _undoDebounceTimer = Timer(const Duration(seconds: 1), () {});
  }

  void recordUndo() {
    final state = jsonEncode({
      'nodes': _nodes.values.map((n) => n.toJson()).toList(),
      'name': _projectName, 'unit_label': _unitLabel,
    });
    if (_undoStack.isNotEmpty && _undoStack.last == state) return;
    _undoStack.add(state);
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final previousJson = _undoStack.removeLast();
    try {
      final Map<String, dynamic> data = jsonDecode(previousJson);
      _nodes.clear(); _mergePorts.clear();
      _projectName = data['name']; _unitLabel = data['unit_label'] ?? "Scene";
      for (var n in data['nodes']) {
        final node = StoryNode.fromJson(n);
        _nodes[node.id] = node;
      }
      _selectedNodeIds.removeWhere((id) => !_nodes.containsKey(id));
      if (_previewNodeId != null && !_nodes.containsKey(_previewNodeId)) _previewNodeId = null;
      _recalculateSequence();
      notifyListeners();
    } catch (e) { debugPrint("Undo Error: $e"); }
  }

  void copySelection() {
    if (_selectedNodeIds.isEmpty) return;
    final id = _selectedNodeIds.first;
    if (_nodes.containsKey(id)) _clipboardData = jsonEncode(_nodes[id]!.toJson());
  }

  void paste() {
    if (_clipboardData == null) return;
    recordUndo();
    try {
      final data = jsonDecode(_clipboardData!);
      final newId = const Uuid().v4();
      final newPos = Offset(data['dx'] + kNodeWidth + 50, data['dy']);
      List<String> nextIds = [];
      if (data['next_ids'] != null) {
        for (var id in List<String>.from(data['next_ids'])) {
          if (_nodes[id]?.type != NodeType.output) nextIds.add(id);
        }
      }
      
      NodeType parsedType = NodeType.scene;
      if (data['type'] == 'NodeType.output') parsedType = NodeType.output;
      if (data['type'] == 'NodeType.merge') parsedType = NodeType.merge;

      final newNode = StoryNode(
        id: newId, type: parsedType,
        title: data['title'], content: data['content'],
        textAlign: StoryNode.stringToTextAlign(data['align']),
        fontFamily: data['font'] ?? "Modern", position: newPos, nextNodeIds: nextIds,
      );
      _nodes[newId] = newNode;
      _selectedNodeIds = {newId};
      _recalculateSequence();
      notifyListeners();
    } catch (e) { debugPrint("Paste Error: $e"); }
  }

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

  List<String> _getTopologicalPath(String targetId) {
    List<String> result = [];
    Set<String> visited = {};

    void visit(String nodeId) {
      if (visited.contains(nodeId)) return;
      
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
          parents.sort((a, b) => _nodes[a]!.position.dx.compareTo(_nodes[b]!.position.dx));
          for (String parentId in parents) visit(parentId);
        }
      }
      visited.add(nodeId); result.add(nodeId);
    }
    
    visit(targetId);
    return result;
  }

  void _recalculateSequence() {
    _nodeSequence.clear(); _activePathIds.clear();
    List<StoryNode> targetNodes = _nodes.values.where((n) => n.type == NodeType.output).toList();
    if (targetNodes.isEmpty) return;

    for (var target in targetNodes) {
      List<String> path = _getTopologicalPath(target.id);
      _activePathIds.addAll(path);

      int counter = 1;
      for (var id in path) {
        if (_nodes[id]?.type == NodeType.scene) {
          _nodeSequence[id] = counter++;
        }
      }
    }
  }

  List<StoryNode> getCompiledNodes([String? targetId]) {
    String? curr = targetId ?? _previewNodeId;
    if (curr == null) {
      try { curr = _nodes.values.firstWhere((n) => n.type == NodeType.output).id; } catch (_) { return []; }
    }
    final pathIds = _getTopologicalPath(curr);
    return pathIds.map((id) => _nodes[id]!).toList();
  }

  void updateNodeContent(String id, String content) {
    if (_nodes.containsKey(id) && _nodes[id]!.content != content) { requestUndoSnapshot(); _nodes[id]!.content = content; }
  }

  void updateNodeTitle(String id, String title) {
    if (_nodes.containsKey(id) && _nodes[id]!.title != title) { requestUndoSnapshot(); _nodes[id]!.title = title; notifyListeners(); }
  }

  void updateNodeAlignment(String id, TextAlign align) {
    if (_nodes.containsKey(id)) { requestUndoSnapshot(); _nodes[id]!.textAlign = align; notifyListeners(); }
  }

  void updateNodeFont(String id, String font) {
    if (_nodes.containsKey(id)) { requestUndoSnapshot(); _nodes[id]!.fontFamily = font; notifyListeners(); }
  }

  void setPreviewNode(String? id) {
    _previewNodeId = id; notifyListeners();
  }

  void jumpToNode(String id) {
    if (!_nodes.containsKey(id)) return;
    
    _selectedNodeIds = {id}; _previewNodeId = null;
    
    final nodePos = _nodes[id]!.position;
    final currentScale = canvasController.value.getMaxScaleOnAxis();
    
    double viewWidth = 800.0, viewHeight = 600.0;
    
    if (canvasKey.currentContext != null) {
      final renderBox = canvasKey.currentContext!.findRenderObject() as RenderBox;
      viewWidth = renderBox.size.width; viewHeight = renderBox.size.height;
    }
    
    final targetX = (viewWidth / 2 / currentScale) - (nodePos.dx + (kNodeWidth / 2));
    final targetY = (viewHeight / 2 / currentScale) - (nodePos.dy + (_nodes[id]!.currentHeight / 2));
    
    canvasController.value = Matrix4.identity()..scale(currentScale)..translate(targetX, targetY);
    notifyListeners();
  }
}