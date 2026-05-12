import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';

import '../../constants.dart';
import '../../state/project_state.dart';

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final nodes = state.getCompiledNodes();

    return Column(
      children:[
        Container(
          padding: const EdgeInsets.all(15), color: kAccentColor.withOpacity(0.1), width: double.infinity,
          child: Row(
            children:[
              const Text("STORY PREVIEW", style: TextStyle(color: kAccentColor, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 20, color: kAccentColor), tooltip: "Copy Compiled Text",
                onPressed: () {
                  StringBuffer buffer = StringBuffer();
                  for (var node in nodes) {
                    if (node.type != NodeType.scene) continue;
                    buffer.writeln(node.title.toUpperCase()); buffer.writeln(node.content); buffer.writeln("\n---\n"); 
                  }
                  Clipboard.setData(ClipboardData(text: buffer.toString()));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Story copied to clipboard!"), duration: Duration(seconds: 2)));
                },
              ),
              IconButton(
                icon: const Icon(Icons.download, size: 20, color: kAccentColor), tooltip: "Export as .txt",
                onPressed: () async {
                  String? outputFile = await FilePicker.platform.saveFile(dialogTitle: 'Export Story', fileName: '${state.projectName}_export.txt', type: FileType.custom, allowedExtensions: ['txt', 'md']);
                  if (outputFile != null) {
                    if (!outputFile.endsWith('.txt') && !outputFile.endsWith('.md')) outputFile += '.txt';
                    StringBuffer buffer = StringBuffer();
                    for (var node in nodes) {
                      if (node.type != NodeType.scene) continue;
                      buffer.writeln(node.title.toUpperCase()); buffer.writeln(node.content); buffer.writeln("\n---\n"); 
                    }
                    await File(outputFile).writeAsString(buffer.toString());
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exported to $outputFile"), duration: const Duration(seconds: 3)));
                  }
                },
              ),
              if (state.previewNodeId != null) IconButton(icon: const Icon(Icons.close), onPressed: () => state.setPreviewNode(null))
            ]
          ),
        ),
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              padding: const EdgeInsets.all(30), itemCount: nodes.length,
              itemBuilder: (ctx, i) {
                final node = nodes[i];
                if (node.type == NodeType.output) return const SizedBox(height: 50, child: Divider(color: Colors.white24));
                if (node.type == NodeType.merge) return const SizedBox.shrink();
                
                final baseStyle = _getFontStyle(node.fontFamily).copyWith(fontSize: 16, height: 1.6, color: Colors.white70);
                final nodeIndex = state.getNodeIndex(node.id);
                final indexPrefix = nodeIndex > 0 ? "#$nodeIndex " : "";

                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => state.jumpToNode(node.id),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 20.0),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
                        Text((indexPrefix + node.title).toUpperCase(), style: const TextStyle(color: kAccentColor, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text.rich(_parseMarkdown(node.content, baseStyle), textAlign: node.textAlign),
                      ]),
                    ),
                  ),
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
      if (match.start > currentIndex) children.add(TextSpan(text: text.substring(currentIndex, match.start), style: baseStyle));
      final fullMatch = match.group(0)!;
      if (fullMatch.startsWith('**')) children.add(TextSpan(text: match.group(2), style: baseStyle.copyWith(fontWeight: FontWeight.bold, color: Colors.white)));
      else children.add(TextSpan(text: match.group(4), style: baseStyle.copyWith(fontStyle: FontStyle.italic)));
      currentIndex = match.end;
    }
    if (currentIndex < text.length) children.add(TextSpan(text: text.substring(currentIndex), style: baseStyle));
    return TextSpan(children: children);
  }

  TextStyle _getFontStyle(String font) {
    switch (font) {
      case 'Typewriter': return const TextStyle(fontFamily: 'Courier');
      case 'Classic': return const TextStyle(fontFamily: 'Times New Roman');
      default: return const TextStyle(fontFamily: 'Roboto');
    }
  }
}