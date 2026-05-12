import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants.dart';
import '../../state/project_state.dart';

class NodeSearchDialog extends StatefulWidget {
  const NodeSearchDialog({super.key});
  @override
  State<NodeSearchDialog> createState() => _NodeSearchDialogState();
}

class _NodeSearchDialogState extends State<NodeSearchDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();
  
  late List<Map<String, dynamic>> kAllNodes;
  List<Map<String, dynamic>> _filtered = [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final unitLabel = context.read<ProjectState>().unitLabel;
    kAllNodes = [
      {'type': NodeType.scene, 'name': "Add $unitLabel"},
      {'type': NodeType.merge, 'name': "Add Merge Node"},
    ];
    if (_filtered.isEmpty && _ctrl.text.isEmpty) {
      _filtered = kAllNodes;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose(); _scrollCtrl.dispose(); _focusNode.dispose();
    super.dispose();
  }

  void _filter(String q) {
    setState(() {
      if (q.isEmpty) _filtered = kAllNodes;
      else _filtered = kAllNodes.where((n) => (n['name'] as String).toLowerCase().contains(q.toLowerCase())).toList();
      _selectedIndex = 0;
    });
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() { _selectedIndex = (_selectedIndex + 1).clamp(0, _filtered.length - 1); });
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() { _selectedIndex = (_selectedIndex - 1).clamp(0, _filtered.length - 1); });
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (_filtered.isNotEmpty) Navigator.pop(context, _filtered[_selectedIndex]['type']);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent, elevation: 0, alignment: Alignment.center,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: kNodeBg, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24, width: 1),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Focus(
                onKeyEvent: _handleKeyEvent,
                child: TextField(
                  controller: _ctrl, focusNode: _focusNode,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: "Search nodes...", hintStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none, icon: Icon(Icons.search, color: Colors.white54),
                  ),
                  onChanged: _filter,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              child: _filtered.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16.0), child: Text("No nodes found.", style: TextStyle(color: Colors.white54)))
                  : ListView.builder(
                      controller: _scrollCtrl, shrinkWrap: true,
                      itemCount: _filtered.length, itemExtent: 50.0, 
                      itemBuilder: (ctx, i) {
                        final nodeDef = _filtered[i];
                        final isSelected = i == _selectedIndex;
                        return MouseRegion(
                          onEnter: (_) => setState(() => _selectedIndex = i),
                          child: GestureDetector(
                            onTap: () => Navigator.pop(context, nodeDef['type']),
                            child: Container(
                              color: isSelected ? kAccentColor.withOpacity(0.8) : Colors.transparent,
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              alignment: Alignment.centerLeft,
                              child: Text(nodeDef['name'], style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}