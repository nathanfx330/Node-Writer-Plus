import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/story_node.dart';
import '../models/authorial_constraint.dart';
import '../state/project_state.dart';
import '../utils/markdown_controller.dart';
import 'panels/preview_panel.dart';
import 'panels/tts_panel.dart';
import 'panels/ollama_node_panel.dart';

enum _SidePanelMode { write, secondary }

class SidePanel extends StatefulWidget {
  const SidePanel({super.key});

  @override
  State<SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<SidePanel> {
  late TextEditingController _titleCtrl;
  late MarkdownSyntaxController _contentCtrl;
  final FocusNode _contentFocusNode = FocusNode();
  final ScrollController _contentScrollController = ScrollController();
  final GlobalKey _editorBoxKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final GlobalKey<TtsPanelState> _ttsKey = GlobalKey<TtsPanelState>();

  String? _editingId;
  _SidePanelMode _mode = _SidePanelMode.write;

  bool _isSearching = false;
  String _searchQuery = '';
  List<int> _searchMatches = <int>[];
  int _currentSearchMatch = -1;

  String? _lastPlaybackNodeId;
  bool _playbackActive = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _contentCtrl = MarkdownSyntaxController();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    _contentFocusNode.dispose();
    _contentScrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _invalidateEditorLayout();
    super.dispose();
  }

  void _syncEditorNode(StoryNode node) {
    if (_editingId == node.id) {
      // Ollama can update node.content while WRITE is offstage. Pull that
      // external result into the editor without disturbing active typing.
      if (!_contentFocusNode.hasFocus && _contentCtrl.text != node.content) {
        _contentCtrl.text = node.content;
        if (_isSearching) _applySearch(_searchController.text);
      }
      _contentCtrl.setAuthorConstraints(node.authorConstraints);
      return;
    }
    _editingId = node.id;
    _invalidateEditorLayout();
    _titleCtrl.text = node.title;
    _contentCtrl.text = node.content;
    _contentCtrl.setAuthorConstraints(node.authorConstraints);
    _contentCtrl.clearPlaybackRange();
    if (_isSearching) {
      _applySearch(_searchController.text);
    } else {
      _contentCtrl.clearSearch();
    }
  }

  void _toggleFormatting(String char) {
    final text = _contentCtrl.text;
    final selection = _contentCtrl.selection;
    if (selection.start < 0 || _editingId == null) return;
    final start = selection.start;
    final end = selection.end;
    bool isWrapped = false;
    if (start >= char.length && end <= text.length - char.length) {
      if (text.substring(start - char.length, start) == char &&
          text.substring(end, end + char.length) == char) {
        isWrapped = true;
      }
    }
    String newText;
    if (isWrapped) {
      newText = text
          .replaceRange(end, end + char.length, '')
          .replaceRange(start - char.length, start, '');
      _contentCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start - char.length,
          extentOffset: end - char.length,
        ),
      );
    } else {
      newText = text.replaceRange(
          start, end, '$char${text.substring(start, end)}$char');
      _contentCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start + char.length,
          extentOffset: end + char.length,
        ),
      );
    }
    _ttsKey.currentState?.stopPlayback();
    final state = context.read<ProjectState>();
    state.updateNodeContent(_editingId!, newText);
    final node = state.nodes[_editingId!];
    if (node != null) _contentCtrl.setAuthorConstraints(node.authorConstraints);
    _reportDroppedConstraints(state);
    if (_isSearching) _runSearch(_searchController.text, reveal: false);
  }

  void _protectSelection(
    ProjectState state,
    StoryNode node,
    AuthorConstraintType type,
  ) {
    final selection = _contentCtrl.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = selection.start < selection.end ? selection.start : selection.end;
    final end = selection.start < selection.end ? selection.end : selection.start;
    state.addAuthorConstraint(node.id, start, end, type);
    _contentCtrl.setAuthorConstraints(node.authorConstraints);
    ContextMenuController.removeAny();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          type == AuthorConstraintType.exact
              ? 'Exact wording protected from Ollama.'
              : 'Meaning / claim protected for Ollama.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _removeProtection(ProjectState state, StoryNode node) {
    final selection = _contentCtrl.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = selection.start < selection.end ? selection.start : selection.end;
    final end = selection.start < selection.end ? selection.end : selection.start;
    state.removeAuthorConstraints(node.id, start, end);
    _contentCtrl.setAuthorConstraints(node.authorConstraints);
    ContextMenuController.removeAny();
  }

  Widget _buildEditorContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
    ProjectState state,
    StoryNode node,
  ) {
    final selection = _contentCtrl.selection;
    final hasSelection = selection.isValid && !selection.isCollapsed;
    final buttons = <ContextMenuButtonItem>[];
    if (hasSelection) {
      buttons.addAll([
        ContextMenuButtonItem(
          label: 'Protect from Ollama — exact wording',
          onPressed: () => _protectSelection(
            state,
            node,
            AuthorConstraintType.exact,
          ),
        ),
        ContextMenuButtonItem(
          label: 'Protect meaning / claim',
          onPressed: () => _protectSelection(
            state,
            node,
            AuthorConstraintType.meaning,
          ),
        ),
        ContextMenuButtonItem(
          label: 'Remove AI protection',
          onPressed: () => _removeProtection(state, node),
        ),
      ]);
    }
    buttons.addAll(editableTextState.contextMenuButtonItems);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buttons,
    );
  }

  void _openSearch() {
    setState(() => _isSearching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
      _searchMatches = <int>[];
      _currentSearchMatch = -1;
      _contentCtrl.clearSearch();
    });
    _contentFocusNode.requestFocus();
  }

  /// Recomputes match offsets without touching element state.
  ///
  /// Kept free of setState so it is safe to call from the build phase, which
  /// is what happens when the selected Scene changes while Find is open.
  void _applySearch(String query) {
    _searchQuery = query;
    final List<int> hits = <int>[];
    if (query.length >= 2) {
      final String hay = _contentCtrl.text.toLowerCase();
      final String needle = query.toLowerCase();
      int index = hay.indexOf(needle);
      while (index >= 0) {
        hits.add(index);
        index = hay.indexOf(needle, index + needle.length);
      }
    }

    _searchMatches = hits;
    _currentSearchMatch = hits.isEmpty ? -1 : 0;
    _contentCtrl.searchQuery = query.length >= 2 ? query : '';
    _contentCtrl.activeMatchOffset = hits.isEmpty ? -1 : hits.first;
  }

  void _runSearch(String query, {bool reveal = true}) {
    _applySearch(query);
    if (mounted) setState(() {});
    if (reveal && _searchMatches.isNotEmpty) {
      _revealSearchMatch();
    } else if (_searchFocusNode.hasFocus) {
      // Updating highlights while the user types must never steal focus from
      // the Find field. Otherwise subsequent characters land in the editor.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isSearching) _searchFocusNode.requestFocus();
      });
    }
  }

  void _stepSearch(int delta) {
    if (_searchMatches.isEmpty) return;
    final int count = _searchMatches.length;
    _currentSearchMatch = (_currentSearchMatch + delta) % count;
    if (_currentSearchMatch < 0) _currentSearchMatch += count;
    setState(() {});
    _revealSearchMatch();
  }

  void _revealSearchMatch() {
    if (_currentSearchMatch < 0 ||
        _currentSearchMatch >= _searchMatches.length) {
      return;
    }
    final int offset = _searchMatches[_currentSearchMatch];
    _contentCtrl.activeMatchOffset = offset;
    _contentCtrl.selection = TextSelection.collapsed(offset: offset);

    // Keep keyboard focus in Find. Navigation should move/scroll the match,
    // not turn the next typed character into an edit of the document.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isSearching) _searchFocusNode.requestFocus();
    });
    final StoryNode? node = _editingId == null
        ? null
        : context.read<ProjectState>().nodes[_editingId];
    if (node != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) =>
          _revealEditorOffset(offset, node));
    }
  }

  Future<void> _readFromEditorCursor(ProjectState state, StoryNode node) async {
    final TextSelection selection = _contentCtrl.selection;
    final int offset = selection.extentOffset < 0
        ? 0
        : selection.extentOffset.clamp(0, _contentCtrl.text.length);
    await _ttsKey.currentState
        ?.playSelectedNodeFromOffset(state, node.id, offset);
  }

  void _handlePlaybackRange(String? nodeId, int localStart, int localEnd) {
    if (!mounted || nodeId == null) return;
    final ProjectState state = context.read<ProjectState>();
    final StoryNode? node = state.nodes[nodeId];
    if (node == null ||
        node.type != NodeType.scene) {
      return;
    }

    final bool changedNode = _lastPlaybackNodeId != nodeId;
    _lastPlaybackNodeId = nodeId;
    if (!_playbackActive) {
      setState(() => _playbackActive = true);
    }
    if (changedNode) {
      // Follow compiled playback across the graph as the voice enters a new
      // content node. jumpToNode also selects it and centers it on the canvas.
      state.jumpToNode(nodeId);
    }

    _editingId = node.id;
    if (_contentCtrl.text != node.content) {
      _titleCtrl.text = node.title;
      _contentCtrl.text = node.content;
      if (_isSearching) _runSearch(_searchController.text, reveal: false);
    }
    _contentCtrl.setAuthorConstraints(node.authorConstraints);

    final int start = localStart.clamp(0, _contentCtrl.text.length);
    final int end = localEnd.clamp(start, _contentCtrl.text.length);
    if (end > start) {
      _contentCtrl.setPlaybackRange(start, end);
    } else {
      _contentCtrl.clearPlaybackRange();
    }
    _contentCtrl.selection = TextSelection.collapsed(offset: start);

    // Follow the spoken text without forcing a panel change. If the user is
    // looking at VOICE, VOICE stays visible; if they are editing, WRITE stays
    // visible and follows the sentence in place.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _revealEditorOffset(start, node);
    });
  }

  void _revealEditorOffset(int offset, StoryNode node) {
    if (!_contentScrollController.hasClients) return;
    final BuildContext? editorContext = _editorBoxKey.currentContext;
    if (editorContext == null) return;
    final RenderBox? box = editorContext.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 40) return;

    final TextStyle style = _getFontStyle(node.fontFamily).copyWith(fontSize: 14);
    // Same laid-out span the field and the gutter use. Measuring an unstyled
    // copy of the text drifts as soon as the Scene contains bold or italic,
    // because the markdown markers render at a near-zero font size.
    final TextPainter painter = _ensureEditorLayout(
      editorContext,
      style: style,
      align: node.textAlign,
      width: (box.size.width - 66).clamp(1.0, double.infinity).toDouble(),
    );

    final Offset caret = painter.getOffsetForCaret(
      TextPosition(offset: offset.clamp(0, _contentCtrl.text.length)),
      Rect.zero,
    );
    final ScrollPosition position = _contentScrollController.position;
    final double target =
        (caret.dy - position.viewportDimension * 0.30)
            .clamp(0.0, position.maxScrollExtent);
    final double distance = (position.pixels - target).abs();
    if (distance < 8) return;
    _contentScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
    );
  }

  // ---------------------------------------------------------------------
  // Editor layout cache
  // ---------------------------------------------------------------------
  //
  // The gutter used to lay out the entire document on every scroll frame and
  // then call getOffsetForCaret once per line. Text metrics only depend on the
  // text, the width, the alignment and the font: highlight overlays change
  // colour, never size. So the layout is computed when one of those four
  // changes and reused for everything else.

  TextPainter? _layoutPainter;
  String _layoutText = '';
  double _layoutWidth = -1;
  TextAlign _layoutAlign = TextAlign.left;
  String? _layoutFont;
  List<double> _layoutLineTops = const <double>[];

  void _invalidateEditorLayout() {
    _layoutPainter?.dispose();
    _layoutPainter = null;
    _layoutWidth = -1;
    _layoutLineTops = const <double>[];
  }

  TextPainter _ensureEditorLayout(
    BuildContext ctx, {
    required TextStyle style,
    required TextAlign align,
    required double width,
  }) {
    final String text = _contentCtrl.text;
    final TextPainter? cached = _layoutPainter;
    if (cached != null &&
        _layoutText == text &&
        _layoutWidth == width &&
        _layoutAlign == align &&
        _layoutFont == style.fontFamily) {
      return cached;
    }

    final TextSpan span = _contentCtrl.buildTextSpan(
      context: ctx,
      style: style,
      withComposing: false,
    );
    final TextPainter painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width);

    final List<double> tops = <double>[];
    final List<int> starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) starts.add(i + 1);
    }
    for (final int start in starts) {
      tops.add(painter
          .getOffsetForCaret(TextPosition(offset: start), Rect.zero)
          .dy);
    }

    _layoutPainter?.dispose();
    _layoutPainter = painter;
    _layoutText = text;
    _layoutWidth = width;
    _layoutAlign = align;
    _layoutFont = style.fontFamily;
    _layoutLineTops = tops;
    return painter;
  }

  /// Editing over a protected span retires the lock rather than moving it onto
  /// the replacement characters. That is a deliberate loss, so it is announced.
  void _reportDroppedConstraints(ProjectState state) {
    final dropped = state.consumeDroppedConstraintCount();
    if (dropped == 0 || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            dropped == 1
                ? 'Edit replaced protected text. That lock was released.'
                : 'Edit replaced protected text. $dropped locks were released.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _handlePlaybackStopped() {
    if (!mounted) return;
    _lastPlaybackNodeId = null;
    _contentCtrl.clearPlaybackRange();
    setState(() => _playbackActive = false);
  }

  void _stopPlaybackFromEditor() {
    _ttsKey.currentState?.stopPlayback();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    final nodeId =
        state.selectedNodeIds.isNotEmpty ? state.selectedNodeIds.first : null;
    final node = nodeId != null ? state.nodes[nodeId] : null;

    if (node != null && node.type == NodeType.scene) {
      _syncEditorNode(node);
    }

    final bool selectedIsOllama = node?.type == NodeType.ollama;

    return Container(
      width: double.infinity,
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          _modeBar(node),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Offstage(
                    offstage: _mode != _SidePanelMode.write,
                    child: _buildWritePanel(state, node),
                  ),
                ),
                // Keep TTS mounted so Scene/Final Output playback survives panel
                // changes. Ollama output nodes use this slot for Ollama instead.
                Positioned.fill(
                  child: Offstage(
                    offstage: _mode != _SidePanelMode.secondary || selectedIsOllama,
                    child: TtsPanel(
                      key: _ttsKey,
                      onPlaybackRange: _handlePlaybackRange,
                      onPlaybackStopped: _handlePlaybackStopped,
                    ),
                  ),
                ),
                if (selectedIsOllama && node != null)
                  Positioned.fill(
                    child: Offstage(
                      offstage: _mode != _SidePanelMode.secondary,
                      child: OllamaNodePanel(nodeId: node.id),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeBar(StoryNode? node) {
    final bool isOllama = node?.type == NodeType.ollama;
    final bool isOutputLike =
        node?.type == NodeType.output || node?.type == NodeType.ollama;

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: const Color(0xFF171717),
      child: Row(
        children: [
          _modeButton(
            mode: _SidePanelMode.write,
            icon: isOutputLike ? Icons.article_outlined : Icons.edit_note,
            label: isOutputLike ? 'OUTPUT' : 'WRITE',
          ),
          const SizedBox(width: 6),
          _modeButton(
            mode: _SidePanelMode.secondary,
            icon: isOllama ? Icons.auto_awesome : Icons.graphic_eq,
            label: isOllama ? 'OLLAMA' : 'VOICE',
          ),
        ],
      ),
    );
  }

  Widget _modeButton({
    required _SidePanelMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = _mode == mode;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          if (mode == _SidePanelMode.secondary) {
            _contentFocusNode.unfocus();
            _searchFocusNode.unfocus();
          }
          setState(() => _mode = mode);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: selected ? kAccentColor.withValues(alpha: 0.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? kAccentColor.withValues(alpha: 0.45) : Colors.white10,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 15, color: selected ? kAccentColor : Colors.white38),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? kAccentColor : Colors.white54,
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWritePanel(ProjectState state, StoryNode? node) {
    if (state.previewNodeId != null) {
      return const PreviewPanel();
    }

    if (node != null && node.type == NodeType.output) {
      return PreviewPanel(
        targetId: node.id,
        title: 'FINAL OUTPUT',
        showProofread: true,
      );
    }

    if (node != null && node.type == NodeType.ollama) {
      return PreviewPanel(
        targetId: node.id,
        title: 'COMPILED INPUT',
        showProofread: false,
      );
    }

    if (node == null) {
      return const Center(
        child: Text('Select a Node', style: TextStyle(color: Colors.grey)),
      );
    }

    if (node.type == NodeType.merge) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MERGE NODE',
              style: TextStyle(
                color: Colors.yellowAccent,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Combines multiple parallel branches into a single linear flow.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 10),
            Text(
              'This allows you to work on different sections of your writing in separate columns, and safely merge them together before compilation. The left-most port is compiled first, then the center, then the right.',
              style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      );
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_isSearching) {
            _closeSearch();
          } else if (_playbackActive) {
            _stopPlaybackFromEditor();
          }
        },
      },
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PROPERTIES',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                labelText: '${state.unitLabel} Title',
                filled: true,
                fillColor: const Color(0xFF222222),
              ),
              onChanged: (v) => state.updateNodeTitle(node.id, v),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                DropdownButton<String>(
                  value: node.fontFamily,
                  dropdownColor: const Color(0xFF333333),
                  underline: Container(),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  items: ['Modern', 'Classic', 'Typewriter']
                      .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) state.updateNodeFont(node.id, v);
                  },
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Bold',
                  icon: const Icon(Icons.format_bold, size: 18),
                  onPressed: () => _toggleFormatting('**'),
                ),
                IconButton(
                  tooltip: 'Italic',
                  icon: const Icon(Icons.format_italic, size: 18),
                  onPressed: () => _toggleFormatting('*'),
                ),
                IconButton(
                  tooltip: 'Find in this node (Ctrl+F)',
                  icon: Icon(
                    Icons.search,
                    size: 19,
                    color: _isSearching ? kAccentColor : null,
                  ),
                  onPressed: _isSearching ? _closeSearch : _openSearch,
                ),
                IconButton(
                  tooltip: _playbackActive
                      ? 'Stop reading (Esc)'
                      : 'No speech playing',
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: 19,
                    color: _playbackActive ? Colors.redAccent : Colors.white24,
                  ),
                  onPressed:
                      _playbackActive ? _stopPlaybackFromEditor : null,
                ),
                if (node.authorConstraints.isNotEmpty)
                  Tooltip(
                    message: '${node.authorConstraints.where((c) => c.type == AuthorConstraintType.exact).length} exact wording lock(s), '
                        '${node.authorConstraints.where((c) => c.type == AuthorConstraintType.meaning).length} meaning lock(s). '
                        'Select protected text and right-click to change or remove protection.',
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5),
                      child: Icon(Icons.lock_outline, size: 16, color: Color(0xFF80CBC4)),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.format_align_left,
                    size: 18,
                    color: node.textAlign == TextAlign.left
                        ? Colors.white
                        : Colors.grey,
                  ),
                  onPressed: () =>
                      state.updateNodeAlignment(node.id, TextAlign.left),
                ),
                IconButton(
                  icon: Icon(
                    Icons.format_align_center,
                    size: 18,
                    color: node.textAlign == TextAlign.center
                        ? Colors.white
                        : Colors.grey,
                  ),
                  onPressed: () =>
                      state.updateNodeAlignment(node.id, TextAlign.center),
                ),
                IconButton(
                  icon: Icon(
                    Icons.format_align_right,
                    size: 18,
                    color: node.textAlign == TextAlign.right
                        ? Colors.white
                        : Colors.grey,
                  ),
                  onPressed: () =>
                      state.updateNodeAlignment(node.id, TextAlign.right),
                ),
              ],
            ),
            if (_isSearching) ...[
              _buildSearchBar(),
              const SizedBox(height: 10),
            ] else
              const SizedBox(height: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final editorStyle =
                      _getFontStyle(node.fontFamily).copyWith(fontSize: 14);
                  return AnimatedBuilder(
                    animation: _contentScrollController,
                    child: GestureDetector(
                      key: _editorBoxKey,
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () => _readFromEditorCursor(state, node),
                      child: TextField(
                        controller: _contentCtrl,
                        focusNode: _contentFocusNode,
                        scrollController: _contentScrollController,
                        maxLines: null,
                        expands: true,
                        textAlign: node.textAlign,
                        textAlignVertical: TextAlignVertical.top,
                        contextMenuBuilder: (context, editableTextState) =>
                            _buildEditorContextMenu(
                          context,
                          editableTextState,
                          state,
                          node,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF222222),
                          border: const OutlineInputBorder(
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.fromLTRB(54, 12, 12, 12),
                          hintText:
                              'Write ${state.unitLabel.toLowerCase()}...  Double-click to read from here.',
                        ),
                        onChanged: (v) {
                          _ttsKey.currentState?.stopPlayback();
                          _contentCtrl.clearPlaybackRange();
                          state.updateNodeContent(node.id, v);
                          _contentCtrl.setAuthorConstraints(node.authorConstraints);
                          _reportDroppedConstraints(state);
                          if (_isSearching) {
                            _runSearch(_searchController.text, reveal: false);
                          }
                        },
                        style: editorStyle,
                      ),
                    ),
                    builder: (context, child) {
                      final scrollOffset = _contentScrollController.hasClients
                          ? _contentScrollController.offset
                          : 0.0;
                      // Cached: only recomputed when the text, width, font or
                      // alignment changes, not on every scroll tick.
                      _ensureEditorLayout(
                        context,
                        style: editorStyle,
                        align: node.textAlign,
                        width: (constraints.maxWidth - 66)
                            .clamp(1.0, double.infinity)
                            .toDouble(),
                      );
                      return Stack(
                        children: [
                          Positioned.fill(child: child!),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: 44,
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _LineNumberPainter(
                                  lineTops: _layoutLineTops,
                                  scrollOffset: scrollOffset,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    String counter;
    if (_searchQuery.length < 2) {
      counter = 'min 2';
    } else if (_searchMatches.isEmpty) {
      counter = '0 matches';
    } else {
      counter = '${_currentSearchMatch + 1} / ${_searchMatches.length}';
    }

    return Container(
      height: 38,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 17, color: Colors.white38),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Find in this node',
                hintStyle: TextStyle(color: Colors.white30),
              ),
              onChanged: _runSearch,
              onSubmitted: (_) {
                _stepSearch(1);
                _searchFocusNode.requestFocus();
              },
            ),
          ),
          Text(counter,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
          IconButton(
            tooltip: 'Previous match',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            onPressed: _searchMatches.isEmpty ? null : () => _stepSearch(-1),
          ),
          IconButton(
            tooltip: 'Next match',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            onPressed: _searchMatches.isEmpty ? null : () => _stepSearch(1),
          ),
          IconButton(
            tooltip: 'Close find',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 17),
            onPressed: _closeSearch,
          ),
        ],
      ),
    );
  }

  TextStyle _getFontStyle(String font) {
    switch (font) {
      case 'Typewriter':
        return const TextStyle(fontFamily: 'Courier', height: 1.4);
      case 'Classic':
        return const TextStyle(fontFamily: 'Times New Roman', height: 1.4);
      default:
        return const TextStyle(fontFamily: 'Roboto', height: 1.4);
    }
  }
}


class _LineNumberPainter extends CustomPainter {
  const _LineNumberPainter({
    required this.lineTops,
    required this.scrollOffset,
  });

  /// Unscrolled y of each logical (newline-delimited) line, precomputed once
  /// per text/width change by the editor layout cache.
  final List<double> lineTops;
  final double scrollOffset;

  static const TextStyle _numberStyle = TextStyle(
    color: Color(0xFF666666),
    fontSize: 10,
    fontFamily: 'monospace',
    height: 1.0,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final gutterPaint = Paint()..color = const Color(0xFF1D1D1D);
    canvas.drawRect(Offset.zero & size, gutterPaint);
    final dividerPaint = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width - 0.5, 0),
      Offset(size.width - 0.5, size.height),
      dividerPaint,
    );

    for (var i = 0; i < lineTops.length; i++) {
      final y = lineTops[i] + 13 - scrollOffset;
      if (y < -14) continue;
      if (y > size.height + 4) break; // tops are monotonic; nothing below fits
      final painter = TextPainter(
        text: TextSpan(text: '${i + 1}', style: _numberStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(maxWidth: size.width - 8);
      painter.paint(canvas, Offset(size.width - painter.width - 8, y));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _LineNumberPainter oldDelegate) =>
      !identical(oldDelegate.lineTops, lineTops) ||
      oldDelegate.scrollOffset != scrollOffset;
}
