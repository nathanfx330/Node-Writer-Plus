import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/compiled_manuscript.dart';
import '../../services/authorial_harness.dart';
import '../../services/ollama_service.dart';

class OllamaProofreadDialog extends StatefulWidget {
  const OllamaProofreadDialog({
    super.key,
    required this.manuscript,
  });

  final CompiledManuscript manuscript;

  @override
  State<OllamaProofreadDialog> createState() => _OllamaProofreadDialogState();
}

class _OllamaProofreadDialogState extends State<OllamaProofreadDialog> {
  static const _hostKey = 'ollama_host';
  static const _defaultModelKey = 'ollama_default_model';
  static const _defaultHost = 'http://localhost:11434';

  final TextEditingController _resultCtrl = TextEditingController();
  String _model = '';
  String? _status;
  bool _running = false;
  bool _hardRejected = false;
  List<MeaningCheck> _meaningChecks = const <MeaningCheck>[];

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  @override
  void dispose() {
    _resultCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadModel() async {
    final prefs = await SharedPreferences.getInstance();
    final model = prefs.getString(_defaultModelKey) ?? '';
    if (!mounted) return;
    setState(() => _model = model);
  }

  Future<void> _proofread() async {
    if (_running) return;
    if (widget.manuscript.text.trim().isEmpty) {
      setState(() => _status = 'There is no compiled text to spell check.');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_hostKey) ?? _defaultHost;
    final model = prefs.getString(_defaultModelKey)?.trim() ?? '';
    if (model.isEmpty) {
      setState(() => _status = 'Choose a model in Settings → Ollama first.');
      return;
    }

    final harness = AuthorialHarness.prepare(widget.manuscript);
    final service = OllamaService(baseUrl: host);

    setState(() {
      _model = model;
      _running = true;
      _hardRejected = false;
      _meaningChecks = const <MeaningCheck>[];
      _status = 'Proofreading with $model…';
    });

    try {
      final correctedWithTokens = await service.generate(
        model: model,
        system:
            'You are a meticulous copy editor. Correct only spelling, grammar, punctuation, capitalization, and obvious typographical errors. Preserve the author’s wording, voice, meaning, paragraph breaks, headings, and Markdown. Do not summarize, rewrite for style, add facts, or add commentary. Return only the corrected text.\n\n${harness.systemRules}',
        prompt:
            'Proofread the following compiled document. Return the complete corrected document and nothing else. Because this is a complete-document edit, every exact-lock token in the source must appear exactly once in your returned document.\n\n${harness.text}',
      );
      if (!mounted) return;

      final exactIssues = harness.validateExactTokens(
        correctedWithTokens,
        requireEveryToken: true,
      );
      if (exactIssues.isNotEmpty) {
        setState(() {
          _hardRejected = true;
          _resultCtrl.clear();
          _status = 'REJECTED: Ollama violated an exact author lock. ${exactIssues.join(' ')}';
        });
        return;
      }

      final restored = harness.restoreExactTokens(correctedWithTokens);
      _resultCtrl.text = restored;

      if (harness.meaningConstraints.isNotEmpty) {
        setState(() => _status =
            'Exact locks preserved. Checking ${harness.meaningConstraints.length} meaning lock${harness.meaningConstraints.length == 1 ? '' : 's'}…');
        final checks = await AuthorialHarness.verifyMeaningLocks(
          service: service,
          model: model,
          constraints: harness.meaningConstraints,
          generatedDocument: restored,
        );
        if (!mounted) return;
        _meaningChecks = checks;
      }

      final preserved = _meaningChecks.where((c) => c.status == 'PRESERVED').length;
      final changed = _meaningChecks.where((c) => c.status == 'CHANGED').length;
      final uncertain = _meaningChecks.where((c) => c.status == 'UNCERTAIN').length;
      final exactCount = harness.exactTokens.length;
      setState(() {
        if (_meaningChecks.isEmpty) {
          _status = exactCount == 0
              ? 'Spell check complete. Review the result before using it.'
              : 'Spell check complete. ✓ $exactCount exact author lock${exactCount == 1 ? '' : 's'} preserved.';
        } else {
          _status = 'Spell check complete. ✓ $exactCount exact. '
              'Meaning check: $preserved preserved, $changed changed, $uncertain uncertain.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final exactCount = widget.manuscript.exactConstraints.length;
    final meaningCount = widget.manuscript.meaningConstraints.length;

    return Dialog(
      child: SizedBox(
        width: 800,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.spellcheck, color: Colors.deepPurpleAccent),
                  const SizedBox(width: 8),
                  const Text(
                    'OLLAMA SPELL CHECK',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _running ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                _model.isEmpty
                    ? 'Uses the model configured in Settings → Ollama.'
                    : 'Using $_model from Settings → Ollama.',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
              if (exactCount + meaningCount > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 14, color: Color(0xFF80CBC4)),
                    const SizedBox(width: 6),
                    Text(
                      '$exactCount exact lock${exactCount == 1 ? '' : 's'}  •  '
                      '$meaningCount meaning lock${meaningCount == 1 ? '' : 's'}',
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _running ? null : _proofread,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.spellcheck),
                  label: Text(_running ? 'CHECKING…' : 'SPELL CHECK COMPILED OUTPUT'),
                ),
              ),
              if (_status != null) ...[
                const SizedBox(height: 8),
                Text(
                  _status!,
                  style: TextStyle(
                    color: _hardRejected ? Colors.redAccent : Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
              if (_meaningChecks.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 110),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF202020),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _meaningChecks.length,
                    itemBuilder: (context, index) {
                      final check = _meaningChecks[index];
                      final color = check.status == 'PRESERVED'
                          ? Colors.greenAccent
                          : check.status == 'CHANGED'
                              ? Colors.redAccent
                              : Colors.amberAccent;
                      final matches = widget.manuscript.meaningConstraints
                          .where((c) => c.id == check.id)
                          .toList(growable: false);
                      final location = matches.isEmpty
                          ? ''
                          : '${matches.first.nodeTitle}, lines '
                              '${matches.first.lineStart == matches.first.lineEnd ? matches.first.lineStart : '${matches.first.lineStart}-${matches.first.lineEnd}'} — ';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${check.status}: $location${check.reason}',
                          style: TextStyle(color: color, fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'CORRECTED REVIEW',
                style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: TextField(
                  controller: _resultCtrl,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: _hardRejected
                        ? 'The generated correction was rejected because it violated an exact author lock.'
                        : 'The corrected document appears here. Your source nodes are not changed.',
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFF222222),
                    border: const OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                  style: const TextStyle(fontSize: 13, height: 1.45),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text(
                    'Source nodes remain untouched.',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _resultCtrl.text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: _resultCtrl.text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Corrected text copied.')),
                            );
                          },
                    icon: const Icon(Icons.copy),
                    label: const Text('COPY CORRECTED'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
