// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'constants.dart';
import 'state/project_state.dart';
import 'ui/top_bar.dart';
import 'ui/side_panel.dart';
import 'ui/canvas_view.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => ProjectState())],
      child: const NodeWriterApp(),
    ),
  );
}

class NodeWriterApp extends StatelessWidget {
  const NodeWriterApp({super.key});

  @override
  Widget build(BuildContext context) {
    final title = context.select<ProjectState, String>(TopBar.projectTitle);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: title,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kCanvasBg,
        cardColor: kNodeBg,
      ),
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});
  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  /// Enough canvas to keep a node and its ports visible at the far left.
  static const double _minCanvasWidth = 200.0;
  static const double _minPanelWidth = 280.0;
  static const double _defaultPanelWidth = 400.0;

  /// Double-click target. The Scene editor is the word processor, so the wide
  /// preset is a writing width, not a split view.
  static const double _widePanelFraction = 0.75;

  double _sidePanelWidth = _defaultPanelWidth;

  /// Live width for the duration of a divider drag.
  ///
  /// Pointer move events arrive at the mouse polling rate, which is several
  /// times the frame rate, so multiple onPanUpdate calls routinely land between
  /// two builds. Deriving the new width from the width captured by the last
  /// build meant every event in a frame started from the same stale value and
  /// overwrote the previous one, so all but the last delta of each frame was
  /// discarded and the divider tracked at a fraction of the cursor speed.
  /// Accumulating here instead keeps every delta.
  double? _dragWidth;

  double _maxPanelWidth(double available) =>
      (available - _minCanvasWidth).clamp(_minPanelWidth, double.infinity);

  /// Dragging across a wide screen is a lot of mouse travel, so the divider
  /// also toggles between the wide writing width and the default.
  void _toggleWide(double available) {
    final double maxPanel = _maxPanelWidth(available);
    final double wide = (available * _widePanelFraction)
        .clamp(_minPanelWidth, maxPanel)
        .toDouble();
    setState(() {
      _sidePanelWidth =
          _sidePanelWidth < wide - 1 ? wide : _defaultPanelWidth;
      _dragWidth = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<ProjectState>();

    // Only file commands are bound application wide, and every one of them is
    // a chord Flutter's text editing shortcuts do not claim. Anything that is
    // also a text editing key (Delete, Backspace, Ctrl+C/V/Z) belongs to the
    // canvas focus subtree instead, in canvas_view.dart, so it cannot reach
    // past the Scene editor. Binding those here put them below
    // DefaultTextEditingShortcuts and Backspace deleted the selected node
    // instead of a character.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            TopBar.saveProject(context),
        const SingleActivator(LogicalKeyboardKey.keyS,
            control: true, shift: true): () => TopBar.saveProjectAs(context),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
            TopBar.openProject(context),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            TopBar.newProject(context),
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final double maxPanel = _maxPanelWidth(constraints.maxWidth);
            final double panelWidth =
                _sidePanelWidth.clamp(_minPanelWidth, maxPanel).toDouble();
            return Row(
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
                                child: PopupMenuButton<NodeType>(
                                  offset: const Offset(0, 60),
                                  color: const Color(0xFF222222),
                                  tooltip: 'Add node',
                                  onSelected: (type) {
                                    final size = MediaQuery.of(context).size;
                                    state.addNode(
                                      state.screenToCanvas(Offset(
                                          size.width / 2, size.height / 2)),
                                      type,
                                    );
                                  },
                                  itemBuilder: (ctx) => [
                                    PopupMenuItem(
                                      value: NodeType.scene,
                                      child: Text("Add ${state.unitLabel}"),
                                    ),
                                    const PopupMenuItem(
                                      value: NodeType.merge,
                                      child: Text("Add Merge Node"),
                                    ),
                                    const PopupMenuItem(
                                      value: NodeType.ollama,
                                      child: Text("Add Ollama Output"),
                                    ),
                                  ],
                                  child: const FloatingActionButton.extended(
                                    backgroundColor: Color(0xFF333333),
                                    foregroundColor: Colors.white,
                                    onPressed: null,
                                    icon: Icon(Icons.add),
                                    label: Text(
                                      "ADD NODE",
                                      style:
                                          TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                              ),
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
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: () => _toggleWide(constraints.maxWidth),
                    onPanStart: (_) => _dragWidth = panelWidth,
                    onPanUpdate: (details) {
                      // Start from the running drag value, not from the width
                      // this build closed over, so events that share a frame
                      // accumulate instead of overwriting each other.
                      final double next = ((_dragWidth ?? panelWidth) -
                              details.delta.dx)
                          .clamp(_minPanelWidth, maxPanel)
                          .toDouble();
                      _dragWidth = next;
                      if (next != _sidePanelWidth) {
                        setState(() => _sidePanelWidth = next);
                      }
                    },
                    onPanEnd: (_) => _dragWidth = null,
                    onPanCancel: () => _dragWidth = null,
                    child: Tooltip(
                      message: 'Drag to resize, double-click for wide',
                      waitDuration: const Duration(milliseconds: 700),
                      child: Container(
                        // Wider than it looks: 5px was a hard target to grab.
                        width: 9,
                        color: kCanvasBg,
                        child: Center(
                          child: Container(
                            width: 1,
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: panelWidth, child: const SidePanel()),
              ],
            );
          },
        ),
      ),
    );
  }
}