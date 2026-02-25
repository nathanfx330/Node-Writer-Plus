import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';

// ==========================================
// 1. CONFIGURATION & MODELS
// ==========================================

const double kWorldSize = 50000.0;
const double kNodeWidth = 220.0;
const double kNodeHeight = 120.0;
const Color kCanvasBg = Color(0xFF111111);
const Color kNodeBg = Color(0xFF252525);
const Color kAccentColor = Colors.orangeAccent;

enum NodeType { scene, output }

class StoryNode {
  final String id;
  final NodeType type;
  String title;
  String content;
  Offset position;
  List<String> nextNodeIds;
  TextAlign textAlign;
  String fontFamily;

  StoryNode({
    required this.id,
    required this.position,
    this.type = NodeType.scene,
    this.title = "Untitled",
    this.content = "",
    this.textAlign = TextAlign.left,
    this.fontFamily = "Modern",
    List<String>? nextNodeIds,
  }) : nextNodeIds = nextNodeIds ?? [];

  Offset get inputPortLocal => Offset(kNodeWidth / 2, 0);
  Offset get outputPortLocal => const Offset(kNodeWidth / 2, kNodeHeight);
  Offset get inputPortGlobal => position + inputPortLocal;
  Offset get outputPortGlobal => position + outputPortLocal;
  Rect get rect => position & Size(kNodeWidth, type == NodeType.output ? 60 : kNodeHeight);

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.toString(),
        'title': title,
        'content': content,
        'align': textAlign.toString(),
        'font': fontFamily,
        'dx': position.dx,
        'dy': position.dy,
        'next_ids': nextNodeIds,
      };

  factory StoryNode.fromJson(Map<String, dynamic> json) {
    return StoryNode(
      id: json['id'],
      type: json['type'] == 'NodeType.output' ? NodeType.output : NodeType.scene,
      title: json['title'],
      content: json['content'],
      textAlign: _stringToTextAlign(json['align']),
      fontFamily: json['font'] ?? "Modern",
      position: Offset(json['dx'], json['dy']),
      nextNodeIds: List<String>.from(json['next_ids'] ??
          (json['next'] != null ? [json['next']] : [])),
    );
  }

  static TextAlign _stringToTextAlign(String? str) {
    if (str == 'TextAlign.center') return TextAlign.center;
    if (str == 'TextAlign.right') return TextAlign.right;
    if (str == 'TextAlign.justify') return TextAlign.justify;
    return TextAlign.left;
  }
}

// ==========================================
// 2. STATE MANAGEMENT
// ==========================================

class ProjectState extends ChangeNotifier {
  Map<String, StoryNode> _nodes = {};
  String _projectName = "Untitled";
  String? _activeFilePath;
  
  // DYNAMIC TERMINOLOGY (Default: Scene)
  String _unitLabel = "Scene"; 

  final TransformationController canvasController = TransformationController();
  Set<String> _selectedNodeIds = {};
  String? _previewNodeId;

  Rect? _lassoRect;
  Offset? _lassoStart;

  String? _draggingWireSourceId;
  Offset? _draggingWireHead;
  String? _hoveredTargetId;
  String? _hoveredSwapTargetId;
  String? _hoveredWireSourceId;
  int _hoveredWireIndex = -1;

  bool _isInvalidCycle = false;
  String? _clipboardData;

  Map<String, int> _nodeSequence = {};
  Set<String> _activePathIds = {};

  final List<String> _undoStack = [];
  static const int _maxUndo = 50;

  ProjectState() {
    newProject();
  }

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

  String? get hoveredWireSourceId => _hoveredWireSourceId;
  int get hoveredWireIndex => _hoveredWireIndex;

  bool get isInvalidCycle => _isInvalidCycle;
  Set<String> get activePathIds => _activePathIds;

  int getNodeIndex(String id) => _nodeSequence[id] ?? -1;

  // --- SETTINGS ---
  void setUnitLabel(String label) {
    _unitLabel = label;
    notifyListeners();
  }

  // --- PROJECT MANAGEMENT ---

  void newProject() {
    _nodes.clear();
    _undoStack.clear();
    _projectName = "Untitled";
    _activeFilePath = null;
    _selectedNodeIds.clear();
    _clipboardData = null;
    _unitLabel = "Scene"; // Reset to default
    
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
    notifyListeners();
  }

  // --- FILE I/O ---

  Future<void> saveProject() async {
    if (_activeFilePath == null) {
      await saveAsProject();
      return;
    }
    await _writeToDisk(_activeFilePath!);
  }

  Future<void> saveAsProject() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Project As',
      fileName: '$_projectName.nw',
      type: FileType.custom,
      allowedExtensions: ['nw'],
    );

    if (outputFile == null) return;

    if (!outputFile.endsWith('.nw')) {
      outputFile = '$outputFile.nw';
    }

    _activeFilePath = outputFile;
    final name = outputFile.split(Platform.pathSeparator).last;
    _projectName = name.replaceAll('.nw', '');
    
    await _writeToDisk(_activeFilePath!);
    notifyListeners();
  }

  Future<void> _writeToDisk(String path) async {
    final Map<String, dynamic> projectData = {
      'version': 17,
      'name': _projectName,
      'unit_label': _unitLabel, // Save preference
      'nodes': _nodes.values.map((n) => n.toJson()).toList(),
    };

    try {
      final File file = File(path);
      await file.writeAsString(jsonEncode(projectData));
      debugPrint("Saved to $path");
    } catch (e) {
      debugPrint("Error saving project: $e");
    }
  }

  Future<void> loadProject() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['nw'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      try {
        final File file = File(path);
        final String jsonStr = await file.readAsString();
        _loadFromJson(jsonStr);
        _activeFilePath = path;
        notifyListeners();
      } catch (e) {
        debugPrint("Error loading: $e");
      }
    }
  }

  void _loadFromJson(String jsonStr) {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      _nodes.clear();
      _undoStack.clear();
      _projectName = data['name'];
      _unitLabel = data['unit_label'] ?? "Scene"; // Load preference or default
      
      canvasController.value = Matrix4.identity()
        ..translate(-kWorldSize / 2 + 600, -kWorldSize / 2 + 350);

      final List<dynamic> nodeList = data['nodes'];
      for (var n in nodeList) {
        final node = StoryNode.fromJson(n);
        _nodes[node.id] = node;
      }

      _selectedNodeIds.clear();
      _previewNodeId = null;
      _recalculateSequence();
    } catch (e) {
      debugPrint("Parse Error: $e");
    }
  }

  // --- NODE ACTIONS ---

  void addNode(Offset centerPos) {
    recordUndo();
    final id = const Uuid().v4();
    _nodes[id] = StoryNode(
      id: id,
      position: centerPos - const Offset(kNodeWidth / 2, kNodeHeight / 2),
      title: "New $_unitLabel",
    );
    _selectedNodeIds = {id};
    notifyListeners();
  }

  void deleteSelected() {
    if (_selectedNodeIds.isEmpty) return;
    recordUndo();
    final toDelete = _selectedNodeIds
        .where((id) => _nodes[id]?.type != NodeType.output)
        .toList();

    for (var id in toDelete) {
      _nodes.remove(id);
      for (var node in _nodes.values) {
        node.nextNodeIds.remove(id);
      }
    }
    _selectedNodeIds.clear();
    _previewNodeId = null;
    _recalculateSequence();
    notifyListeners();
  }

  void updateNodePosition(String id, Offset delta) {
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
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);

    _hoveredWireSourceId = null;
    _hoveredWireIndex = -1;

    if (isShift && _nodes.containsKey(nodeId)) {
      final nodeCenter = _nodes[nodeId]!.rect.center;
      for (var source in _nodes.values) {
        if (source.id == nodeId) continue;
        for (int i = 0; i < source.nextNodeIds.length; i++) {
          final targetId = source.nextNodeIds[i];
          if (targetId == nodeId) continue;
          if (!_nodes.containsKey(targetId)) continue;

          final target = _nodes[targetId]!;
          final dist = _distanceToLineSegment(
              nodeCenter, source.outputPortGlobal, target.inputPortGlobal);

          if (dist < 50) {
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
      recordUndo();
      final source = _nodes[_hoveredWireSourceId];
      if (source != null && _hoveredWireIndex < source.nextNodeIds.length) {
        final targetId = source.nextNodeIds[_hoveredWireIndex];
        source.nextNodeIds[_hoveredWireIndex] = id;
        if (!_nodes[id]!.nextNodeIds.contains(targetId)) {
          _nodes[id]!.nextNodeIds = [targetId];
        }
      }
      _hoveredWireSourceId = null;
      _hoveredWireIndex = -1;
      _recalculateSequence();
    }
    notifyListeners();
  }

  void selectNode(String id, {bool additive = false}) {
    if (additive) {
      if (_selectedNodeIds.contains(id)) {
        _selectedNodeIds.remove(id);
      } else {
        _selectedNodeIds.add(id);
      }
    } else {
      if (!_selectedNodeIds.contains(id)) {
        _selectedNodeIds = {id};
      }
    }
    notifyListeners();
  }

  void startLasso(Offset screenPos) {
    _lassoStart = _screenToCanvas(screenPos);
    _lassoRect = Rect.fromPoints(_lassoStart!, _lassoStart!);
    _selectedNodeIds.clear();
    notifyListeners();
  }

  void updateLasso(Offset screenPos) {
    if (_lassoStart == null) return;
    final current = _screenToCanvas(screenPos);
    _lassoRect = Rect.fromPoints(_lassoStart!, current);
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

  void startWireDrag(String sourceId) {
    recordUndo();
    _draggingWireSourceId = sourceId;
    _draggingWireHead = _nodes[sourceId]!.outputPortGlobal;
    notifyListeners();
  }

  void updateWireDrag(Offset screenPos) {
    _draggingWireHead = _screenToCanvas(screenPos);
    _hoveredTargetId = null;
    _hoveredSwapTargetId = null;
    _isInvalidCycle = false;

    for (var node in _nodes.values) {
      if (node.id == _draggingWireSourceId) continue;
      if ((_draggingWireHead! - node.inputPortGlobal).distance < 60) {
        _hoveredTargetId = node.id;
        if (_detectCycle(_draggingWireSourceId!, node.id)) _isInvalidCycle = true;
        break;
      }
      if (node.type != NodeType.output &&
          (_draggingWireHead! - node.outputPortGlobal).distance < 60) {
        _hoveredSwapTargetId = node.id;
        break;
      }
    }
    notifyListeners();
  }

  void endWireDrag() {
    if (_draggingWireSourceId != null && !_isInvalidCycle) {
      if (_hoveredTargetId != null) {
        _connectNode(_draggingWireSourceId!, _hoveredTargetId!);
      } else if (_hoveredSwapTargetId != null) {
        final source = _nodes[_draggingWireSourceId]!;
        final target = _nodes[_hoveredSwapTargetId]!;
        source.nextNodeIds = List.from(target.nextNodeIds);
        target.nextNodeIds.clear();
        _recalculateSequence();
      }
    }
    _draggingWireSourceId = null;
    _draggingWireHead = null;
    _hoveredTargetId = null;
    _hoveredSwapTargetId = null;
    _isInvalidCycle = false;
    notifyListeners();
  }

  void _connectNode(String sourceId, String targetId) {
    final source = _nodes[sourceId]!;
    for (var n in _nodes.values) {
      if (n.nextNodeIds.contains(targetId)) {
        n.nextNodeIds.remove(targetId);
      }
    }
    source.nextNodeIds.add(targetId);
    _recalculateSequence();
  }

  void disconnectNode(String id) {
    recordUndo();
    if (_nodes.containsKey(id)) {
      _nodes[id]!.nextNodeIds.clear();
      _recalculateSequence();
      notifyListeners();
    }
  }

  void panCanvas(Offset delta) {
    final matrix = canvasController.value.clone();
    matrix.translate(delta.dx, delta.dy);
    canvasController.value = matrix;
  }

  Offset _screenToCanvas(Offset screenPos) {
    final matrix = canvasController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    return Offset((screenPos.dx - translation.x) / scale,
        (screenPos.dy - translation.y) / scale);
  }

  double _distanceToLineSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a - b).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = math.max(0, math.min(1, t));
    final Offset projection = a + (b - a) * t;
    return (p - projection).distance;
  }

  void recordUndo() {
    final state = jsonEncode({
      'nodes': _nodes.values.map((n) => n.toJson()).toList(),
      'name': _projectName,
      'unit_label': _unitLabel,
    });
    if (_undoStack.isNotEmpty && _undoStack.last == state) return;
    _undoStack.add(state);
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final previousJson = _undoStack.removeLast();
    _loadFromJson(previousJson);
    notifyListeners();
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
      final newNode = StoryNode(
        id: newId,
        type: data['type'] == 'NodeType.output' ? NodeType.output : NodeType.scene,
        title: data['title'],
        content: data['content'],
        textAlign: StoryNode._stringToTextAlign(data['align']),
        fontFamily: data['font'] ?? "Modern",
        position: newPos,
        nextNodeIds: nextIds,
      );
      _nodes[newId] = newNode;
      _selectedNodeIds = {newId};
      _recalculateSequence();
      notifyListeners();
    } catch (e) {
      debugPrint("Paste Error: $e");
    }
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

  void _recalculateSequence() {
    _nodeSequence.clear();
    _activePathIds.clear();
    StoryNode? outputNode;
    try {
      outputNode = _nodes.values.firstWhere((n) => n.type == NodeType.output);
    } catch (_) { return; }

    Map<String, String> parents = {};
    for (var node in _nodes.values) {
      for (var childId in node.nextNodeIds) {
        if (!parents.containsKey(childId) || node.nextNodeIds.indexOf(childId) == 0) {
          parents[childId] = node.id;
        }
      }
    }

    String? curr = outputNode.id;
    List<String> path = [];
    int safe = 0;
    while (curr != null && safe < 1000) {
      path.add(curr);
      _activePathIds.add(curr);
      curr = parents[curr];
      safe++;
    }

    path = path.reversed.toList();
    for (int i = 0; i < path.length; i++) {
      if (_nodes[path[i]]?.type != NodeType.output) {
        _nodeSequence[path[i]] = i + 1;
      }
    }
  }

  void updateNodeContent(String id, String content) {
    if (_nodes.containsKey(id)) _nodes[id]!.content = content;
  }

  void updateNodeTitle(String id, String title) {
    if (_nodes.containsKey(id)) {
      _nodes[id]!.title = title;
      notifyListeners();
    }
  }

  void updateNodeAlignment(String id, TextAlign align) {
    if (_nodes.containsKey(id)) {
      recordUndo();
      _nodes[id]!.textAlign = align;
      notifyListeners();
    }
  }

  void updateNodeFont(String id, String font) {
    if (_nodes.containsKey(id)) {
      recordUndo();
      _nodes[id]!.fontFamily = font;
      notifyListeners();
    }
  }

  void setPreviewNode(String? id) {
    _previewNodeId = id;
    notifyListeners();
  }
}

// ==========================================
// 3. UI
// ==========================================

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProjectState()),
      ],
      child: const NodeWriterApp(),
    ),
  );
}

class NodeWriterApp extends StatelessWidget {
  const NodeWriterApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): () => state.deleteSelected(),
        const SingleActivator(LogicalKeyboardKey.backspace): () => state.deleteSelected(),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () => state.undo(),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () => state.copySelection(),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => state.paste(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => state.saveProject(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): () => state.saveAsProject(),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () => state.loadProject(),
      },
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: "${state.projectName} - Node Writer",
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF111111),
          cardColor: const Color(0xFF222222),
        ),
        home: const MainLayout(),
      ),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  double _sidePanelWidth = 400.0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                const TopBar(),
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      children: [
                        const Positioned.fill(child: GridBackground()),
                        const NodeCanvas(),
                        Positioned(
                            left: 20,
                            top: 20,
                            child: FloatingActionButton.extended(
                              backgroundColor: const Color(0xFF333333),
                              foregroundColor: Colors.white,
                              onPressed: () {
                                final size = MediaQuery.of(context).size;
                                final state = context.read<ProjectState>();
                                final center = state._screenToCanvas(
                                    Offset(size.width / 2, size.height / 2));
                                state.addNode(center);
                              },
                              icon: const Icon(Icons.add),
                              // DYNAMIC LABEL BASED ON SETTINGS
                              label: Text("ADD ${state.unitLabel.toUpperCase()}",
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                            ))
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  _sidePanelWidth -= details.delta.dx;
                  if (_sidePanelWidth < 250) _sidePanelWidth = 250;
                  if (_sidePanelWidth > 800) _sidePanelWidth = 800;
                });
              },
              child: Container(
                width: 5,
                color: const Color(0xFF111111),
                child: Center(
                  child: Container(
                    width: 1, 
                    color: Colors.white.withOpacity(0.1)
                  )
                ),
              ),
            ),
          ),

          SizedBox(
            width: _sidePanelWidth,
            child: const SidePanel(),
          ),
        ],
      ),
    );
  }
}

class TopBar extends StatelessWidget {
  const TopBar({super.key});
  
  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    return Container(
      height: 40,
      color: const Color(0xFF222222),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Text("${state.projectName}${state.activeFilePath == null ? '*' : ''} - Node Writer",
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(width: 20),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "New", onTap: () => state.newProject()),
          _MenuButton(label: "Open", onTap: () => state.loadProject()),
          _MenuButton(label: "Save", onTap: () => state.saveProject()),
          _MenuButton(label: "Save As", onTap: () => state.saveAsProject()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "Undo", onTap: () => state.undo()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "Copy", onTap: () => state.copySelection()),
          _MenuButton(label: "Paste", onTap: () => state.paste()),
          const VerticalDivider(color: Colors.black, width: 20),
          
          // ABOUT BUTTON
          _MenuButton(label: "About", onTap: () => _showAboutDialog(context)),
          
          const Spacer(),
          // SETTINGS BUTTON
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: "Settings",
            onPressed: () => _showSettingsDialog(context, state),
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18),
            onPressed: () => state.deleteSelected(),
            tooltip: "Delete Selected",
          ),
        ],
      ),
    );
  }
// ABOUT DIALOG WITH LOGO
  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        
        // ADDED: A nice balanced padding around the whole box
        contentPadding: const EdgeInsets.only(top: 32, bottom: 24, left: 24, right: 24),
        
        // The title: Text("About") has been completely removed!
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/logo.png', height: 200),
            const SizedBox(height: 5),
            const Text(
              "Node Writer 1.0",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              "by Nathaniel Westveer",
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close", style: TextStyle(color: kAccentColor)),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog(BuildContext context, ProjectState state) {
    showDialog(
      context: context,
      builder: (ctx) {
        // Use local variable to avoid redraw issues inside dialog
        String selected = state.unitLabel;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text("Project Settings"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("What do you call a node?"),
                const SizedBox(height: 10),
                DropdownButton<String>(
                  value: selected,
                  isExpanded: true,
                  items: ["Scene", "Passage", "Paragraph", "Section", "Beat", "Card"]
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => selected = val);
                      state.setUnitLabel(val);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Done")),
            ],
          ),
        );
      },
    );
  }
}

class _MenuButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MenuButton({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(label, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

class NodeCanvas extends StatelessWidget {
  const NodeCanvas({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.read<ProjectState>();
    return Listener(
      onPointerMove: (event) {
        if (event.buttons == kMiddleMouseButton) state.panCanvas(event.delta);
        else if (state.draggingWireSourceId != null) state.updateWireDrag(event.position);
        else if (state.lassoRect != null) state.updateLasso(event.position);
      },
      onPointerUp: (event) {
        if (state.draggingWireSourceId != null) state.endWireDrag();
        if (state.lassoRect != null) state.endLasso();
      },
      child: GestureDetector(
        onPanStart: (details) {
          if (details.kind == PointerDeviceKind.mouse) state.startLasso(details.globalPosition);
        },
        child: InteractiveViewer(
          transformationController: state.canvasController,
          boundaryMargin: const EdgeInsets.all(kWorldSize),
          minScale: 0.1,
          maxScale: 2.0,
          constrained: false,
          panEnabled: false,
          child: SizedBox(
            width: kWorldSize,
            height: kWorldSize,
            child: Stack(
              children: [
                RepaintBoundary(child: ConnectionsLayer()),
                Selector<ProjectState, List<String>>(
                  selector: (_, s) => s.nodes.keys.toList(),
                  builder: (ctx, ids, _) => Stack(
                    children: ids.map((id) => NodePositionWrapper(nodeId: id)).toList(),
                  ),
                ),
                const LassoLayer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConnectionsLayer extends StatelessWidget {
  const ConnectionsLayer({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<ProjectState>(
      builder: (context, state, _) {
        return CustomPaint(
          size: Size.infinite,
          painter: ConnectionPainter(state),
        );
      },
    );
  }
}

class NodePositionWrapper extends StatelessWidget {
  final String nodeId;
  const NodePositionWrapper({super.key, required this.nodeId});
  @override
  Widget build(BuildContext context) {
    return Selector<ProjectState, Offset>(
      selector: (_, state) => state.nodes[nodeId]?.position ?? Offset.zero,
      builder: (context, pos, _) => Positioned(
        left: pos.dx,
        top: pos.dy,
        child: NodeVisual(nodeId: nodeId),
      ),
    );
  }
}

class NodeVisual extends StatefulWidget {
  final String nodeId;
  const NodeVisual({super.key, required this.nodeId});
  @override
  State<NodeVisual> createState() => _NodeVisualState();
}

class _NodeVisualState extends State<NodeVisual> {
  bool _isHoveringOutput = false;

  TextSpan _getPreviewSpan(String content) {
    if (content.isEmpty) return const TextSpan(text: "// Empty", style: TextStyle(color: Colors.grey));
    String displayContent = content.length > 150 ? content.substring(0, 150) : content;
    return TextSpan(text: displayContent, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11, fontFamily: 'monospace', height: 1.2));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<ProjectState>();
    final nodeId = widget.nodeId;
    final node = state.nodes[nodeId]!;
    
    final isSelected = context.select<ProjectState, bool>((s) => s.selectedNodeIds.contains(nodeId));
    final isActive = context.select<ProjectState, bool>((s) => s.activePathIds.contains(nodeId));
    final isPreview = context.select<ProjectState, bool>((s) => s.previewNodeId == nodeId);
    final index = context.select<ProjectState, int>((s) => s.getNodeIndex(nodeId));
    
    final isHoverTarget = context.select<ProjectState, bool>((s) => s.hoveredTargetId == nodeId);
    final isSwapTarget = context.select<ProjectState, bool>((s) => s.hoveredSwapTargetId == nodeId);
    final isCycleHover = context.select<ProjectState, bool>((s) => s.isInvalidCycle) && (isHoverTarget || isSwapTarget);

    final isOutput = node.type == NodeType.output;
    final double height = isOutput ? 60.0 : kNodeHeight;
    final double borderRadius = isOutput ? 30.0 : 12.0;

    Color headerColor = isActive ? const Color(0xFF335533) : const Color(0xFF333333);
    if (isOutput) headerColor = const Color(0xFF555555);
    if (isPreview) headerColor = Colors.amber.shade900;

    Color borderColor = isSelected ? Colors.white : Colors.black;
    if (isHoverTarget) borderColor = Colors.white70;
    if (isSwapTarget) borderColor = Colors.purpleAccent;
    if (isCycleHover) borderColor = Colors.red;
    if (isPreview) borderColor = Colors.amber;

    List<BoxShadow> shadows = [const BoxShadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 5))];
    if (isSelected) shadows = [const BoxShadow(color: Colors.blueAccent, blurRadius: 15, spreadRadius: 1)];
    else if (isPreview) shadows = [const BoxShadow(color: Colors.amber, blurRadius: 15, spreadRadius: 1)];

    return GestureDetector(
      onPanStart: (d) {
        state.recordUndo();
        state.selectNode(nodeId, additive: HardwareKeyboard.instance.isShiftPressed);
      },
      onPanEnd: (_) => state.onNodeDragEnd(nodeId),
      onPanUpdate: (d) => state.updateNodePosition(nodeId, d.delta),
      onTap: () => state.selectNode(nodeId, additive: HardwareKeyboard.instance.isShiftPressed),
      onDoubleTap: () => state.setPreviewNode(isOutput ? null : nodeId),
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition, nodeId),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: isActive || isOutput || isSelected || isPreview ? 1.0 : 0.7,
        child: Container(
          width: kNodeWidth,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF252525),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: borderColor, width: (isSelected || isPreview) ? 2 : 1),
            boxShadow: shadows,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Content
              isOutput 
              ? Center(
                  child: Text("FINAL OUTPUT", 
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.5))
                )
              : Column(
                  children: [
                    Container(
                      height: 32,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: headerColor,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(borderRadius)),
                      ),
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Text(
                          (index > 0 ? "#$index " : "") + node.title.toUpperCase(),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text.rich(_getPreviewSpan(node.content), overflow: TextOverflow.fade),
                        ),
                      ),
                    ),
                  ],
                ),

              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  width: 14, height: 14,
                  transform: Matrix4.translationValues(0, -7, 0),
                  decoration: BoxDecoration(
                    color: (isHoverTarget && !isCycleHover) ? Colors.white : const Color(0xFF111111),
                    shape: BoxShape.circle,
                    border: Border.all(color: isCycleHover ? Colors.red : Colors.grey),
                  ),
                ),
              ),

              if (!isOutput)
                Positioned(
                  bottom: -20, left: 0, right: 0,
                  child: Center(
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _isHoveringOutput = true),
                      onExit: (_) => setState(() => _isHoveringOutput = false),
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onPanStart: (_) => state.startWireDrag(nodeId),
                        child: Container(
                          width: 50, height: 50, color: Colors.transparent,
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: isSwapTarget ? 24 : 16, height: isSwapTarget ? 24 : 16,
                              decoration: BoxDecoration(
                                color: isSwapTarget ? Colors.purpleAccent : (_isHoveringOutput ? Colors.white : const Color(0xFF444444)),
                                shape: BoxShape.circle,
                                border: Border.all(color: isSwapTarget ? Colors.white : (_isHoveringOutput ? Colors.cyanAccent : Colors.white), width: isSwapTarget ? 3 : 1.5),
                                boxShadow: _isHoveringOutput || isSwapTarget ? [BoxShadow(color: isSwapTarget ? Colors.purpleAccent : Colors.white, blurRadius: 10)] : [],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              
              if (!isOutput && node.nextNodeIds.length > 1)
                Positioned(
                  bottom: -35, right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Text("+${node.nextNodeIds.length - 1} alts", style: const TextStyle(fontSize: 9, color: Colors.grey)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset globalPos, String nodeId) {
    final state = context.read<ProjectState>();
    final pos = RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy);
    showMenu(context: context, position: pos, items: [
      PopupMenuItem(child: const Text("Delete"), onTap: () { state.selectNode(nodeId); state.deleteSelected(); }),
      PopupMenuItem(child: const Text("Disconnect All"), onTap: () => state.disconnectNode(nodeId)),
    ]);
  }
}

class ConnectionPainter extends CustomPainter {
  final ProjectState state;
  ConnectionPainter(this.state);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    for (var node in state.nodes.values) {
      for (int i = 0; i < node.nextNodeIds.length; i++) {
        final target = state.nodes[node.nextNodeIds[i]];
        if (target == null) continue;
        bool isActive = state.activePathIds.contains(node.id) && state.activePathIds.contains(target.id);
        bool isHovered = (state.hoveredWireSourceId == node.id && state.hoveredWireIndex == i);
        
        paint.strokeWidth = isHovered ? 4.0 : (isActive ? 2.5 : 1.5);
        paint.color = isHovered ? Colors.cyanAccent : (isActive ? Colors.white : const Color(0xFF555555));
        
        if (isActive || isHovered) _drawCurve(canvas, paint, node.outputPortGlobal, target.inputPortGlobal);
        else _drawDashedCurve(canvas, paint, node.outputPortGlobal, target.inputPortGlobal);
      }
    }
    if (state.draggingWireHead != null && state.draggingWireSourceId != null) {
      final source = state.nodes[state.draggingWireSourceId!]!;
      paint.color = state.isInvalidCycle ? Colors.red : (state.hoveredTargetId != null ? Colors.white : Colors.white54);
      if (state.hoveredSwapTargetId != null) paint.color = Colors.purpleAccent;
      paint.strokeWidth = 3.0;
      Offset end = state.draggingWireHead!;
      if (state.hoveredTargetId != null) end = state.nodes[state.hoveredTargetId!]!.inputPortGlobal;
      else if (state.hoveredSwapTargetId != null) end = state.nodes[state.hoveredSwapTargetId!]!.outputPortGlobal;
      _drawCurve(canvas, paint, source.outputPortGlobal, end);
    }
  }
  void _drawCurve(Canvas canvas, Paint paint, Offset start, Offset end) {
    final path = Path()..moveTo(start.dx, start.dy);
    double dist = (end.dy - start.dy).abs();
    double control = dist < 80 ? 40.0 : dist * 0.5;
    path.cubicTo(start.dx, start.dy + control, end.dx, end.dy - control, end.dx, end.dy);
    canvas.drawPath(path, paint);
  }
  void _drawDashedCurve(Canvas canvas, Paint paint, Offset start, Offset end) {
    final path = Path()..moveTo(start.dx, start.dy);
    double dist = (end.dy - start.dy).abs();
    double control = dist < 80 ? 40.0 : dist * 0.5;
    path.cubicTo(start.dx, start.dy + control, end.dx, end.dy - control, end.dx, end.dy);
    final metric = path.computeMetrics().first;
    final dashedPath = Path();
    for (double d = 0; d < metric.length; d += 20) dashedPath.addPath(metric.extractPath(d, d + 10), Offset.zero);
    canvas.drawPath(dashedPath, paint);
  }
  @override
  bool shouldRepaint(covariant ConnectionPainter old) => true;
}

class SidePanel extends StatefulWidget {
  const SidePanel({super.key});
  @override
  State<SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<SidePanel> {
  late TextEditingController _titleCtrl;
  late TextEditingController _contentCtrl;
  String? _editingId;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _contentCtrl = MarkdownSyntaxController();
  }

  void _toggleFormatting(String char) {
    final text = _contentCtrl.text;
    final selection = _contentCtrl.selection;
    if (selection.start < 0) return;
    final start = selection.start;
    final end = selection.end;
    bool isWrapped = false;
    if (start >= char.length && end <= text.length - char.length) {
      if (text.substring(start - char.length, start) == char && text.substring(end, end + char.length) == char) isWrapped = true;
    }
    String newText;
    if (isWrapped) {
      newText = text.replaceRange(end, end + char.length, "").replaceRange(start - char.length, start, "");
      _contentCtrl.value = TextEditingValue(text: newText, selection: TextSelection(baseOffset: start - char.length, extentOffset: end - char.length));
    } else {
      newText = text.replaceRange(start, end, "$char${text.substring(start, end)}$char");
      _contentCtrl.value = TextEditingValue(text: newText, selection: TextSelection(baseOffset: start + char.length, extentOffset: end + char.length));
    }
    context.read<ProjectState>().updateNodeContent(_editingId!, newText);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final nodeId = state.selectedNodeIds.isNotEmpty ? state.selectedNodeIds.first : null;
    final node = nodeId != null ? state.nodes[nodeId] : null;

    if (state.previewNodeId != null || (node != null && node.type == NodeType.output)) {
      return Container(width: double.infinity, color: const Color(0xFF1A1A1A), child: const PreviewPanel());
    }

    if (node == null) {
      return Container(width: double.infinity, color: const Color(0xFF1A1A1A), child: const Center(child: Text("Select a Node", style: TextStyle(color: Colors.grey))));
    }

    if (_editingId != nodeId) {
      _editingId = nodeId;
      _titleCtrl.text = node.title;
      _contentCtrl.text = node.content;
    }

    return Container(
      width: double.infinity, color: const Color(0xFF1A1A1A), padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("PROPERTIES", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 20),
          TextField(controller: _titleCtrl, decoration: const InputDecoration(labelText: "Scene Title", filled: true, fillColor: Color(0xFF222222)), onChanged: (v) => state.updateNodeTitle(node!.id, v)),
          const SizedBox(height: 10),
          Row(children: [
            DropdownButton<String>(
              value: node.fontFamily, dropdownColor: const Color(0xFF333333), underline: Container(), style: const TextStyle(fontSize: 12, color: Colors.white),
              items: ["Modern", "Classic", "Typewriter"].map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
              onChanged: (v) { if (v != null) state.updateNodeFont(node.id, v); },
            ),
            const SizedBox(width: 10),
            IconButton(icon: const Icon(Icons.format_bold, size: 18), onPressed: () => _toggleFormatting("**")),
            IconButton(icon: const Icon(Icons.format_italic, size: 18), onPressed: () => _toggleFormatting("*")),
            const Spacer(),
            IconButton(icon: Icon(Icons.format_align_left, size: 18, color: node.textAlign == TextAlign.left ? Colors.white : Colors.grey), onPressed: () => state.updateNodeAlignment(node.id, TextAlign.left)),
            IconButton(icon: Icon(Icons.format_align_center, size: 18, color: node.textAlign == TextAlign.center ? Colors.white : Colors.grey), onPressed: () => state.updateNodeAlignment(node.id, TextAlign.center)),
            IconButton(icon: Icon(Icons.format_align_right, size: 18, color: node.textAlign == TextAlign.right ? Colors.white : Colors.grey), onPressed: () => state.updateNodeAlignment(node.id, TextAlign.right)),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: TextField(
              controller: _contentCtrl, maxLines: null, expands: true, textAlign: node.textAlign, textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(filled: true, fillColor: Color(0xFF222222), border: OutlineInputBorder(borderSide: BorderSide.none), hintText: "Write scene..."),
              onChanged: (v) => state.updateNodeContent(node.id, v),
              style: _getFontStyle(node.fontFamily).copyWith(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
  
  TextStyle _getFontStyle(String font) {
    switch (font) {
      case 'Typewriter': return const TextStyle(fontFamily: 'Courier', height: 1.4);
      case 'Classic': return const TextStyle(fontFamily: 'Times New Roman', height: 1.4);
      default: return const TextStyle(fontFamily: 'Roboto', height: 1.4);
    }
  }
}

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key});

  // Helper method to generate clean text for copying/exporting
  String _getCompiledRawText(List<StoryNode> nodes) {
    StringBuffer buffer = StringBuffer();
    for (var node in nodes) {
      if (node.type == NodeType.output) continue;
      buffer.writeln(node.title.toUpperCase());
      buffer.writeln(node.content);
      buffer.writeln("\n---\n"); // Separator between nodes
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final nodes = _getCompiledNodes(state);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(15), 
          color: kAccentColor.withOpacity(0.1), 
          width: double.infinity,
          child: Row(
            children: [
              const Text("STORY PREVIEW", style: TextStyle(color: kAccentColor, fontWeight: FontWeight.bold)),
              const Spacer(),
              
              // 1. COPY TO CLIPBOARD BUTTON
              IconButton(
                icon: const Icon(Icons.copy, size: 20, color: kAccentColor),
                tooltip: "Copy Compiled Text",
                onPressed: () {
                  final text = _getCompiledRawText(nodes);
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Story copied to clipboard!"), duration: Duration(seconds: 2)),
                  );
                },
              ),

              // 2. EXPORT AS .TXT FILE BUTTON
              IconButton(
                icon: const Icon(Icons.download, size: 20, color: kAccentColor),
                tooltip: "Export as .txt",
                onPressed: () async {
                  final text = _getCompiledRawText(nodes);
                  String? outputFile = await FilePicker.platform.saveFile(
                    dialogTitle: 'Export Story',
                    fileName: '${state.projectName}_export.txt',
                    type: FileType.custom,
                    allowedExtensions: ['txt', 'md'],
                  );

                  if (outputFile != null) {
                    if (!outputFile.endsWith('.txt') && !outputFile.endsWith('.md')) {
                      outputFile += '.txt';
                    }
                    await File(outputFile).writeAsString(text);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Exported to $outputFile"), duration: const Duration(seconds: 3)),
                      );
                    }
                  }
                },
              ),

              if (state.previewNodeId != null) 
                IconButton(icon: const Icon(Icons.close), onPressed: () => state.setPreviewNode(null))
            ]
          ),
        ),
        Expanded(
          // 3. SELECTION AREA: This allows you to drag and select text across multiple nodes!
          child: SelectionArea(
            child: ListView.builder(
              padding: const EdgeInsets.all(30), 
              itemCount: nodes.length,
              itemBuilder: (ctx, i) {
                final node = nodes[i];
                if (node.type == NodeType.output) return const SizedBox(height: 50, child: Divider());
                
                final baseStyle = _getFontStyle(node.fontFamily).copyWith(fontSize: 16, height: 1.6, color: Colors.white70);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20.0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(node.title.toUpperCase(), style: const TextStyle(color: Colors.grey, fontSize: 10, letterSpacing: 1.5)),
                    const SizedBox(height: 8),
                    // CHANGED from SelectableText.rich to Text.rich so SelectionArea can handle the selection
                    Text.rich(
                      _parseMarkdown(node.content, baseStyle),
                      textAlign: node.textAlign,
                    ),
                  ]),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
  
  TextSpan _parseMarkdown(String text, TextStyle baseStyle) {
    final children = <TextSpan>[];
    final regex = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    int currentIndex = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > currentIndex) {
        children.add(TextSpan(text: text.substring(currentIndex, match.start), style: baseStyle));
      }
      final fullMatch = match.group(0)!;
      if (fullMatch.startsWith('**')) {
        children.add(TextSpan(text: match.group(2), style: baseStyle.copyWith(fontWeight: FontWeight.bold, color: Colors.white)));
      } else {
        children.add(TextSpan(text: match.group(4), style: baseStyle.copyWith(fontStyle: FontStyle.italic)));
      }
      currentIndex = match.end;
    }
    if (currentIndex < text.length) {
      children.add(TextSpan(text: text.substring(currentIndex), style: baseStyle));
    }
    return TextSpan(children: children);
  }

  TextStyle _getFontStyle(String font) {
    switch (font) {
      case 'Typewriter': return const TextStyle(fontFamily: 'Courier');
      case 'Classic': return const TextStyle(fontFamily: 'Times New Roman');
      default: return const TextStyle(fontFamily: 'Roboto');
    }
  }

  List<StoryNode> _getCompiledNodes(ProjectState state) {
    String? curr = state.previewNodeId;
    if (curr == null) {
      try { curr = state.nodes.values.firstWhere((n) => n.type == NodeType.output).id; } catch (_) { return []; }
    }
    
    Map<String, String> parents = {};
    for (var n in state.nodes.values) {
      for (var childId in n.nextNodeIds) {
        if (!parents.containsKey(childId) || n.nextNodeIds.indexOf(childId) == 0) {
          parents[childId] = n.id;
        }
      }
    }
    List<StoryNode> path = [];
    int safety = 0;
    while (curr != null && safety < 1000) {
      if (state.nodes[curr] != null) path.add(state.nodes[curr]!);
      curr = parents[curr];
      safety++;
    }
    return path.reversed.toList();
  }
}

class LassoLayer extends StatelessWidget {
  const LassoLayer({super.key});
  @override
  Widget build(BuildContext context) {
    final rect = context.select<ProjectState, Rect?>((s) => s.lassoRect);
    if (rect == null) return const SizedBox.shrink();
    return CustomPaint(painter: _LassoPainter(rect));
  }
}
class _LassoPainter extends CustomPainter {
  final Rect rect;
  _LassoPainter(this.rect);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.blue.withOpacity(0.1);
    final border = Paint()..color = Colors.blue.withOpacity(0.5)..style = PaintingStyle.stroke;
    canvas.drawRect(rect, paint);
    canvas.drawRect(rect, border);
  }
  @override
  bool shouldRepaint(covariant _LassoPainter old) => old.rect != rect;
}

class GridBackground extends StatelessWidget {
  const GridBackground({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.read<ProjectState>();
    return ValueListenableBuilder<Matrix4>(
      valueListenable: state.canvasController,
      builder: (context, matrix, _) {
        final translation = matrix.getTranslation();
        final scale = matrix.getMaxScaleOnAxis();
        return CustomPaint(
          painter: _GridPainter(translation.x, translation.y, scale),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  final double dx;
  final double dy;
  final double scale;
  _GridPainter(this.dx, this.dy, this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 1.0;
    const spacing = 150.0; // Larger Grid Spacing
    final gridStep = spacing * scale;
    
    double startX = (dx % gridStep) - gridStep;
    double startY = (dy % gridStep) - gridStep;

    for (double x = startX; x < size.width; x += gridStep) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = startY; y < size.height; y += gridStep) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.dx != dx || old.dy != dy || old.scale != scale;
}

class MarkdownSyntaxController extends TextEditingController {
  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final children = <TextSpan>[];
    final regex = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    final text = this.text;
    int currentIndex = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > currentIndex) {
        children.add(TextSpan(
            text: text.substring(currentIndex, match.start), style: style));
      }
      final fullMatch = match.group(0)!;
      final hiddenStyle =
          style?.copyWith(color: Colors.transparent, fontSize: 0.1);
      if (fullMatch.startsWith('**')) {
        children.add(TextSpan(text: '**', style: hiddenStyle));
        children.add(TextSpan(
            text: match.group(2),
            style: style?.copyWith(
                fontWeight: FontWeight.bold, color: Colors.white)));
        children.add(TextSpan(text: '**', style: hiddenStyle));
      } else {
        children.add(TextSpan(text: '*', style: hiddenStyle));
        children.add(TextSpan(
            text: match.group(4),
            style: style?.copyWith(fontStyle: FontStyle.italic)));
        children.add(TextSpan(text: '*', style: hiddenStyle));
      }
      currentIndex = match.end;
    }
    if (currentIndex < text.length) {
      children.add(TextSpan(text: text.substring(currentIndex), style: style));
    }
    return TextSpan(style: style, children: children);
  }
}
