// lib/ui/panels/tts_panel.dart

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants.dart';
import '../../models/story_node.dart';
import '../../models/voice_model.dart';
import '../../services/piper_service.dart';
import '../../state/project_state.dart';
import '../../utils/text_helpers.dart';

enum TtsSource { selectedNode, compiledOutput }

typedef PlaybackRangeChanged = void Function(
  String? nodeId,
  int localStart,
  int localEnd,
);

class TtsPanel extends StatefulWidget {
  final PlaybackRangeChanged? onPlaybackRange;
  final VoidCallback? onPlaybackStopped;

  const TtsPanel({
    super.key,
    this.onPlaybackRange,
    this.onPlaybackStopped,
  });

  @override
  State<TtsPanel> createState() => TtsPanelState();
}

class TtsPanelState extends State<TtsPanel> {
  final PiperService _piper = PiperService();

  SharedPreferences? _prefs;
  VoiceModel? _selectedVoice;
  String _modelPath = '';
  double _speechSpeed = 1.0;
  int _speakerId = 0;
  bool _useGpu = false;
  bool _gpuTesting = false;
  bool _includeTitles = false;
  bool _withSubtitles = false;
  bool _ready = false;
  bool _playing = false;
  bool _rendering = false;
  double _renderProgress = 0;
  String _renderEta = '';
  int _activeChunkIndex = -1;
  List<TextChunk> _playbackChunks = const <TextChunk>[];
  TtsSource _source = TtsSource.selectedNode;
  int _playbackRunId = 0;

  bool get _busy => _playing || _rendering;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _piper.init();

      _speechSpeed = prefs.getDouble('node_writer_tts_speed') ?? 1.0;
      _speakerId = prefs.getInt('node_writer_tts_speaker') ?? 0;
      _useGpu = prefs.getBool('node_writer_tts_gpu') ?? false;
      _includeTitles = prefs.getBool('node_writer_tts_titles') ?? false;
      _withSubtitles = prefs.getBool('node_writer_tts_srt') ?? false;

      final savedModel = prefs.getString('node_writer_tts_model');
      if (savedModel != null && File(savedModel).existsSync()) {
        _modelPath = savedModel;
        for (final voice in _piper.availableVoices) {
          if (voice.path == savedModel) {
            _selectedVoice = voice;
            break;
          }
        }
        if (_selectedVoice == null) {
          _selectedVoice = VoiceModel(
            name: 'Custom (${p.basename(savedModel)})',
            path: savedModel,
          );
          _piper.availableVoices.insert(0, _selectedVoice!);
        }
      } else if (_piper.availableVoices.isNotEmpty) {
        _selectedVoice = _piper.availableVoices.first;
        _modelPath = _selectedVoice!.path;
      }

      _prefs = prefs;
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _ready = true);
      _toast('TTS initialization failed: $e');
    }
  }

  _SpeechDocument _selectedNodeDocument(
    ProjectState state, {
    String? nodeId,
    bool contentOnly = false,
  }) {
    final String? id = nodeId ??
        (state.selectedNodeIds.isNotEmpty ? state.selectedNodeIds.first : null);
    final StoryNode? node = id == null ? null : state.nodes[id];
    if (node == null || node.type != NodeType.scene) {
      return const _SpeechDocument('', <_SpeechSpan>[]);
    }

    final StringBuffer buffer = StringBuffer();
    final List<_SpeechSpan> spans = <_SpeechSpan>[];

    if (!contentOnly && _includeTitles && node.title.trim().isNotEmpty) {
      final int start = buffer.length;
      buffer.write(node.title.trim());
      spans.add(_SpeechSpan(node.id, start, buffer.length, false));
      buffer.write('\n\n');
    }

    final int contentStart = buffer.length;
    buffer.write(node.content);
    spans.add(_SpeechSpan(node.id, contentStart, buffer.length, true));
    return _SpeechDocument(buffer.toString(), spans);
  }

  _SpeechDocument _compiledDocument(
    ProjectState state, {
    String? targetId,
  }) {
    final StringBuffer buffer = StringBuffer();
    final List<_SpeechSpan> spans = <_SpeechSpan>[];

    for (final node in state.getCompiledNodes(targetId)) {
      if (node.type != NodeType.scene) continue;
      if (buffer.isNotEmpty) buffer.writeln();

      if (_includeTitles && node.title.trim().isNotEmpty) {
        final int titleStart = buffer.length;
        buffer.writeln(node.title.trim());
        spans.add(_SpeechSpan(node.id, titleStart, buffer.length, false));
        buffer.writeln();
      }

      final int contentStart = buffer.length;
      buffer.write(node.content);
      spans.add(_SpeechSpan(node.id, contentStart, buffer.length, true));
      buffer.writeln();
    }

    return _SpeechDocument(buffer.toString(), spans);
  }

  int _docRevision = -1;
  TtsSource? _docSource;
  bool? _docTitles;
  String? _docSelected;
  String? _docTarget;
  _SpeechDocument _docCache = const _SpeechDocument('', <_SpeechSpan>[]);

  /// A Final Output node represents the whole manuscript that reaches that
  /// target, so VOICE treats it as compiled speech automatically. Scene nodes
  /// keep the user's normal Selected/Compiled choice.
  TtsSource _effectiveSource(ProjectState state) {
    final String? selected =
        state.selectedNodeIds.isNotEmpty ? state.selectedNodeIds.first : null;
    final StoryNode? node = selected == null ? null : state.nodes[selected];
    return node?.type == NodeType.output ? TtsSource.compiledOutput : _source;
  }

  /// When a specific Final Output is selected, compile toward that exact sink.
  /// This matters in projects with more than one output node.
  String? _compiledTargetId(ProjectState state) {
    final String? selected =
        state.selectedNodeIds.isNotEmpty ? state.selectedNodeIds.first : null;
    final StoryNode? node = selected == null ? null : state.nodes[selected];
    return node?.type == NodeType.output ? node!.id : null;
  }

  /// Building the compiled speech document walks the graph and concatenates
  /// every Scene. Memoized against ProjectState.revision so dragging a node
  /// around the canvas does not rebuild the whole manuscript per frame.
  _SpeechDocument _sourceDocument(ProjectState state) {
    final String? selected =
        state.selectedNodeIds.isNotEmpty ? state.selectedNodeIds.first : null;
    final TtsSource source = _effectiveSource(state);
    final String? targetId =
        source == TtsSource.compiledOutput ? _compiledTargetId(state) : null;
    if (_docRevision == state.revision &&
        _docSource == source &&
        _docTitles == _includeTitles &&
        _docSelected == selected &&
        _docTarget == targetId) {
      return _docCache;
    }
    final _SpeechDocument document = source == TtsSource.selectedNode
        ? _selectedNodeDocument(state)
        : _compiledDocument(state, targetId: targetId);
    _docRevision = state.revision;
    _docSource = source;
    _docTitles = _includeTitles;
    _docSelected = selected;
    _docTarget = targetId;
    _docCache = document;
    return document;
  }

  String _sourceText(ProjectState state) => _sourceDocument(state).text;

  Future<void> _play(ProjectState state) async {
    if (!_ready || _rendering) return;
    final _SpeechDocument document = _sourceDocument(state);
    await _startPlayback(document, source: _effectiveSource(state));
  }

  /// Called by the WRITE editor. Double-clicking text starts reading from the
  /// sentence under the caret using the same Piper voice/settings as VOICE.
  Future<void> playSelectedNodeFromOffset(
    ProjectState state,
    String nodeId,
    int localOffset,
  ) async {
    if (!_ready || _rendering) return;

    final _SpeechDocument document = _selectedNodeDocument(
      state,
      nodeId: nodeId,
      contentOnly: true,
    );
    final List<TextChunk> chunks = TextHelpers.splitIntoChunks(document.text);
    if (chunks.isEmpty) return;
    final int at = TextHelpers.chunkIndexForOffset(
      chunks,
      localOffset.clamp(0, document.text.length),
    );
    final int start = TextHelpers.nextSpeakableIndex(chunks, at);
    if (mounted) setState(() => _source = TtsSource.selectedNode);
    await _startPlayback(
      document,
      startIndex: start,
      source: TtsSource.selectedNode,
    );
  }

  Future<void> _startPlayback(
    _SpeechDocument document, {
    int startIndex = 0,
    TtsSource? source,
  }) async {
    final String text = document.text;
    if (text.trim().isEmpty) {
      _toast((source ?? _source) == TtsSource.selectedNode
          ? 'Select a scene with text first.'
          : 'The compiled output has no text yet.');
      return;
    }
    if (!File(_piper.exePath).existsSync()) {
      _toast('Piper binary not found at ${_piper.exePath}');
      return;
    }
    if (_modelPath.isEmpty || !File(_modelPath).existsSync()) {
      _toast('Choose a Piper voice model first.');
      return;
    }

    final List<TextChunk> chunks = TextHelpers.splitIntoChunks(text);
    if (!chunks.any((c) => c.hasSpeech)) {
      _toast('No speakable text found.');
      return;
    }

    final int safeStart = TextHelpers.nextSpeakableIndex(
      chunks,
      startIndex.clamp(0, chunks.length - 1),
    );

    if (_playing) {
      _playbackRunId++;
      await _piper.stop();
    }
    final int myRun = ++_playbackRunId;
    if (!mounted) return;
    setState(() {
      _playing = true;
      _activeChunkIndex = safeStart;
      _playbackChunks = chunks;
    });

    _emitPlaybackRange(document, chunks[safeStart]);

    try {
      await _piper.playChunks(
        chunks.map((c) => c.text).toList(),
        modelPath: _modelPath,
        speed: _speechSpeed,
        speakerId: _speakerId,
        useGpu: _useGpu,
        startIndex: safeStart,
        onChunkStart: (index) {
          if (!mounted || myRun != _playbackRunId || index < 0 || index >= chunks.length) return;
          setState(() => _activeChunkIndex = index);
          _emitPlaybackRange(document, chunks[index]);
        },
      );
    } catch (e) {
      if (mounted) _toast('Playback failed: $e');
    } finally {
      if (mounted && myRun == _playbackRunId) {
        setState(() {
          _playing = false;
          _activeChunkIndex = -1;
        });
        widget.onPlaybackStopped?.call();
      }
    }
  }

  void _emitPlaybackRange(_SpeechDocument document, TextChunk chunk) {
    final _MappedRange? mapped = document.mapChunk(chunk);
    if (mapped == null) return;
    widget.onPlaybackRange?.call(
      mapped.nodeId,
      mapped.localStart,
      mapped.localEnd,
    );
  }

  Future<void> stopPlayback() => _stop();

  Future<void> _stop() async {
    _playbackRunId++;
    await _piper.stop();
    if (!mounted) return;
    setState(() {
      _playing = false;
      _rendering = false;
      _activeChunkIndex = -1;
    });
    widget.onPlaybackStopped?.call();
  }

  Future<void> _render(ProjectState state) async {
    if (!_ready || _busy) return;
    final text = _sourceText(state);
    if (text.trim().isEmpty) {
      _toast('Nothing to render.');
      return;
    }
    if (!File(_piper.exePath).existsSync()) {
      _toast('Piper binary not found at ${_piper.exePath}');
      return;
    }
    if (_modelPath.isEmpty || !File(_modelPath).existsSync()) {
      _toast('Choose a Piper voice model first.');
      return;
    }

    final defaultName = _effectiveSource(state) == TtsSource.compiledOutput
        ? '${state.projectName}_compiled.wav'
        : '${state.projectName}_scene.wav';
    String? output = await FilePicker.platform.saveFile(
      dialogTitle: 'Render speech',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: const ['wav'],
    );
    if (output == null) return;
    if (!output.toLowerCase().endsWith('.wav')) output += '.wav';

    final chunks = TextHelpers.splitIntoChunks(text)
        .where((c) => c.hasSpeech)
        .map((c) => c.text)
        .toList();

    setState(() {
      _rendering = true;
      _renderProgress = 0;
      _renderEta = 'Starting';
    });

    try {
      final ok = await _piper.generateToFile(
        text,
        output,
        modelPath: _modelPath,
        speed: _speechSpeed,
        speakerId: _speakerId,
        useGpu: _useGpu,
        exportChunks: chunks,
        isSubtitlesRequested: _withSubtitles,
        onProgress: (current, total, eta) {
          if (!mounted) return;
          setState(() {
            _renderProgress = total <= 0 ? 0 : current / total;
            _renderEta = '$current / $total   ETA $eta';
          });
        },
      );
      if (!mounted) return;
      _toast(ok
          ? 'Rendered ${p.basename(output)}'
          : 'Piper did not complete the render.');
    } catch (e) {
      if (mounted) _toast('Render failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _rendering = false;
          _renderProgress = 0;
          _renderEta = '';
        });
      }
    }
  }

  Future<void> _pickVoice() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose Piper voice model',
      type: FileType.custom,
      allowedExtensions: const ['onnx'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final voice = VoiceModel(name: 'Custom (${p.basename(path)})', path: path);
    setState(() {
      _selectedVoice = voice;
      _modelPath = path;
      if (!_piper.availableVoices.any((v) => v.path == path)) {
        _piper.availableVoices.insert(0, voice);
      }
    });
    await _prefs?.setString('node_writer_tts_model', path);
  }

  Future<void> _testGpu(bool wanted) async {
    if (!wanted) {
      setState(() => _useGpu = false);
      await _prefs?.setBool('node_writer_tts_gpu', false);
      return;
    }
    if (_modelPath.isEmpty || !File(_modelPath).existsSync()) {
      _toast('Choose a valid voice model before testing CUDA.');
      return;
    }
    setState(() => _gpuTesting = true);
    final works = await _piper.testGpuSupport(_modelPath);
    if (!mounted) return;
    setState(() {
      _gpuTesting = false;
      _useGpu = works;
    });
    await _prefs?.setBool('node_writer_tts_gpu', works);
    _toast(works
        ? 'CUDA acceleration enabled.'
        : 'CUDA unavailable for this Piper build.');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    _piper.dispose();
    super.dispose();
  }

  // Sentence splitting runs a unicode regex over the whole compiled document.
  // build() is reached on every ProjectState notification, including each
  // frame of a node drag, so the statistics are memoized on the source text.
  String _statsText = '';
  int _statsSentences = 0;
  int _statsWords = 0;

  void _refreshStats(String text) {
    if (identical(text, _statsText) || text == _statsText) return;
    _statsText = text;
    _statsSentences =
        TextHelpers.splitIntoChunks(text).where((c) => c.hasSpeech).length;
    _statsWords = TextHelpers.wordCount(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final text = _sourceText(state);
    final TtsSource effectiveSource = _effectiveSource(state);
    final bool finalOutputSelected = _compiledTargetId(state) != null;
    _refreshStats(text);
    final sentenceCount = _statsSentences;
    final words = _statsWords;

    final activeText = _activeChunkIndex >= 0 &&
            _activeChunkIndex < _playbackChunks.length
        ? _playbackChunks[_activeChunkIndex].label
        : '';

    return Container(
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: kAccentColor, size: 19),
              const SizedBox(width: 8),
              const Text(
                'VOICE',
                style: TextStyle(
                  color: kAccentColor,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              if (!_ready)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton<TtsSource>(
            segments: const [
              ButtonSegment(
                value: TtsSource.selectedNode,
                icon: Icon(Icons.article_outlined, size: 16),
                label: Text('Selected'),
              ),
              ButtonSegment(
                value: TtsSource.compiledOutput,
                icon: Icon(Icons.route_outlined, size: 16),
                label: Text('Compiled'),
              ),
            ],
            selected: {effectiveSource},
            onSelectionChanged: _busy || finalOutputSelected
                ? null
                : (value) => setState(() => _source = value.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF222222),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  effectiveSource == TtsSource.selectedNode
                      ? _selectedSourceLabel(state)
                      : finalOutputSelected
                          ? 'Final Output · full compiled manuscript'
                          : 'Compiled graph output',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$words words  •  $sentenceCount sentences',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_playing)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: kAccentColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: kAccentColor.withValues(alpha: 0.25)),
              ),
              child: Text(
                activeText.isEmpty ? 'Generating speech…' : activeText,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
            ),
          if (_rendering) ...[
            LinearProgressIndicator(value: _renderProgress == 0 ? null : _renderProgress),
            const SizedBox(height: 6),
            Text(_renderEta, style: const TextStyle(color: Colors.white54, fontSize: 10)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: !_ready || text.trim().isEmpty
                      ? null
                      : (_busy ? _stop : () => _play(state)),
                  icon: Icon(_busy ? Icons.stop : Icons.play_arrow),
                  label: Text(_busy ? 'STOP' : 'READ'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _busy ? Colors.redAccent : kAccentColor,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Render WAV',
                onPressed: !_ready || _busy || text.trim().isEmpty
                    ? null
                    : () => _render(state),
                icon: const Icon(Icons.save_alt),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white12),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                _sectionLabel('VOICE MODEL'),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<VoiceModel>(
                        value: _selectedVoice,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF252525),
                        decoration: _inputDecoration(),
                        items: _piper.availableVoices
                            .map((voice) => DropdownMenuItem(
                                  value: voice,
                                  child: Text(
                                    voice.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ))
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (voice) async {
                                if (voice == null) return;
                                setState(() {
                                  _selectedVoice = voice;
                                  _modelPath = voice.path;
                                });
                                await _prefs?.setString('node_writer_tts_model', voice.path);
                              },
                      ),
                    ),
                    const SizedBox(width: 7),
                    IconButton(
                      tooltip: 'Choose .onnx model',
                      onPressed: _busy ? null : _pickVoice,
                      icon: const Icon(Icons.folder_open, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 17),
                _sectionLabel('SPEED'),
                Slider(
                  value: _speechSpeed,
                  min: 0.65,
                  max: 1.65,
                  divisions: 20,
                  label: _speechSpeed.toStringAsFixed(2),
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _speechSpeed = value);
                          _prefs?.setDouble('node_writer_tts_speed', value);
                        },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Faster', style: TextStyle(color: Colors.white38, fontSize: 10)),
                    Text('length scale ${_speechSpeed.toStringAsFixed(2)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 10)),
                    const Text('Slower', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 14),
                _sectionLabel('SPEAKER ID'),
                const SizedBox(height: 7),
                Row(
                  children: [
                    IconButton.outlined(
                      onPressed: _busy || _speakerId <= 0
                          ? null
                          : () {
                              setState(() => _speakerId--);
                              _prefs?.setInt('node_writer_tts_speaker', _speakerId);
                            },
                      icon: const Icon(Icons.remove, size: 16),
                    ),
                    Expanded(
                      child: Center(
                        child: Text('$_speakerId',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    IconButton.outlined(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _speakerId++);
                              _prefs?.setInt('node_writer_tts_speaker', _speakerId);
                            },
                      icon: const Icon(Icons.add, size: 16),
                    ),
                  ],
                ),
                SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('CUDA / GPU', style: TextStyle(fontSize: 12)),
                  subtitle: Text(
                    _gpuTesting ? 'Testing Piper CUDA provider…' : 'Use GPU acceleration when available',
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                  value: _useGpu,
                  onChanged: _busy || _gpuTesting ? null : _testGpu,
                ),
                SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Speak node titles', style: TextStyle(fontSize: 12)),
                  value: _includeTitles,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _includeTitles = value);
                          _prefs?.setBool('node_writer_tts_titles', value);
                        },
                ),
                SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Write .srt with render', style: TextStyle(fontSize: 12)),
                  value: _withSubtitles,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _withSubtitles = value);
                          _prefs?.setBool('node_writer_tts_srt', value);
                        },
                ),
                const SizedBox(height: 10),
                Text(
                  _piper.isInitialized
                      ? 'Piper: ${_piper.exePath}'
                      : 'Piper is initializing…',
                  style: const TextStyle(color: Colors.white30, fontSize: 9),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _selectedSourceLabel(ProjectState state) {
    if (state.selectedNodeIds.isEmpty) return 'No scene selected';
    final node = state.nodes[state.selectedNodeIds.first];
    if (node == null) return 'No scene selected';
    if (node.type == NodeType.output) return 'Final Output node selected';
    if (node.type == NodeType.merge) return 'Merge node selected';
    return node.title;
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      );

  InputDecoration _inputDecoration() => const InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Color(0xFF222222),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        border: OutlineInputBorder(borderSide: BorderSide.none),
      );
}


class _SpeechDocument {
  final String text;
  final List<_SpeechSpan> spans;

  const _SpeechDocument(this.text, this.spans);

  _MappedRange? mapChunk(TextChunk chunk) {
    if (spans.isEmpty) return null;

    // Prefer content ranges over spoken titles when a chunk crosses both.
    _SpeechSpan? hit;
    for (final _SpeechSpan span in spans) {
      if (!span.isContent) continue;
      if (chunk.start < span.docEnd && chunk.end > span.docStart) {
        hit = span;
        break;
      }
    }
    if (hit == null) {
      for (final _SpeechSpan span in spans) {
        if (chunk.start < span.docEnd && chunk.end > span.docStart) {
          hit = span;
          break;
        }
      }
    }
    if (hit == null) return null;

    if (!hit.isContent) {
      return _MappedRange(hit.nodeId, 0, 0);
    }

    final int a = chunk.start.clamp(hit.docStart, hit.docEnd) - hit.docStart;
    final int b = chunk.end.clamp(hit.docStart, hit.docEnd) - hit.docStart;
    return _MappedRange(hit.nodeId, a, b);
  }
}

class _SpeechSpan {
  final String nodeId;
  final int docStart;
  final int docEnd;
  final bool isContent;
  const _SpeechSpan(this.nodeId, this.docStart, this.docEnd, this.isContent);
}

class _MappedRange {
  final String nodeId;
  final int localStart;
  final int localEnd;
  const _MappedRange(this.nodeId, this.localStart, this.localEnd);
}