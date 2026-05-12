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
          scaffoldBackgroundColor: kCanvasBg, 
          cardColor: kNodeBg
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
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Column(
              children:[
                const TopBar(),
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      children:[
                        const Positioned.fill(child: GridBackground()),
                        const NodeCanvas(),
                        Positioned(
                          left: 20, top: 20,
                          child: PopupMenuButton<NodeType>(
                            offset: const Offset(0, 60),
                            color: const Color(0xFF222222),
                            onSelected: (type) {
                              final size = MediaQuery.of(context).size;
                              final state = context.read<ProjectState>();
                              state.addNode(state.screenToCanvas(Offset(size.width / 2, size.height / 2)), type);
                            },
                            itemBuilder: (ctx) {
                                final state = context.read<ProjectState>();
                                return [
                                  PopupMenuItem(value: NodeType.scene, child: Text("Add ${state.unitLabel}")),
                                  const PopupMenuItem(value: NodeType.merge, child: const Text("Add Merge Node")),
                                ];
                            },
                            child: const FloatingActionButton.extended(
                              backgroundColor: Color(0xFF333333), foregroundColor: Colors.white,
                              onPressed: null,
                              icon: Icon(Icons.add),
                              label: Text("ADD NODE", style: TextStyle(fontWeight: FontWeight.bold)),
                            )
                          )
                        )
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
              child: Container(width: 5, color: kCanvasBg, child: Center(child: Container(width: 1, color: Colors.white.withOpacity(0.1)))),
            ),
          ),
          SizedBox(width: _sidePanelWidth, child: const SidePanel()),
        ],
      ),
    );
  }
}