import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/ollama_service.dart';
import '../../state/project_state.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.projectState});

  final ProjectState projectState;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  static const _hostKey = 'ollama_host';
  static const _defaultModelKey = 'ollama_default_model';
  static const _systemPromptKey = 'ollama_system_prompt';
  static const _defaultHost = 'http://localhost:11434';
  static const _defaultSystemPrompt =
      'You are a careful writing assistant. Preserve the author’s voice unless explicitly asked to change it.';

  late final TabController _tabController;
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _systemCtrl = TextEditingController();

  SharedPreferences? _prefs;
  OllamaService _ollama = OllamaService();
  List<String> _models = <String>[];
  String? _selectedModel;
  String? _status;
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hostCtrl.dispose();
    _systemCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_hostKey) ?? _defaultHost;
    _prefs = prefs;
    _hostCtrl.text = host;
    _systemCtrl.text = prefs.getString(_systemPromptKey) ?? _defaultSystemPrompt;
    _selectedModel = prefs.getString(_defaultModelKey);
    _ollama = OllamaService(baseUrl: host);
    if (!mounted) return;
    setState(() => _loading = false);
    await _refreshModels(quiet: true);
  }

  Future<void> _persist() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final host = _hostCtrl.text.trim().isEmpty ? _defaultHost : _hostCtrl.text.trim();
    _hostCtrl.text = host;
    await prefs.setString(_hostKey, host);
    await prefs.setString(_systemPromptKey, _systemCtrl.text.trim().isEmpty
        ? _defaultSystemPrompt
        : _systemCtrl.text.trim());
    final model = _selectedModel?.trim() ?? '';
    if (model.isNotEmpty) await prefs.setString(_defaultModelKey, model);
    _ollama = OllamaService(baseUrl: host);
  }

  Future<void> _refreshModels({bool quiet = false}) async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      if (!quiet) _status = 'Connecting to Ollama…';
    });
    try {
      await _persist();
      final models = await _ollama.listModels();
      var selected = _selectedModel;
      if ((selected == null || selected.isEmpty) && models.isNotEmpty) {
        selected = models.first;
      }
      if (!mounted) return;
      setState(() {
        _models = models;
        _selectedModel = selected;
        _status = models.isEmpty
            ? 'Ollama is reachable, but no local models were reported.'
            : '${models.length} local model${models.length == 1 ? '' : 's'} available.';
      });
      if (selected != null && selected.isNotEmpty) {
        await _prefs?.setString(_defaultModelKey, selected);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      title: const Text('Settings'),
      content: SizedBox(
        width: 560,
        height: 390,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'FORMATTING'),
                Tab(text: 'OLLAMA'),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _formattingTab(),
                  _ollamaTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await _persist();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _formattingTab() {
    final labels = [
      'Scene',
      'Passage',
      'Paragraph',
      'Section',
      'Beat',
      'Card',
      'Header'
    ];
    final state = widget.projectState;

    return ListView(
      children: [
        const Text(
          'Writing units',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose what Node Writer calls ordinary writing nodes.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          value: state.unitLabel,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Node name',
            filled: true,
            border: OutlineInputBorder(),
          ),
          items: labels
              .map((label) => DropdownMenuItem(value: label, child: Text(label)))
              .toList(),
          onChanged: (value) {
            if (value != null) state.setUnitLabel(value);
            setState(() {});
          },
        ),
        const SizedBox(height: 22),
        const Text(
          'Compiled output',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
        ),
        const SizedBox(height: 8),
        const Text(
          'Shape of copied and exported text. Ollama always receives headings '
          'so it can see the structure, whatever is chosen here.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Include node titles as headings',
              style: TextStyle(fontSize: 13)),
          value: state.exportTitles,
          onChanged: (value) {
            state.setExportShape(includeTitles: value);
            setState(() {});
          },
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Separate nodes with a horizontal rule',
              style: TextStyle(fontSize: 13)),
          value: state.exportSeparators,
          onChanged: (value) {
            state.setExportShape(includeSeparators: value);
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _ollamaTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final modelItems = <String>{..._models};
    if (_selectedModel != null && _selectedModel!.isNotEmpty) {
      modelItems.add(_selectedModel!);
    }
    final sortedModels = modelItems.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return ListView(
      children: [
        const Text(
          'These settings are shared by every Ollama output and FINAL OUTPUT spell check.',
          style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.35),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ollama host',
                  filled: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _refreshModels(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Refresh installed models',
              onPressed: _refreshing ? null : () => _refreshModels(),
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: (_selectedModel == null || _selectedModel!.isEmpty)
              ? null
              : _selectedModel,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Default model',
            filled: true,
            border: OutlineInputBorder(),
          ),
          hint: const Text('Choose a local model'),
          items: sortedModels
              .map((model) => DropdownMenuItem(value: model, child: Text(model)))
              .toList(),
          onChanged: (value) async {
            setState(() => _selectedModel = value);
            if (value != null) {
              await _prefs?.setString(_defaultModelKey, value);
            }
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _systemCtrl,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'System prompt',
            alignLabelWithHint: true,
            filled: true,
            border: OutlineInputBorder(),
          ),
        ),
        if (_status != null) ...[
          const SizedBox(height: 10),
          Text(
            _status!,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ],
    );
  }
}
