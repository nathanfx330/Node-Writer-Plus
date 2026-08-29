import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants.dart';
import '../../models/story_node.dart';
import '../../services/ollama_service.dart';
import '../../services/authorial_harness.dart';
import '../../state/project_state.dart';

class OllamaNodePanel extends StatefulWidget {
  const OllamaNodePanel({super.key, required this.nodeId});

  final String nodeId;

  @override
  State<OllamaNodePanel> createState() => _OllamaNodePanelState();
}

class _OllamaNodePanelState extends State<OllamaNodePanel> {
  static const _hostKey = 'ollama_host';
  static const _defaultModelKey = 'ollama_default_model';
  static const _systemPromptKey = 'ollama_system_prompt';
  static const _defaultHost = 'http://localhost:11434';
  static const _defaultSystemPrompt =
      'You are a careful writing assistant. Preserve the author’s voice unless explicitly asked to change it.';

  final TextEditingController _promptCtrl = TextEditingController();

  bool _generating = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadPromptFromNode();
  }

  @override
  void didUpdateWidget(covariant OllamaNodePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeId != widget.nodeId) {
      _status = null;
      _loadPromptFromNode();
    }
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  /// Pulls the node's saved ask into the field on mount and on node change.
  /// Deliberately not done from build: mutating a controller mid-build is the
  /// kind of thing that works until the day it does not.
  void _loadPromptFromNode() {
    final node = context.read<ProjectState>().nodes[widget.nodeId];
    _promptCtrl.text = node?.ollamaPrompt ?? '';
  }

  Future<void> _run(ProjectState state, StoryNode node) async {
    if (_generating) return;

    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_hostKey) ?? _defaultHost;
    final model = prefs.getString(_defaultModelKey)?.trim() ?? '';
    final system = prefs.getString(_systemPromptKey) ?? _defaultSystemPrompt;

    if (model.isEmpty) {
      setState(() => _status = 'Choose a model in Settings → Ollama first.');
      return;
    }

    final instruction = _promptCtrl.text.trim();
    if (instruction.isEmpty) {
      setState(() => _status = 'Enter an ask for this Ollama output.');
      return;
    }

    // Ollama is an output node: its input is the exact manuscript compilation
    // that reaches this point in the graph, plus Scene-level authorial locks.
    final manuscript = state.getModelInput(node.id);
    final compiledInput = manuscript.text.trim();
    if (compiledInput.isEmpty) {
      setState(() => _status = 'Connect writing upstream of this Ollama output first.');
      return;
    }
    final harness = AuthorialHarness.prepare(manuscript);

    final prompt = StringBuffer()
      ..writeln(instruction)
      ..writeln()
      ..writeln('COMPILED MANUSCRIPT INPUT:')
      ..write(harness.text);

    setState(() {
      _generating = true;
      _status = 'Generating with $model…';
    });

    try {
      final result = await OllamaService(baseUrl: host).generate(
        model: model,
        prompt: prompt.toString(),
        system: '$system\n\n${harness.systemRules}',
      );
      if (!mounted) return;
      final tokenIssues = harness.validateExactTokens(result);
      final restored = harness.restoreExactTokens(result);
      state.setOllamaResult(node.id, restored);
      final exactCount = harness.exactTokens.length;
      final meaningCount = harness.meaningConstraints.length;
      setState(() {
        if (tokenIssues.isNotEmpty) {
          _status = 'Done with protection warning: ${tokenIssues.join(' ')}';
        } else if (exactCount + meaningCount > 0) {
          _status = 'Done — authorial harness applied: '
              '$exactCount exact, $meaningCount meaning lock${meaningCount == 1 ? '' : 's'}.';
        } else {
          _status = 'Done — ${restored.length} characters returned.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final node = state.nodes[widget.nodeId];
    if (node == null || node.type != NodeType.ollama) {
      return const Center(child: Text('Ollama output unavailable'));
    }
    final manuscript = state.getModelInput(node.id);
    final compiledInput = manuscript.text.trim();
    final exactLocks = manuscript.exactConstraints.length;
    final meaningLocks = manuscript.meaningConstraints.length;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 17, color: Colors.deepPurpleAccent),
              const SizedBox(width: 8),
              const Text(
                'OLLAMA OUTPUT',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.deepPurpleAccent,
                  letterSpacing: 1.3,
                ),
              ),
              const Spacer(),
              if (_generating)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Model and connection settings live in Settings → Ollama.',
                  style: TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ),
              Text(
                compiledInput.isEmpty ? 'NO INPUT' : '${compiledInput.length} INPUT CHARS',
                style: const TextStyle(color: Colors.white30, fontSize: 9),
              ),
            ],
          ),
          if (exactLocks + meaningLocks > 0) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF20272A),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 15, color: Color(0xFF80CBC4)),
                  const SizedBox(width: 7),
                  Text(
                    '$exactLocks exact  •  $meaningLocks meaning',
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                  const Spacer(),
                  const Text(
                    'AUTHORIAL HARNESS',
                    style: TextStyle(color: Colors.white30, fontSize: 8, letterSpacing: 0.8),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          const Text(
            'ASK',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _promptCtrl,
            minLines: 4,
            maxLines: 7,
            textAlignVertical: TextAlignVertical.top,
            decoration: _decoration(
              compiledInput.isEmpty
                  ? 'Connect scenes upstream, then tell Ollama what to do with that compilation.'
                  : 'Tell Ollama what to do with the compiled manuscript at this point.',
            ),
            onChanged: (value) => state.updateOllamaPrompt(node.id, value),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generating || compiledInput.isEmpty
                  ? null
                  : () => _run(state, node),
              icon: const Icon(Icons.play_arrow),
              label: Text(_generating ? 'GENERATING…' : 'RUN ASK'),
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(
              _status!,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              const Text(
                'RESULT',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Copy Ollama result',
                visualDensity: VisualDensity.compact,
                onPressed: node.content.trim().isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: node.content));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Ollama result copied.'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                icon: const Icon(Icons.copy, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF222222),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Colors.white10),
              ),
              child: SelectionArea(
                child: SingleChildScrollView(
                  child: Text(
                    node.content.trim().isEmpty
                        ? 'Run the ask to see Ollama’s response here.'
                        : node.content,
                    style: TextStyle(
                      color: node.content.trim().isEmpty ? Colors.white30 : Colors.white70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF222222),
        border: const OutlineInputBorder(borderSide: BorderSide.none),
      );
}
