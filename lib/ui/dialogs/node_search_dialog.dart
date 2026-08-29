import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants.dart';
import '../../state/project_state.dart';

/// One entry in the Tab palette.
class _NodeOption {
  const _NodeOption(this.type, this.name);
  final NodeType type;
  final String name;
}

class NodeSearchDialog extends StatefulWidget {
  const NodeSearchDialog({super.key});
  @override
  State<NodeSearchDialog> createState() => _NodeSearchDialogState();
}

class _NodeSearchDialogState extends State<NodeSearchDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();

  List<_NodeOption> _all = const <_NodeOption>[];
  List<_NodeOption> _filtered = const <_NodeOption>[];
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
    _all = <_NodeOption>[
      _NodeOption(NodeType.scene, 'Add $unitLabel'),
      const _NodeOption(NodeType.merge, 'Add Merge Node'),
      const _NodeOption(NodeType.ollama, 'Add Ollama Output'),
    ];
    _filter(_ctrl.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _filter(String query) {
    final q = query.trim().toLowerCase();
    final next = q.isEmpty
        ? _all
        : _all
            .where((option) => option.name.toLowerCase().contains(q))
            .toList(growable: false);
    setState(() {
      _filtered = next;
      _selectedIndex = 0;
    });
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  void _accept(int index) {
    if (index < 0 || index >= _filtered.length) return;
    Navigator.pop(context, _filtered[index].type);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_filtered.isEmpty) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedIndex =
          (_selectedIndex + 1).clamp(0, _filtered.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedIndex =
          (_selectedIndex - 1).clamp(0, _filtered.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _accept(_selectedIndex);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      alignment: Alignment.center,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: kNodeBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 20,
              offset: const Offset(0, 10),
            )
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Focus(
                onKeyEvent: _handleKeyEvent,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focusNode,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  onChanged: _filter,
                  decoration: const InputDecoration(
                    hintText: 'Search nodes...',
                    hintStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                    icon: Icon(Icons.search, color: Colors.white54),
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              child: _filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No nodes found.',
                          style: TextStyle(color: Colors.white54)),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemExtent: 50,
                      itemBuilder: (ctx, i) {
                        final option = _filtered[i];
                        final isSelected = i == _selectedIndex;
                        return MouseRegion(
                          onEnter: (_) => setState(() => _selectedIndex = i),
                          child: GestureDetector(
                            onTap: () => _accept(i),
                            child: Container(
                              color: isSelected
                                  ? kAccentColor.withValues(alpha: 0.8)
                                  : Colors.transparent,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.centerLeft,
                              child: Text(
                                option.name,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white70,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
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
