import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../state/project_state.dart';
import '../utils/markdown_controller.dart';
import 'panels/preview_panel.dart';

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
    
    if (node.type == NodeType.merge) {
      return Container(
        width: double.infinity, color: const Color(0xFF1A1A1A), padding: const EdgeInsets.all(20),
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("MERGE NODE", style: TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          SizedBox(height: 20),
          Text("Combines multiple parallel branches into a single linear flow.", style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
          SizedBox(height: 10),
          Text("This allows you to work on different sections of your writing in separate columns, and safely merge them together before compilation. The left-most port is compiled first, then the center, then the right.", style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.4))
        ])
      );
    }
    
    if (_editingId != nodeId) {
      _editingId = nodeId;
      _titleCtrl.text = node.title; _contentCtrl.text = node.content;
    }

    return Container(
      width: double.infinity, color: const Color(0xFF1A1A1A), padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children:[
          const Text("PROPERTIES", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 20),
          TextField(controller: _titleCtrl, decoration: InputDecoration(labelText: "${state.unitLabel} Title", filled: true, fillColor: const Color(0xFF222222)), onChanged: (v) => state.updateNodeTitle(node.id, v)),
          const SizedBox(height: 10),
          Row(children:[
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
              decoration: InputDecoration(filled: true, fillColor: const Color(0xFF222222), border: const OutlineInputBorder(borderSide: BorderSide.none), hintText: "Write ${state.unitLabel.toLowerCase()}..."),
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