import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../state/project_state.dart';
import 'dialogs/node_search_dialog.dart';

class NodeCanvas extends StatefulWidget {
  const NodeCanvas({super.key});
  @override
  State<NodeCanvas> createState() => _NodeCanvasState();
}

class _NodeCanvasState extends State<NodeCanvas> {
  bool _isLassoing = false;
  final FocusNode _canvasFocusNode = FocusNode();
  Offset _lastMouseScreenPos = Offset.zero;

  @override
  void dispose() {
    _canvasFocusNode.dispose();
    super.dispose();
  }

  void _showNodeSearchDialog() async {
    final state = context.read<ProjectState>();
    final canvasPos = state.screenToCanvas(_lastMouseScreenPos);

    final NodeType? selectedType = await showDialog<NodeType>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => const NodeSearchDialog(),
    );

    if (selectedType != null) {
      state.addNode(canvasPos, selectedType);
    }
    _canvasFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<ProjectState>();

    // Graph editing keys are bound here, not at application level.
    //
    // Delete, Backspace, Ctrl+C, Ctrl+V and Ctrl+Z are all text editing keys
    // too. Bound globally they sit below Flutter's DefaultTextEditingShortcuts
    // in the tree and intercept the keystroke before the Scene editor ever
    // sees it, so Backspace deletes the node instead of a character. Scoped to
    // the canvas focus subtree they can only fire when the canvas has focus,
    // which is exactly when they mean the graph rather than the manuscript.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.delete): state.deleteSelected,
        const SingleActivator(LogicalKeyboardKey.backspace):
            state.deleteSelected,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            state.undo,
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            state.copySelection,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            state.paste,
      },
      child: Focus(
        focusNode: _canvasFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.tab) {
            _showNodeSearchDialog();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
        key: state.canvasKey,
        behavior: HitTestBehavior.opaque,
        onPointerHover: (event) {
          _lastMouseScreenPos = event.localPosition;
        },
        onPointerDown: (event) {
          _lastMouseScreenPos = event.localPosition;
          if (!_canvasFocusNode.hasFocus) _canvasFocusNode.requestFocus();

          final isRightClick = event.buttons == kSecondaryMouseButton;
          final isMiddleClick = event.buttons == kMiddleMouseButton;
          if (isMiddleClick) return;

          final canvasPos = state.screenToCanvas(event.localPosition);
          bool hitNode = state.nodes.values.any((n) => n.rect.inflate(40).contains(canvasPos));
          
          if (!hitNode) {
            if (isRightClick) {
              final pos = RelativeRect.fromLTRB(event.position.dx, event.position.dy, event.position.dx, event.position.dy);
              showMenu<NodeType>(
                context: context,
                position: pos,
                color: const Color(0xFF222222),
                items: [
                  PopupMenuItem(value: NodeType.scene, child: Text("Add ${state.unitLabel}")),
                  const PopupMenuItem(value: NodeType.merge, child: Text("Add Merge Node")),
                  const PopupMenuItem(value: NodeType.ollama, child: Text("Add Ollama Output")),
                ],
              ).then((type) {
                if (type != null) state.addNode(canvasPos, type);
              });
            } else {
              _isLassoing = true;
              state.clearSelection();
              state.startLasso(event.localPosition);
            }
          }
        },
        onPointerMove: (event) {
          if (event.buttons == kMiddleMouseButton) state.panCanvas(event.delta);
          else if (state.draggingWireSourceId != null) state.updateWireDrag(event.localPosition);
          else if (_isLassoing && state.lassoRect != null) state.updateLasso(event.localPosition);
        },
        onPointerUp: (event) {
          if (state.draggingWireSourceId != null) state.endWireDrag();
          if (_isLassoing) { state.endLasso(); _isLassoing = false; }
        },
        child: InteractiveViewer(
          transformationController: state.canvasController, boundaryMargin: const EdgeInsets.all(kWorldSize), minScale: 0.1, maxScale: 2.0, constrained: false, panEnabled: false,
          child: Container(
            width: kWorldSize, height: kWorldSize, color: Colors.transparent, 
            child: Stack(
              children:[
                const RepaintBoundary(child: ConnectionsLayer()),
                Selector<ProjectState, List<String>>(
                  selector: (_, s) => s.nodes.keys.toList(),
                  builder: (ctx, ids, _) => Stack(children: ids.map((id) => NodePositionWrapper(nodeId: id)).toList()),
                ),
                const LassoLayer(),
              ],
            ),
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
    return Consumer<ProjectState>(builder: (context, state, _) => CustomPaint(size: Size.infinite, painter: ConnectionPainter(state)));
  }
}

class NodePositionWrapper extends StatelessWidget {
  final String nodeId;
  const NodePositionWrapper({super.key, required this.nodeId});
  @override
  Widget build(BuildContext context) {
    return Selector<ProjectState, Offset>(
      selector: (_, state) => state.nodes[nodeId]?.position ?? Offset.zero,
      builder: (context, pos, _) => Positioned(left: pos.dx, top: pos.dy, child: NodeVisual(nodeId: nodeId)),
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
    return TextSpan(text: content.length > 150 ? content.substring(0, 150) : content, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontFamily: 'monospace', height: 1.2));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<ProjectState>();
    final nodeId = widget.nodeId;
    // The parent Stack rebuilds from the node map, but this element can be
    // marked dirty in the same frame its node is deleted.
    final node = state.nodes[nodeId];
    if (node == null) return const SizedBox.shrink();
    
    final isSelected = context.select<ProjectState, bool>((s) => s.selectedNodeIds.contains(nodeId));
    final isActive = context.select<ProjectState, bool>((s) => s.activePathIds.contains(nodeId));
    final isPreview = context.select<ProjectState, bool>((s) => s.previewNodeId == nodeId);
    final index = context.select<ProjectState, int>((s) => s.getNodeIndex(nodeId));
    
    final isHoverTarget = context.select<ProjectState, bool>((s) => s.hoveredTargetId == nodeId);
    final isSwapTarget = context.select<ProjectState, bool>((s) => s.hoveredSwapTargetId == nodeId);
    final isCycleHover = context.select<ProjectState, bool>((s) => s.isInvalidCycle) && (isHoverTarget || isSwapTarget);

    final isOutput = node.type == NodeType.output;
    final isMerge = node.type == NodeType.merge;
    final isOllama = node.type == NodeType.ollama;
    
    final double height = node.currentHeight;
    final double borderRadius = (isOutput || isMerge || isOllama) ? 30.0 : 12.0;

    Color headerColor = isActive ? const Color(0xFF335533) : const Color(0xFF333333);
    if (isOutput) headerColor = const Color(0xFF555555);
    if (isOllama) headerColor = const Color(0xFF4A2A68);
    if (isPreview) headerColor = Colors.amber.shade900;

    Color borderColor = isSelected ? Colors.white : Colors.black;
    if (isHoverTarget) borderColor = Colors.white70;
    if (isSwapTarget) borderColor = Colors.purpleAccent;
    if (isCycleHover) borderColor = Colors.red;
    if (isPreview) borderColor = Colors.amber;

    List<BoxShadow> shadows = [const BoxShadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 5))];
    if (isSelected) shadows = [const BoxShadow(color: Colors.blueAccent, blurRadius: 15, spreadRadius: 1)];
    else if (isPreview) shadows = [const BoxShadow(color: Colors.amber, blurRadius: 15, spreadRadius: 1)];

    List<Widget> inputPorts = [];
    if (node.type == NodeType.merge) {
      final List<String> ports = state.getMergePorts(node.id);
      int portCount = 3;
      double spacing = kNodeWidth / portCount;

      int snapPortIndex = -1;
      if (state.draggingWireSourceId != null) snapPortIndex = ports.indexOf(state.draggingWireSourceId!);

      for (int i = 0; i < portCount; i++) {
        bool isHoveringThisPort = isHoverTarget && !isCycleHover && (i == state.hoveredMergePortIndex || i == snapPortIndex);
        bool isConnected = ports[i].isNotEmpty;
        
        inputPorts.add(
          Positioned(
            top: -7, left: (spacing / 2) + (i * spacing) - 7, 
            child: Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                color: isHoveringThisPort ? Colors.white : (isConnected ? Colors.greenAccent : const Color(0xFF111111)),
                shape: BoxShape.circle,
                border: Border.all(color: isCycleHover ? Colors.red : (isHoveringThisPort ? Colors.white : (isConnected ? Colors.white : Colors.grey)), width: 1.0)
              )
            )
          )
        );
      }
    } else {
      inputPorts.add(
        Positioned(
          top: -7, left: (kNodeWidth / 2) - 7,
          child: Container(
            width: 14, height: 14, 
            decoration: BoxDecoration(
              color: (isHoverTarget && !isCycleHover) ? Colors.white : const Color(0xFF111111), 
              shape: BoxShape.circle, border: Border.all(color: isCycleHover ? Colors.red : Colors.grey, width: 1.0)
            ),
          ),
        )
      );
    }

    return GestureDetector(
      onPanStart: (d) {
        state.requestUndoSnapshot(); 
        state.selectNode(nodeId, additive: HardwareKeyboard.instance.isShiftPressed);
      },
      onPanEnd: (_) => state.onNodeDragEnd(nodeId),
      onPanUpdate: (d) => state.updateNodePosition(nodeId, d.delta),
      onTap: () => state.selectNode(nodeId, additive: HardwareKeyboard.instance.isShiftPressed),
      onDoubleTap: () => state.setPreviewNode((isOutput || isMerge || isOllama) ? null : nodeId),
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition, nodeId),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: isActive || isOutput || isOllama || isMerge || isSelected || isPreview ? 1.0 : 0.7,
        child: Container(
          width: kNodeWidth, height: height,
          decoration: BoxDecoration(color: const Color(0xFF252525), borderRadius: BorderRadius.circular(borderRadius), border: Border.all(color: borderColor, width: (isSelected || isPreview) ? 2 : 1), boxShadow: shadows),
          child: Stack(
            clipBehavior: Clip.none,
            children:[
              isOutput 
              ? const Center(child: Text("FINAL OUTPUT", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.5)))
              : isOllama
                ? const Center(child: Text("OLLAMA OUTPUT", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurpleAccent, letterSpacing: 1.5)))
                : isMerge 
                  ? const Center(child: Text("MERGE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.yellowAccent, letterSpacing: 1.5)))
                  : Column(
                    children:[
                      Container(
                        height: 32, width: double.infinity, alignment: Alignment.center,
                        decoration: BoxDecoration(color: headerColor, borderRadius: BorderRadius.vertical(top: Radius.circular(borderRadius))),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8.0), child: Text((index > 0 ? "#$index " : "") + node.title.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white), overflow: TextOverflow.ellipsis)),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Text.rich(
                              _getPreviewSpan(node.content),
                              overflow: TextOverflow.fade,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

              ...inputPorts,

              if (!isOutput && !isOllama)
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
                
              if (node.type == NodeType.scene && node.nextNodeIds.length > 1)
                Positioned(
                  bottom: -35, right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
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
    showMenu(context: context, position: pos, items:[
      PopupMenuItem(child: const Text("Delete"), onTap: () { state.selectNode(nodeId); state.deleteSelected(); }),
      PopupMenuItem(child: const Text("Disconnect Outputs"), onTap: () => state.disconnectNode(nodeId)),
      PopupMenuItem(child: const Text("Pop Out of Chain"), onTap: () => state.popNodeOut(nodeId)),
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
        
        Offset startPoint = state.getOutputPortGlobal(node.id);
        Offset endPoint = state.getInputPortGlobal(target.id, node.id);

        if (isActive || isHovered) _drawCurve(canvas, paint, startPoint, endPoint);
        else _drawDashedCurve(canvas, paint, startPoint, endPoint);
      }
    }
    
    if (state.draggingWireHead != null && state.draggingWireSourceId != null) {
      final source = state.nodes[state.draggingWireSourceId!];
      if (source == null) return;
      paint.color = state.isInvalidCycle ? Colors.red : (state.hoveredTargetId != null ? Colors.white : Colors.white54);
      if (state.hoveredSwapTargetId != null) paint.color = Colors.purpleAccent;
      paint.strokeWidth = 3.0;
      
      Offset end = state.draggingWireHead!;
      if (state.hoveredTargetId != null) {
        end = state.getInputPortGlobal(state.hoveredTargetId!, null, forcePortIndex: state.hoveredMergePortIndex);
      } else if (state.hoveredSwapTargetId != null) {
        end = state.getOutputPortGlobal(state.hoveredSwapTargetId!);
      }
      
      _drawCurve(canvas, paint, state.getOutputPortGlobal(source.id), end);
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
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final dashedPath = Path();
    for (double d = 0; d < metric.length; d += 20) dashedPath.addPath(metric.extractPath(d, d + 10), Offset.zero);
    canvas.drawPath(dashedPath, paint);
  }
  @override
  bool shouldRepaint(covariant ConnectionPainter old) => true;
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
    final paint = Paint()..color = Colors.blue.withValues(alpha: 0.1);
    final border = Paint()..color = Colors.blue.withValues(alpha: 0.5)..style = PaintingStyle.stroke;
    canvas.drawRect(rect, paint); canvas.drawRect(rect, border);
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
        final scale = matrix.getMaxScaleOnAxis();
        return CustomPaint(painter: _GridPainter(matrix.getTranslation().x, matrix.getTranslation().y, scale));
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  final double dx, dy, scale;
  _GridPainter(this.dx, this.dy, this.scale);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.05)..strokeWidth = 1.0;
    final gridStep = 150.0 * scale;
    double startX = (dx % gridStep) - gridStep;
    double startY = (dy % gridStep) - gridStep;
    for (double x = startX; x < size.width; x += gridStep) canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (double y = startY; y < size.height; y += gridStep) canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
  @override
  bool shouldRepaint(covariant _GridPainter old) => old.dx != dx || old.dy != dy || old.scale != scale;
}