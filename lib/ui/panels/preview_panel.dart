import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants.dart';
import '../../models/story_node.dart';
import '../../state/project_state.dart';
import '../dialogs/ollama_proofread_dialog.dart';

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({
    super.key,
    this.targetId,
    this.title = 'STORY PREVIEW',
    this.showProofread = true,
  });

  final String? targetId;
  final String title;
  final bool showProofread;

  bool _isContentNode(StoryNode node) => node.type == NodeType.scene;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final nodes = state.getCompiledNodes(targetId);
    // Two shapes of the same compilation. The model always sees headings so it
    // can orient itself; the author sees whatever Settings, Formatting says.
    final manuscript = state.getModelInput(targetId);
    final compiledText = state.getExportManuscript(targetId).text;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(15),
          color: kAccentColor.withValues(alpha: 0.1),
          width: double.infinity,
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(color: kAccentColor, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (showProofread)
                IconButton(
                  icon: const Icon(Icons.spellcheck, size: 20, color: Colors.deepPurpleAccent),
                  tooltip: 'Spell check compiled output with Ollama',
                  onPressed: compiledText.trim().isEmpty
                      ? null
                      : () => showDialog<void>(
                            context: context,
                            builder: (_) => OllamaProofreadDialog(manuscript: manuscript),
                          ),
                ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20, color: kAccentColor),
                tooltip: 'Copy compiled text',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: compiledText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Story copied to clipboard!'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.download, size: 20, color: kAccentColor),
                tooltip: 'Export compiled text',
                onPressed: () async {
                  String? outputFile = await FilePicker.platform.saveFile(
                    dialogTitle: 'Export Story',
                    fileName: '${state.projectName}_export.txt',
                    type: FileType.custom,
                    allowedExtensions: ['txt', 'md'],
                  );
                  if (outputFile == null) return;
                  final String path =
                      (outputFile.endsWith('.txt') || outputFile.endsWith('.md'))
                          ? outputFile
                          : '$outputFile.txt';
                  String message;
                  try {
                    await File(path).writeAsString(compiledText, flush: true);
                    message = 'Exported to $path';
                  } catch (e) {
                    message = 'Export failed: $e';
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(message),
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                },
              ),
              if (state.previewNodeId != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => state.setPreviewNode(null),
                ),
            ],
          ),
        ),
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              padding: const EdgeInsets.all(30),
              itemCount: nodes.length,
              itemBuilder: (ctx, i) {
                final node = nodes[i];
                if (node.type == NodeType.output || node.type == NodeType.ollama) {
                  return const SizedBox(
                    height: 50,
                    child: Divider(color: Colors.white24),
                  );
                }
                if (node.type == NodeType.merge) return const SizedBox.shrink();
                if (!_isContentNode(node)) return const SizedBox.shrink();

                final baseStyle = _getFontStyle(node.fontFamily).copyWith(
                  fontSize: 16,
                  height: 1.6,
                  color: Colors.white70,
                );
                final nodeIndex = state.getNodeIndex(node.id);
                final indexPrefix = nodeIndex > 0 ? '#$nodeIndex ' : '';
                const headingColor = kAccentColor;

                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => state.jumpToNode(node.id),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (indexPrefix + node.title).toUpperCase(),
                            style: TextStyle(
                              color: headingColor,
                              fontSize: 10,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text.rich(
                            _parseMarkdown(node.content, baseStyle),
                            textAlign: node.textAlign,
                          ),
                        ],
                      ),
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
      if (match.start > currentIndex) {
        children.add(TextSpan(text: text.substring(currentIndex, match.start), style: baseStyle));
      }
      final fullMatch = match.group(0)!;
      if (fullMatch.startsWith('**')) {
        children.add(
          TextSpan(
            text: match.group(2),
            style: baseStyle.copyWith(fontWeight: FontWeight.bold, color: Colors.white),
          ),
        );
      } else {
        children.add(
          TextSpan(
            text: match.group(4),
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ),
        );
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
      case 'Typewriter':
        return const TextStyle(fontFamily: 'Courier');
      case 'Classic':
        return const TextStyle(fontFamily: 'Times New Roman');
      default:
        return const TextStyle(fontFamily: 'Roboto');
    }
  }
}
